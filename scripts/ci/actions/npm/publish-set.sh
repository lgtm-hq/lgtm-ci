#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Publish an ordered set of npm packages with idempotent re-runs.
#
# Ported byte-for-byte from the audited py-lintro implementation
# (scripts/ci/npm/publish_packages.sh, as corrected by py-lintro#2637), with
# the lintro package list and binary staging removed: the reusable starts at
# "a directory of ready-to-pack packages" (one subdirectory per package), so
# this script knows nothing about what it is publishing. See
# reusable-publish-npm-set.yml for the consumer contract.
#
# Resilience (#1682 class): each publish is wrapped in bounded exponential
# backoff that retries ONLY transient Sigstore/registry failures (notably the
# `TLOG_CREATE_ENTRY_ERROR` Rekor 409). Auth and validation failures are never
# retried — retrying them only hides the real problem. Combined with the
# idempotency skip, a re-run repairs a partial publish instead of compounding
# it: platform packages publish first, the meta package last, so consumers
# never resolve a meta-package whose optional dependencies are missing.
#
# Dist-tag reconciliation (#1691, #2631): on both idempotent paths — the
# `npm view` pre-check skip and the EPUBLISHCONFLICT conflict-as-success
# branch — the requested dist-tag is reconciled. Read before write: `npm
# dist-tag ls` is an unauthenticated read, and when it already shows the tag
# pointing at this version nothing is written — the path every
# already-published package takes on a live re-run. This matters because npm
# trusted publishing (OIDC) tokens are publish-scoped and the registry
# rejects `npm dist-tag add` under them (npm/cli#8547). A write that is
# needed and rejected is recorded as dist-tag drift — one warning per
# package, a step-summary line, and a deferred non-zero exit after the loop —
# so the remaining packages still publish and the run still goes red.
#
# Environment:
#   PACKAGES_DIR       Directory containing one subdirectory per package (required)
#   ORDER              Subdirectory names in publish order; meta package last.
#                      May be whitespace/comma separated, or a JSON array.
#                      The literal "." means PACKAGES_DIR itself is the single
#                      package (the deprecated single-package wrapper shape).
#   DIST_TAG           Dist-tag (default latest; must be non-empty)
#   LIVE               1 performs a real publish; default (0) is --dry-run
#   PROVENANCE         0 disables --provenance (default: enabled)
#   ACCESS             npm access level (default public)
#   MAX_ATTEMPTS       Max attempts per publish/reconcile on transient errors (default 3)
#   RETRY_DELAY        Base backoff seconds; doubles each retry (default 5)
#   MAX_DELAY          Backoff ceiling seconds (default 60)
#   GITHUB_OUTPUT      Workflow output file: published=<json>, dist_tag_drift=<bool>
#                      (status per package: published | skipped | dry-run)
#   GITHUB_STEP_SUMMARY  Drift lines appended when set
#   NPM_CMD            npm binary name (overridable in tests; default npm)

set -euo pipefail

: "${PACKAGES_DIR:?PACKAGES_DIR is required}"
: "${ORDER:?ORDER is required}"
PACKAGES_DIR="${PACKAGES_DIR%/}"
DIST_TAG="${DIST_TAG-latest}"
LIVE="${LIVE:-0}"
PROVENANCE="${PROVENANCE:-1}"
ACCESS="${ACCESS:-public}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"
MAX_DELAY="${MAX_DELAY:-60}"
NPM="${NPM_CMD:-npm}"

if [[ -z "$DIST_TAG" ]]; then
	echo "ERROR: DIST_TAG must be non-empty (use 'latest' for normal releases)" >&2
	exit 1
fi
if [[ ! -d "$PACKAGES_DIR" ]]; then
	echo "ERROR: PACKAGES_DIR '$PACKAGES_DIR' does not exist" >&2
	exit 1
fi
if [[ ! "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
	echo "ERROR: MAX_ATTEMPTS must be a positive integer (got '$MAX_ATTEMPTS')" >&2
	exit 1
fi
if [[ ! "$RETRY_DELAY" =~ ^(0|[1-9][0-9]*)$ ]]; then
	echo "ERROR: RETRY_DELAY must be a non-negative integer (got '$RETRY_DELAY')" >&2
	exit 1
fi
if [[ ! "$MAX_DELAY" =~ ^(0|[1-9][0-9]*)$ ]]; then
	echo "ERROR: MAX_DELAY must be a non-negative integer (got '$MAX_DELAY')" >&2
	exit 1
fi

# Accept a JSON array (the reusable passes `order` straight from workflow
# input) or a comma/space-separated list, so tests and callers need no jq.
normalize_order() {
	local order="$1"
	if [[ "$order" == \[*\] ]]; then
		printf '%s\n' "$order" | jq -r 'if type == "array" then .[] else empty end'
	else
		echo "$order" | tr ',' ' ' | tr -s ' ' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true
	fi
}

# Non-retryable failures: authentication, permission, and validation errors.
# These are checked BEFORE the transient patterns because an auth message can
# also mention a Sigstore component (e.g. "sigstore authentication failed
# (E401)"), and retrying it would only hide the real problem.
NON_RETRYABLE_ERROR_RE='E401|E403|E402|ENEEDAUTH|EOTP|EPERM|unauthorized|forbidden|authentication failed|permission denied'
# Transient failures that are safe to retry: the Rekor transparency-log 409
# (TLOG_CREATE_ENTRY_ERROR), other Sigstore/tlog hiccups, registry 5xx,
# rate-limit 429s, and transient network errors.
TRANSIENT_ERROR_RE='TLOG_CREATE_ENTRY_ERROR|creating tlog entry|transparency log|rekor|fulcio|sigstore|ETIMEDOUT|ECONNRESET|EAI_AGAIN|ENOTFOUND|socket hang up|5[0-9][0-9] (internal server error|bad gateway|service unavailable|gateway time-?out)|internal server error|bad gateway|service unavailable|gateway time-?out|EAGAIN|E429|429 too many requests'
# A publish conflict means the exact name@version is already on the registry —
# the desired end state. Treat it as an idempotent success (a prior attempt in
# this loop or an earlier run landed the tarball) rather than a failure.
ALREADY_PUBLISHED_RE='EPUBLISHCONFLICT|cannot publish over|previously published version|already published'

dist_tag_drift=0

# Remove setup-node registry _authToken lines so OIDC trusted publishing can
# run: setup-node with registry-url writes a placeholder
# //registry.npmjs.org/:_authToken=${NODE_AUTH_TOKEN}, and an empty-token
# auth entry makes npm prefer (broken) token auth over the OIDC exchange.
_strip_npmrc_auth_tokens() {
	local npmrc tmp
	for npmrc in "${NPM_CONFIG_USERCONFIG:-}" "${HOME}/.npmrc" ".npmrc"; do
		[[ -n "$npmrc" && -f "$npmrc" ]] || continue
		if grep -q '_authToken' "$npmrc"; then
			tmp="$(mktemp)"
			# Drop authToken entries only; keep registry / always-auth lines.
			# grep -v exits 1 when every line matched (file becomes empty) — tolerate that.
			grep -v '_authToken' "$npmrc" >"$tmp" || true
			mv "$tmp" "$npmrc"
			echo "Stripped _authToken from ${npmrc} for OIDC trusted publishing"
		fi
	done
}
_strip_npmrc_auth_tokens
# Per-package results, accumulated as compact JSON objects and joined at the
# end into the `published` workflow output.
declare -a RESULT_JSON=()

# Compact single line: the value goes into GITHUB_OUTPUT, where a multi-line
# JSON blob would need heredoc delimiters.
emit_published_output() {
	if ((${#RESULT_JSON[@]} == 0)); then
		echo "[]"
		return
	fi
	printf '%s\n' "${RESULT_JSON[@]}" | jq -sc '.'
}

_record_dist_tag_drift() {
	local dr_name="$1"
	local dr_version="$2"
	local dr_actual="$3"
	dist_tag_drift=1
	if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
		echo "- **${dr_name}@${dr_version}**: dist-tag \`$DIST_TAG\` points at \`${dr_actual}\`, not \`${dr_version}\`; the reconcile write was rejected (OIDC trusted publishing cannot run \`npm dist-tag\`, npm/cli#8547)." \
			>>"$GITHUB_STEP_SUMMARY"
	fi
}

package_field() {
	# $1 package dir, $2 field (name|version) — via package.json.
	node -p "require('$1/package.json').$2"
}

# Workflow artifacts drop file modes: actions/upload-artifact zips every file
# as 0644, and `npm pack` records the on-disk mode into the tarball, so a
# consumer's launcher or binary under bin/ (or any package.json "bin"
# target) would install non-executable. Restore +x on those files before
# anything is packed. Idempotent, and it runs for dry-runs too so a
# rehearsal packs the same modes a live publish would.
restore_bin_modes() {
	local pkg_dir="$1" target
	local -a targets=()
	if [[ -d "$pkg_dir/bin" ]]; then
		while IFS= read -r target; do
			[[ -n "$target" ]] && targets+=("$target")
		done < <(find "$pkg_dir/bin" -type f | sort)
	fi
	while IFS= read -r target; do
		[[ -n "$target" ]] && targets+=("$pkg_dir/$target")
	done < <(node -p "const b = require('$pkg_dir/package.json').bin; (typeof b === 'string' ? [b] : Object.values(b || {})).join('\\n')")
	for target in "${targets[@]+"${targets[@]}"}"; do
		[[ -f "$target" && ! -x "$target" ]] || continue
		chmod +x "$target"
		echo "    restored executable mode on ${target#"$PACKAGES_DIR"/}"
	done
}

registry_integrity() {
	# Post-publish registry read; empty (never a lie) when the lookup fails.
	# Dry-runs never touch the registry, not even to read: a dry-run must not
	# depend on network state, and its result is "packed", not "on the registry".
	if [[ "$LIVE" != "1" ]]; then
		return 0
	fi
	"$NPM" view "$1@$2" dist.integrity 2>/dev/null || true
}

# Reconcile the requested dist-tag for an already-published name@version.
#
# Read before write (#2631): `npm dist-tag ls` is an unauthenticated read on
# a public package. When it already shows the requested tag pointing at this
# version, the registry is in the desired end state and nothing is written —
# the path every already-published package takes on a live re-run. This
# matters because the OIDC trusted-publishing token is publish-scoped and the
# registry rejects `npm dist-tag add` under it (npm/cli#8547), so the write
# must only be attempted when the read proves it necessary. A failed read
# falls back to the write path rather than inventing a success.
#
# When a write is needed and fails, the failure is recorded as dist-tag
# drift, not aborted on: one warning per drifted package naming the expected
# and actual tags (and the OIDC remediation for auth-scope rejections), one
# step-summary line, and the drift flag that turns into the deferred
# non-zero exit after the loop — a half-published release must still publish
# its remaining packages (#1682's intent).
#
# `npm dist-tag add` itself is idempotent: a no-op when the tag already
# points at that version. Transient failures get the same bounded backoff as
# publish_one. Auth rejections are never retried — they surface the OIDC
# remediation immediately.
#
# Args:
#   $1: package name (e.g. "@scope/pkg-linux-x64").
#   $2: package version.
# Returns:
#   0 when the tag is correct (already or after the write); 1 on drift that
#   could not be repaired, after recording the warning and the flag.
reconcile_dist_tag() {
	local dt_name="$1"
	local dt_version="$2"
	local dt_actual=""
	local dt_list
	if dt_list="$("$NPM" dist-tag ls "$dt_name" 2>&1)"; then
		dt_actual="$(awk -v tag="$DIST_TAG" '
			{
				line = $0
				sub(/\r$/, "", line)
				sub(/[[:space:]]+$/, "", line)
				sub(/^- /, "", line)
				n = split(line, parts, ": ")
				if (n >= 2 && parts[1] == tag) {
					print parts[2]
					exit
				}
			}
		' <<<"$dt_list")"
		if [[ "$dt_actual" == "$dt_version" ]]; then
			echo "==> Dist-tag '$DIST_TAG' already points at $dt_name@$dt_version; nothing to reconcile."
			return 0
		fi
	fi
	local attempt=1
	local delay="$RETRY_DELAY"
	local dt_output dt_rc
	while :; do
		echo "==> Reconciling dist-tag '$DIST_TAG' for $dt_name@$dt_version (attempt $attempt/$MAX_ATTEMPTS)"
		dt_output="$("$NPM" dist-tag add "$dt_name@$dt_version" "$DIST_TAG" 2>&1)" && dt_rc=0 || dt_rc=$?
		printf '%s\n' "$dt_output"
		if [[ "$dt_rc" -eq 0 ]]; then
			return 0
		fi
		# The OIDC remediation only applies to auth-scope rejections; retrying
		# those would only hide the real problem.
		if grep -qiE "$NON_RETRYABLE_ERROR_RE" <<<"$dt_output"; then
			_record_dist_tag_drift "$dt_name" "$dt_version" "${dt_actual:-unknown}"
			echo "ERROR: could not reconcile dist-tag '$DIST_TAG' for $dt_name@$dt_version (exit $dt_rc)." >&2
			echo "ERROR: npm trusted publishing (OIDC) tokens are publish-scoped and cannot run 'npm dist-tag' (npm/cli#8547)." >&2
			echo "ERROR: re-apply the tag with classic auth: npm dist-tag add $dt_name@$dt_version $DIST_TAG" >&2
			echo "::warning::Dist-tag drift for $dt_name: '$DIST_TAG' should point at $dt_version but reads '${dt_actual:-unknown}' on the registry, and the write was rejected. npm trusted publishing (OIDC) tokens are publish-scoped and cannot run 'npm dist-tag' (npm/cli#8547). Re-apply with classic auth: npm dist-tag add $dt_name@$dt_version $DIST_TAG"
			return 1
		fi
		if grep -qiE "$TRANSIENT_ERROR_RE" <<<"$dt_output"; then
			if [[ "$attempt" -ge "$MAX_ATTEMPTS" ]]; then
				_record_dist_tag_drift "$dt_name" "$dt_version" "${dt_actual:-unknown}"
				echo "ERROR: could not reconcile dist-tag '$DIST_TAG' for $dt_name@$dt_version after $MAX_ATTEMPTS attempts on a transient error." >&2
				echo "::warning::Dist-tag drift for $dt_name: '$DIST_TAG' should point at $dt_version but reads '${dt_actual:-unknown}' on the registry, and the reconcile write kept failing (see the errors above). The remaining packages are still published; the run fails after the loop."
				return 1
			fi
			echo "WARNING: transient dist-tag error for $dt_name@$dt_version (attempt $attempt/$MAX_ATTEMPTS); retrying in ${delay}s." >&2
			sleep "$delay"
			attempt=$((attempt + 1))
			delay=$((delay * 2))
			if [[ "$delay" -gt "$MAX_DELAY" ]]; then
				delay="$MAX_DELAY"
			fi
			continue
		fi
		# Unclassified failure: neither auth nor transient. Still drift — the
		# tag is not where it should be — so record it, or the callers'
		# `|| true` would let the run go green.
		_record_dist_tag_drift "$dt_name" "$dt_version" "${dt_actual:-unknown}"
		echo "ERROR: could not reconcile dist-tag '$DIST_TAG' for $dt_name@$dt_version (exit $dt_rc)." >&2
		echo "::warning::Dist-tag drift for $dt_name: '$DIST_TAG' should point at $dt_version but reads '${dt_actual:-unknown}' on the registry, and the reconcile write failed with an unclassified error (see above). The remaining packages are still published; the run fails after the loop."
		return 1
	done
}

# Publish one package directory with bounded, exponential-backoff retry on
# transient Sigstore/registry errors only.
#
# Args:
#   $1: package subdirectory name under $PACKAGES_DIR (e.g. "linux-arm64",
#       or "." for the wrapper's single-directory shape).
# Returns:
#   0 on a successful (or idempotently already-present) publish; 1 otherwise.
publish_one() {
	local pkg="$1"
	if [[ "$pkg" == "." ]]; then
		local pkg_dir="$PACKAGES_DIR"
	else
		local pkg_dir="$PACKAGES_DIR/$pkg"
	fi
	local attempt=1
	local delay="$RETRY_DELAY"
	local output rc
	while :; do
		echo "==> Publishing $pkg (attempt $attempt/$MAX_ATTEMPTS)"
		# Re-run the identical signed publish each attempt (provenance intact).
		# Capture combined output so we can both echo it and classify the error.
		output="$( (cd "$pkg_dir" && "$NPM" publish --access "$ACCESS" $provenance_flag $dryrun_flag --tag "$DIST_TAG") 2>&1)" && rc=0 || rc=$?
		printf '%s\n' "$output"
		if [[ "$rc" -eq 0 ]]; then
			return 0
		fi
		if grep -qiE "$ALREADY_PUBLISHED_RE" <<<"$output"; then
			echo "==> $pkg already present on the registry (publish conflict); treating as an idempotent success." >&2
			# A fresh publish applies --tag atomically, but this version was
			# published earlier (possibly under a different tag): reconcile the
			# requested tag. Drift is recorded, not fatal here (see
			# reconcile_dist_tag). Dry-runs never mutate the registry, so they
			# skip reconciliation.
			if [[ "$LIVE" == "1" ]]; then
				reconcile_dist_tag "$(package_field "$pkg_dir" name)" "$(package_field "$pkg_dir" version)" || true
			fi
			return 0
		fi
		if grep -qiE "$NON_RETRYABLE_ERROR_RE" <<<"$output"; then
			echo "ERROR: $pkg publish failed with a non-retryable auth/validation error; not retrying." >&2
			return 1
		fi
		if grep -qiE "$TRANSIENT_ERROR_RE" <<<"$output"; then
			if [[ "$attempt" -ge "$MAX_ATTEMPTS" ]]; then
				echo "ERROR: $pkg publish failed after $MAX_ATTEMPTS attempts on a transient error." >&2
				return 1
			fi
			echo "WARNING: transient publish error for $pkg (attempt $attempt/$MAX_ATTEMPTS); retrying in ${delay}s." >&2
			sleep "$delay"
			attempt=$((attempt + 1))
			delay=$((delay * 2))
			if [[ "$delay" -gt "$MAX_DELAY" ]]; then
				delay="$MAX_DELAY"
			fi
			continue
		fi
		echo "ERROR: $pkg publish failed with a non-transient error (exit $rc); not retrying." >&2
		return 1
	done
}

# Build the result entry for one package and remember it for the output.
finish_package() {
	local pkg="$1"
	local status="$2"
	local pkg_dir
	if [[ "$pkg" == "." ]]; then
		pkg_dir="$PACKAGES_DIR"
	else
		pkg_dir="$PACKAGES_DIR/$pkg"
	fi
	local name version integrity_json
	name="$(package_field "$pkg_dir" name)"
	version="$(package_field "$pkg_dir" version)"
	local integrity
	integrity="$(registry_integrity "$name" "$version")"
	if [[ -n "$integrity" ]]; then
		integrity_json="\"$integrity\""
	else
		integrity_json="null"
	fi
	RESULT_JSON+=("$(printf '{"name":"%s","version":"%s","status":"%s","integrity":%s}' "$name" "$version" "$status" "$integrity_json")")
}

if [[ "$PROVENANCE" != "0" ]]; then
	provenance_flag="--provenance"
else
	provenance_flag=""
fi
if [[ "$LIVE" != "1" ]]; then
	dryrun_flag="--dry-run"
else
	dryrun_flag=""
fi
if [[ "$LIVE" != "1" ]]; then
	echo "DRY-RUN mode: no packages will be published. Set LIVE=1 (or dry-run: false) to publish."
else
	echo "LIVE mode: packages WILL be published to the registry (dist-tag=$DIST_TAG)."
fi

# An empty order must fail loudly: a loop over nothing would emit
# published=[] and exit 0, and a release could go green having published
# nothing. Resolve the list up front so the check happens before any work.
ORDERED_PACKAGES="$(normalize_order "$ORDER")"
if [[ -z "$ORDERED_PACKAGES" ]]; then
	echo "ERROR: ORDER resolved to no packages (got '$ORDER'); refusing to publish an empty set" >&2
	exit 1
fi

while IFS= read -r pkg; do
	[[ -n "$pkg" ]] || continue
	if [[ "$pkg" == "." ]]; then
		pkg_dir="$PACKAGES_DIR"
	else
		pkg_dir="$PACKAGES_DIR/$pkg"
	fi
	if [[ ! -f "$pkg_dir/package.json" ]]; then
		echo "ERROR: $pkg_dir/package.json not found (check the order input)" >&2
		exit 1
	fi
	restore_bin_modes "$pkg_dir"
	# Idempotency: if this exact name@version is already on the registry
	# (e.g. a rerun after a mid-loop failure published some packages), skip
	# it. Without this a retry would fail on the already-published versions
	# and leave the release partially published. Only meaningful for a real
	# publish; dry-runs always run to exercise the tarball.
	if [[ "$LIVE" == "1" ]]; then
		pkg_name="$(package_field "$pkg_dir" name)"
		pkg_version="$(package_field "$pkg_dir" version)"
		# Distinguish "version not published" (npm E404) from a lookup that
		# failed for another reason (network, rate-limit, 5xx).
		# Redirect order is intentional: inside $() stdout is the capture pipe,
		# so `2>&1` routes stderr into it and `>/dev/null` then discards stdout
		# only. view_err therefore holds just the error text. Do NOT "simplify"
		# this to `>/dev/null 2>&1` — that discards both streams and would
		# break the E404 classification below.
		view_err="$("$NPM" view "$pkg_name@$pkg_version" version 2>&1 >/dev/null)" && view_ok=1 || view_ok=0
		if [[ "$view_ok" == "1" ]]; then
			echo "==> Skipping $pkg_name@$pkg_version (already published)"
			# The version exists but may carry a different tag than this run
			# requested; reconcile it. A failed reconcile is recorded as drift
			# and the run exits non-zero after the loop, so the remaining
			# packages still publish (see reconcile_dist_tag).
			reconcile_dist_tag "$pkg_name" "$pkg_version" || true
			finish_package "$pkg" "skipped"
			continue
		elif ! grep -qiE 'E404|404 Not Found|is not in this registry' <<<"$view_err"; then
			# The existence check itself failed, so we cannot prove the version
			# is absent. Fail safe by neither skipping nor aborting the whole
			# release: proceed to publish. publish_one() is conflict-safe — if
			# the version is in fact already present, npm's publish conflict is
			# treated as an idempotent success, and a genuine transient error is
			# retried. Aborting here would instead risk leaving a multi-package
			# release partially published on a mere lookup hiccup.
			echo "WARNING: could not verify $pkg_name@$pkg_version on the registry; proceeding to publish (publish is conflict-safe)." >&2
			echo "$view_err" >&2
		fi
	fi
	if publish_one "$pkg"; then
		# A rehearsal is its own status: consumers (and the deprecated
		# wrapper's boolean `published`) must never read a dry-run as live.
		if [[ "$LIVE" == "1" ]]; then
			finish_package "$pkg" "published"
		else
			finish_package "$pkg" "dry-run"
		fi
	else
		exit 1
	fi
done <<<"$ORDERED_PACKAGES"

# Deferred drift exit (#2631): every package has been processed, so the run
# can now go red for the tags that could not be reconciled. The output lets
# a caller (e.g. the recovery workflow) detect the drift programmatically.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	{
		echo "published=$(emit_published_output)"
		if [[ "$dist_tag_drift" -eq 1 ]]; then
			echo "dist_tag_drift=true"
		else
			echo "dist_tag_drift=false"
		fi
	} >>"${GITHUB_OUTPUT}"
fi
if [[ "$dist_tag_drift" -eq 1 ]]; then
	echo "ERROR: npm publish step complete, but dist-tag drift remains (see the warnings above); failing the run." >&2
	exit 1
fi

echo "npm publish step complete."
