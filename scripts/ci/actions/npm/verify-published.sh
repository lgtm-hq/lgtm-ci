#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Post-publish verification for an npm package set. Read-only:
#          this script never writes to the registry; it confirms the
#          registry now serves what the publish step claimed.
#
# Phase 1, propagation (all packages together, one shared clock):
#   A fresh publish is routinely invisible through `npm view` for one to six
#   minutes (platform packages lag the meta package; py-lintro 0.159.1,
#   0.159.4, 0.160.2 and the 0.160.3rc1 checkpoint all did), so every package
#   in ORDER is polled in the same loop with exponential backoff until each is
#   - visible: `npm view <name>@<version>` resolves;
#   - complete: `dist.attestations` and `dist.integrity` are present
#     (provenance metadata propagates separately from the version);
#   - tagged: `dist-tags.<DIST_TAG>` points at <version>, so consumers that
#     resolve the tag get this publish and not the previous release.
#   The log records when each package became visible and the total wait. The
#   loop is bounded: ATTEMPTS polls, DELAY_START seconds before the first
#   retry doubling up to DELAY seconds between later ones (defaults 30 polls,
#   5 s doubling to a 30 s cap: about fifteen minutes worst case; the
#   0.160.3rc1 checkpoint needed about eight minutes for full visibility).
#   A package still missing, incomplete or mis-tagged after the budget is a
#   failure; every package is reported before the script exits.
# Phase 2, only after every package is visible:
#   For the meta package (last in ORDER): `npm install <name>@<version>` from
#   the REGISTRY into a scratch directory, then `npm audit signatures` there.
#   The audit verifies the registry's signatures and attestations for
#   registry-resolved packages, so it must run against the published tarball,
#   never a local re-pack. The meta package's optional dependencies are the
#   platform packages, which is why the install waits for the whole set.
# Optional:
#   - SMOKE command run in the scratch install directory (host platform);
#     its output is shown so a failure is diagnosable from the log.
#
# Dry-runs never touched the registry, so with DRY_RUN=1 this script only
# reports what it would have checked and exits 0.
#
# Environment:
#   PACKAGES_DIR   Directory containing one subdirectory per package (required)
#   ORDER          Same order input publish-set.sh took; meta package last (required)
#   DIST_TAG       Dist-tag the publish used; must point at each version (default latest)
#   DRY_RUN        1 when the publish was a dry-run (default 0)
#   SMOKE          Optional command to run inside the scratch install
#   ATTEMPTS       Propagation polls before giving up (default 30)
#   DELAY          Cap in seconds between polls (default 30)
#   DELAY_START    Seconds before the first retry, doubling up to DELAY (default 5)
#   NPM_CMD        npm binary name (overridable in tests; default npm)
#   SLEEP_CMD      sleep command (overridable in tests; default sleep)

set -euo pipefail

: "${PACKAGES_DIR:?PACKAGES_DIR is required}"
: "${ORDER:?ORDER is required}"
PACKAGES_DIR="${PACKAGES_DIR%/}"
DIST_TAG="${DIST_TAG-latest}"
DRY_RUN="${DRY_RUN:-0}"
SMOKE="${SMOKE:-}"
ATTEMPTS="${ATTEMPTS:-30}"
DELAY="${DELAY:-30}"
DELAY_START="${DELAY_START:-5}"
NPM="${NPM_CMD:-npm}"
SLEEP="${SLEEP_CMD:-sleep}"

if [[ ! "$ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
	echo "ERROR: ATTEMPTS must be a positive integer (got '$ATTEMPTS')" >&2
	exit 1
fi
if [[ ! "$DELAY" =~ ^(0|[1-9][0-9]*)$ ]]; then
	echo "ERROR: DELAY must be a non-negative integer (got '$DELAY')" >&2
	exit 1
fi
if [[ ! "$DELAY_START" =~ ^(0|[1-9][0-9]*)$ ]]; then
	echo "ERROR: DELAY_START must be a non-negative integer (got '$DELAY_START')" >&2
	exit 1
fi
if [[ -z "$DIST_TAG" ]]; then
	echo "ERROR: DIST_TAG must be non-empty (use 'latest' for normal releases)" >&2
	exit 1
fi

normalize_order() {
	local order="$1"
	if [[ "$order" == \[*\] ]]; then
		printf '%s\n' "$order" | jq -r 'if type == "array" then .[] else empty end'
	else
		echo "$order" | tr ',' ' ' | tr -s ' ' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true
	fi
}

package_field() {
	# The path travels as an argv entry, never interpolated into JS source
	# (PACKAGES_DIR and the order entries are caller-provided strings), and
	# path.resolve keeps a relative PACKAGES_DIR (packages-dir: npm) from
	# being looked up as a module name. The field name is a fixed literal.
	node -p "require(require('node:path').resolve(process.argv[1])).$2" "$1/package.json"
}

package_dir_for() {
	if [[ "$1" == "." ]]; then
		echo "$PACKAGES_DIR"
	else
		echo "$PACKAGES_DIR/$1"
	fi
}

# Failures accumulate; every package is checked before deciding.
declare -a FAILURES=()

# One registry probe. Prints a state word on stdout:
#   ok        visible, attestation + integrity present, dist-tag points here
#   missing   the version does not resolve yet
#   partial   visible but attestation/integrity not yet present
#   untagged  visible and complete but dist-tags.<DIST_TAG> is elsewhere
# Args: $1 name, $2 version. Never fails: a probe error is "missing".
probe_package() {
	local name="$1" version="$2"
	local view tags actual
	if ! view="$("$NPM" view "$name@$version" dist.attestations dist.integrity --json 2>/dev/null)"; then
		echo missing
		return 0
	fi
	if ! printf '%s' "$view" | jq -e '."dist.attestations"' >/dev/null 2>&1 ||
		! printf '%s' "$view" | jq -e '."dist.integrity"' >/dev/null 2>&1; then
		echo partial
		return 0
	fi
	# dist-tags live on the packument, not the version manifest: a separate
	# read. A tag that has not moved yet means consumers resolving it still
	# get the previous release, so the publish is not done propagating.
	if ! tags="$("$NPM" view "$name" dist-tags --json 2>/dev/null)"; then
		echo untagged
		return 0
	fi
	actual="$(printf '%s' "$tags" | jq -r --arg tag "$DIST_TAG" '.[$tag] // empty' 2>/dev/null || true)"
	if [[ "$actual" != "$version" ]]; then
		echo untagged
		return 0
	fi
	echo ok
}

# Seconds since the script started, for the per-package timing lines.
STARTED_AT="$(date +%s)"
elapsed() {
	echo $(($(date +%s) - STARTED_AT))
}

# Poll every package together until each is ok or the budget is spent.
# Args: lines of "name version" (one package per line).
wait_for_propagation() {
	local specs="$1"
	local -a pending=()
	local line
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		pending+=("$line")
	done <<<"$specs"

	local attempt delay="$DELAY_START" state name version
	local -A last_state=()
	for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
		local -a still=()
		echo "==> Propagation poll $attempt/$ATTEMPTS (${#pending[@]} package(s) pending, $(elapsed)s elapsed)"
		for line in "${pending[@]}"; do
			name="${line% *}"
			version="${line##* }"
			state="$(probe_package "$name" "$version")"
			case "$state" in
			ok)
				echo "    $name@$version visible with provenance attestation, integrity and dist-tag '$DIST_TAG' after $(elapsed)s (poll $attempt)"
				;;
			missing)
				echo "    $name@$version not visible yet"
				still+=("$line")
				;;
			partial)
				echo "    $name@$version visible, but provenance attestation or integrity not yet present"
				still+=("$line")
				;;
			untagged)
				echo "    $name@$version visible and complete, but dist-tag '$DIST_TAG' does not point at it yet"
				still+=("$line")
				;;
			esac
			last_state["$line"]="$state"
		done
		pending=("${still[@]+"${still[@]}"}")
		if ((${#pending[@]} == 0)); then
			echo "==> All packages visible on the registry after $(elapsed)s ($attempt poll(s))"
			return 0
		fi
		if ((attempt < ATTEMPTS)); then
			echo "    waiting ${delay}s before the next poll"
			"$SLEEP" "$delay"
			delay=$((delay * 2))
			if ((delay > DELAY)); then
				delay="$DELAY"
			fi
		fi
	done

	for line in "${pending[@]}"; do
		name="${line% *}"
		version="${line##* }"
		case "${last_state[$line]}" in
		partial)
			echo "ERROR: $name@$version is on the registry without provenance attestation or integrity after $ATTEMPTS attempts ($(elapsed)s)" >&2
			FAILURES+=("$name@$version missing dist.attestations/dist.integrity after $ATTEMPTS propagation attempts")
			;;
		untagged)
			echo "ERROR: dist-tag '$DIST_TAG' does not point at $name@$version after $ATTEMPTS attempts ($(elapsed)s)" >&2
			FAILURES+=("$name@$version not tagged '$DIST_TAG' after $ATTEMPTS propagation attempts")
			;;
		*)
			echo "ERROR: $name@$version not visible on the registry after $ATTEMPTS attempts ($(elapsed)s)" >&2
			FAILURES+=("$name@$version not found after $ATTEMPTS propagation attempts")
			;;
		esac
	done
	return 1
}

# Args: $1 package name, $2 version — the exact published spec.
audit_meta_signatures() {
	local name="$1" version="$2"
	local spec="$name@$version"
	# Global on purpose: the EXIT trap below fires at script exit, outside
	# this function's scope, where a function-local would be unbound under
	# set -u.
	SCRATCH_DIR="$(mktemp -d)"
	trap 'rm -rf "$SCRATCH_DIR"' EXIT
	local scratch="$SCRATCH_DIR"
	echo "==> Installing $spec from the registry into a scratch directory for npm audit signatures"
	# Exact spec from the registry (not a local re-pack): the audit checks the
	# registry's signature/attestation for what consumers will actually get.
	(cd "$scratch" && "$NPM" install --silent --no-audit --no-fund --ignore-scripts "$spec" >/dev/null 2>&1) || {
		echo "ERROR: scratch install of $spec from the registry failed" >&2
		FAILURES+=("$spec scratch install from the registry failed")
		return 0
	}
	# Quiet on success; on failure the audit's own report is the diagnostic.
	local audit_out
	if audit_out="$(cd "$scratch" && "$NPM" audit signatures 2>&1)"; then
		echo "    npm audit signatures passed for $spec"
	else
		printf '%s\n' "$audit_out" >&2
		echo "ERROR: npm audit signatures failed for $spec" >&2
		FAILURES+=("$spec npm audit signatures failed")
	fi
	if [[ -n "$SMOKE" ]]; then
		echo "==> Running smoke command: $SMOKE"
		# Output stays visible: it is the only diagnostic when the smoke fails.
		if (cd "$scratch" && bash -c "$SMOKE"); then
			echo "    smoke command passed"
		else
			echo "ERROR: smoke command failed: $SMOKE" >&2
			FAILURES+=("smoke command failed: $SMOKE")
		fi
	fi
}

if [[ "$DRY_RUN" == "1" ]]; then
	echo "Dry-run publish: post-publish registry verification skipped (nothing was written)."
	echo "Would check: provenance attestation + integrity per package; npm audit signatures on the meta package."
	exit 0
fi

# Same guard as publish-set.sh: an empty order would verify nothing and pass.
ORDERED_PACKAGES="$(normalize_order "$ORDER")"
if [[ -z "$ORDERED_PACKAGES" ]]; then
	echo "ERROR: ORDER resolved to no packages (got '$ORDER'); nothing to verify" >&2
	exit 1
fi

meta_name=""
meta_version=""
SPECS=""
while IFS= read -r pkg; do
	[[ -n "$pkg" ]] || continue
	pkg_dir="$(package_dir_for "$pkg")"
	name="$(package_field "$pkg_dir" name)"
	version="$(package_field "$pkg_dir" version)"
	SPECS+="$name $version"$'\n'
	# ORDER's last entry is the meta package; its published spec gets the audit.
	meta_name="$name"
	meta_version="$version"
done <<<"$ORDERED_PACKAGES"

# The scratch install resolves the meta package's optional dependencies (the
# platform packages) from the registry, so it runs only once the whole set
# is visible; an early install would fail on a lagging platform package.
if wait_for_propagation "$SPECS" && [[ -n "$meta_name" ]]; then
	audit_meta_signatures "$meta_name" "$meta_version"
else
	echo "==> Skipping the scratch install and audit: not every package is visible" >&2
fi

if ((${#FAILURES[@]} > 0)); then
	echo "ERROR: post-publish verification failed:" >&2
	for failure in "${FAILURES[@]}"; do
		echo "  - $failure" >&2
	done
	exit 1
fi

echo "Post-publish verification passed for all packages."
