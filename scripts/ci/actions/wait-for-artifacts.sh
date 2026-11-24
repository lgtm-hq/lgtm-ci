#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Wait for a run's matrix result artifacts to become listable before
#          aggregation, then (optionally) download them (#803).
#
# GitHub's artifact listing is eventually consistent: a matrix leg whose upload
# reported success can be missing from the run's artifact list for tens of
# seconds afterwards, and an artifact that *is* listed can still 404 on
# download for a few more. A one-shot download then fails the aggregate with
# "Expected N matrix summaries, found N-1" on a run whose legs all passed.
#
# This script polls the listing until it shows at least EXPECTED_COUNT
# artifacts matching PATTERN, or the wait budget expires. The retry is
# deliberately narrow:
#
#   - retried:     listing under-counts; HTTP 404 on a concrete artifact id
#                  during download; a listing or download that answers a
#                  transient server error (HTTP 500, 502, 503 or 504, #1606)
#   - not retried: over-counts (a sibling call in the same run uploaded under
#                  the same names — see `artifact-prefix`, #752); a timed-out
#                  call; any other listing/download error (401, 403, other
#                  4xx, anything unrecognised); integrity failures (digest
#                  mismatch, bad or unsafe zip)
#
# Every retry shares one budget (WAIT_BUDGET_SECONDS) and one backoff
# schedule: a 404 and a 5xx on the same artifact count as attempts of the
# same retry, and the time the listing waited is already spent.
#
# Aggregation itself is NOT performed here; aggregate-results.sh then runs once
# against the downloaded set with its existing strictness (#1058).
#
# Usage:
#   wait-for-artifacts.sh EXPECTED_COUNT PATTERN
#
#   EXPECTED_COUNT  Positive integer: artifacts the matrix must have produced.
#   PATTERN         Shell glob matched against artifact names, e.g.
#                   "<artifact-prefix>-results-*" ("python-results-*" with
#                   the default prefix, #1091).
#
# Environment:
#   GITHUB_REPOSITORY   (required) owner/repo
#   GITHUB_RUN_ID       (required) run whose artifacts are listed
#   GH_TOKEN            (required) token with actions:read
#   DOWNLOAD_DIR        (optional) When set, download every matched artifact
#                       and extract it to DOWNLOAD_DIR/<artifact-name>/, the
#                       layout actions/download-artifact uses with
#                       merge-multiple: false. When unset, only the listing is
#                       awaited.
#   MATRIX_JSON         (optional) Matrix JSON ({"include":[{KEY: value}, …]})
#   MATRIX_KEY          (optional) Include key whose value fills PATTERN's `*`.
#                       Both set: the check is by name — a matching artifact
#                       outside the matrix fails like an over-count, and a
#                       permanent under-count names the missing legs. PATTERN
#                       must then contain exactly one `*`; any other shape is
#                       rejected rather than silently checked by count only.
#   WAIT_BUDGET_SECONDS (optional) Total wait budget (default: 90).
#   BACKOFF_SCHEDULE    (optional) Space-separated sleep seconds between polls;
#                       the last value repeats (default: "2 4 8 16 30").
#   GH_CMD_TIMEOUT      (optional) Wall-clock bound in seconds on each `gh`
#                       call (default: 30), so a stalled fetch cannot burn the
#                       job budget (#743 / #749 / #776).
#   TIMEOUT_BIN         (optional) `timeout` binary (GNU coreutils, or the BSD
#                       one newer macOS releases ship); auto-resolved
#                       from `timeout` then `gtimeout` when unset, and with
#                       neither on PATH the calls are bounded by a perl
#                       watchdog with the same semantics (lib/bounded-run.sh).
#   GITHUB_OUTPUT       (optional) Receives `polls`, `artifact-count` and
#                       `elapsed-seconds` when set.

set -euo pipefail

EXPECTED_COUNT="${1:?usage: wait-for-artifacts.sh EXPECTED_COUNT PATTERN}"
PATTERN="${2:?usage: wait-for-artifacts.sh EXPECTED_COUNT PATTERN}"

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${DOWNLOAD_DIR:=}"
: "${MATRIX_JSON:=}"
: "${MATRIX_KEY:=}"
: "${WAIT_BUDGET_SECONDS:=90}"
: "${BACKOFF_SCHEDULE:=2 4 8 16 30}"
: "${GH_CMD_TIMEOUT:=30}"

if [[ ! "$EXPECTED_COUNT" =~ ^[1-9][0-9]*$ ]]; then
	echo "::error::EXPECTED_COUNT must be a positive integer (got '${EXPECTED_COUNT}')"
	exit 1
fi
if [[ ! "$WAIT_BUDGET_SECONDS" =~ ^[0-9]+$ ]]; then
	echo "::error::WAIT_BUDGET_SECONDS must be a non-negative integer (got '${WAIT_BUDGET_SECONDS}')"
	exit 1
fi
if [[ ! "$GH_CMD_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
	echo "::error::GH_CMD_TIMEOUT must be a positive integer (got '${GH_CMD_TIMEOUT}')"
	exit 1
fi
read -r -a BACKOFF <<<"${BACKOFF_SCHEDULE:-}"
if [[ ${#BACKOFF[@]} -eq 0 ]]; then
	echo "::error::BACKOFF_SCHEDULE must list at least one delay"
	exit 1
fi
for delay in "${BACKOFF[@]}"; do
	if [[ ! "$delay" =~ ^[1-9][0-9]*$ ]]; then
		echo "::error::BACKOFF_SCHEDULE entries must be positive integers (got '${delay}')"
		exit 1
	fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/bounded-run.sh
source "$SCRIPT_DIR/../lib/bounded-run.sh"

# Every `gh` call runs under a hard bound; a missing one would silently
# restore unbounded calls, so fail loudly instead (#743). Auto-resolved because
# `runner-image` is a caller input: ubuntu ships `timeout`, a macOS host with
# Homebrew coreutils `gtimeout`, and the hosted macOS images neither, where
# the bound is lib/bounded-run.sh's perl watchdog (#1729).
bounded_run_resolve || exit 1

# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
if [[ "$BOUNDED_RUN_MODE" == perl ]]; then
	log_info "No coreutils timeout on PATH; gh calls are bounded by the perl watchdog in lib/bounded-run.sh"
fi

readonly ARTIFACTS_ENDPOINT="repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/artifacts"

# Scratch space for captured stderr and in-flight archives; removed on every
# exit path so an aborted download cannot leave zips behind.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wait-for-artifacts.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
STDERR_FILE="${WORK_DIR}/stderr"
: >"$STDERR_FILE"

# SIGTERM first, then SIGKILL for a `gh` that ignores it, so a wedged request
# can never outlive the bound. Exit 124 or 137 means the bound fired.
gh_bounded() {
	bounded_run "$GH_CMD_TIMEOUT" 10 gh "$@" </dev/null
}

# Expected artifact names, one per line on stdout, when the matrix is known.
# Empty when MATRIX_JSON/MATRIX_KEY are unset or the pattern has no single `*`
# to fill. A MATRIX_JSON that does not parse, or whose include entries are not
# objects, is a caller bug, not a reason to fall back to the weaker count-only
# check: return non-zero (diagnostic on stderr) so the caller fails loudly
# rather than silently degrading or treating the diagnostic as a name.
expected_names() {
	[[ -n "$MATRIX_JSON" && -n "$MATRIX_KEY" ]] || return 0
	if [[ "${PATTERN//[^*]/}" != "*" ]]; then
		echo "PATTERN '${PATTERN}' must contain exactly one '*' for MATRIX_KEY to fill" >&2
		return 1
	fi
	local prefix="${PATTERN%%\**}" suffix="${PATTERN#*\*}"
	if ! jq -e 'type == "object" and ((.include // []) | type == "array" and all(type == "object"))' \
		<<<"$MATRIX_JSON" >/dev/null 2>&1; then
		echo "MATRIX_JSON is not an object whose include entries are all objects" >&2
		return 1
	fi
	local names
	names="$(jq -r --arg key "$MATRIX_KEY" --arg prefix "$prefix" --arg suffix "$suffix" \
		'.include[]? | .[$key] | select(. != null) | "\($prefix)\(.)\($suffix)"' \
		<<<"$MATRIX_JSON")" || return 1
	# A key that names no include entry is a typo in the workflow, not a
	# matrix without legs: fail rather than quietly lose the by-name check.
	if [[ -z "$names" ]] && jq -e '(.include // []) | length > 0' <<<"$MATRIX_JSON" >/dev/null; then
		echo "MATRIX_KEY '${MATRIX_KEY}' matches no include entry of MATRIX_JSON" >&2
		return 1
	fi
	printf '%s\n' "$names"
}

# Lines of "<id>\t<name>" for every non-expired artifact on the run whose name
# matches PATTERN, one per name. The run-level listing spans every attempt of
# the run, so after `Re-run failed jobs` a leg can appear once per attempt;
# like actions/download-artifact's `latest`, keep only the highest id per name
# so a rerun is not mistaken for sibling contamination. Exits non-zero when
# the listing call itself fails; the caller treats that as an unrelated error.
list_matching() {
	local listing
	# `--paginate` so a run with >100 artifacts (large sibling fan-outs) cannot
	# hide a leg on a later page; `--slurp` folds the pages into one array.
	listing="$(gh_bounded api -X GET --paginate --slurp "${ARTIFACTS_ENDPOINT}?per_page=100" \
		2>"$STDERR_FILE")" || return $?
	jq -r '[.[].artifacts[]? | select(.expired != true)]
		| group_by(.name) | map(max_by(.id)) | sort_by(.id)
		| .[] | "\(.id)\t\(.name)\t\(.digest // "")"' <<<"$listing" |
		while IFS=$'\t' read -r id name digest; do
			# shellcheck disable=SC2254 # PATTERN is a glob by contract
			case "$name" in
			$PATTERN) printf '%s\t%s\t%s\n' "$id" "$name" "$digest" ;;
			esac
		done
}

# sha256 of a file as "sha256:<hex>", matching the listing's `digest` field.
# ubuntu has sha256sum; macOS only shasum.
file_digest() {
	local file="$1" hex
	if command -v sha256sum >/dev/null 2>&1; then
		hex="$(sha256sum "$file" | cut -d' ' -f1)"
	else
		hex="$(shasum -a 256 "$file" | cut -d' ' -f1)"
	fi
	printf 'sha256:%s' "$hex"
}

join_names() {
	(($# > 0)) || return 0
	printf '%s' "$1"
	shift
	(($# > 0)) && printf ', %s' "$@"
	return 0
}

# Print the status code (500, 502, 503 or 504) when the last `gh` call's
# stderr (STDERR_FILE) reports a transient server answer; return 1 otherwise.
# `gh api` reports an HTTP error as one line: `gh: HTTP 503` when the body
# carries no message (the zip endpoint, seen in #1606), or
# `gh: <message> (HTTP 503)` when it does. Only a whole line of exactly that
# shape counts, so "503" inside an artifact id, a name or a URL, or a
# different code such as `HTTP 5030`, never does. The whole diagnostic must
# agree: any other `gh:` line (a 401 or 403 next to the 503, or an error
# this script does not know) makes the failure non-transient, so it is
# never retried and never reported as a server error.
transient_server_answer() {
	local line answer=""
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line%"${line##*[![:space:]]}"}"
		if [[ "$line" =~ ^gh:\ HTTP\ (50[0234])$ ]] ||
			[[ "$line" =~ ^gh:\ .*\ \(HTTP\ (50[0234])\)$ ]]; then
			[[ -n "$answer" ]] || answer="${BASH_REMATCH[1]}"
		elif [[ "$line" == gh:* ]]; then
			return 1
		fi
	done <"$STDERR_FILE"
	[[ -n "$answer" ]] || return 1
	printf '%s' "$answer"
}

# Summarise the answers given as arguments (status codes, in the order seen)
# as "HTTP 404 x1, HTTP 503 x2", in first-seen order.
answers_seen() {
	local code seen=() parts=() count other
	for code in "$@"; do
		[[ " ${seen[*]-} " == *" ${code} "* ]] || seen+=("$code")
	done
	for code in ${seen[@]+"${seen[@]}"}; do
		count=0
		for other in "$@"; do
			[[ "$other" == "$code" ]] && count=$((count + 1))
		done
		parts+=("HTTP ${code} x${count}")
	done
	join_names ${parts[@]+"${parts[@]}"}
}

# The sleep before the next poll: the scheduled backoff, clamped to whatever
# budget remains so the final wait uses it all rather than giving up early.
# Returns 1 once the budget is spent.
next_delay() {
	local attempt="$1" elapsed="$2" idx delay remaining
	remaining=$((WAIT_BUDGET_SECONDS - elapsed))
	if ((remaining <= 0)); then
		return 1
	fi
	idx=$((attempt - 1))
	if ((idx >= ${#BACKOFF[@]})); then
		idx=$((${#BACKOFF[@]} - 1))
	fi
	delay="${BACKOFF[$idx]}"
	if ((delay > remaining)); then
		delay=$remaining
	fi
	printf '%s' "$delay"
}

# Budget accounting uses the larger of wall-clock time and the sum of
# scheduled sleeps, so a stubbed `sleep` still exhausts the budget
# deterministically while slow API calls still count against it in CI.
slept=0
elapsed() {
	if ((SECONDS > slept)); then
		printf '%s' "$SECONDS"
	else
		printf '%s' "$slept"
	fi
}

# Expected names are resolved once. When the matrix is known the check is by
# name, not just by count: a sibling call's artifact standing in for a missing
# leg would otherwise satisfy the count while the wrong set gets aggregated.
EXPECTED_NAMES=()
# Plain command substitution, not process substitution: the parser's exit
# status must reach this shell so a partial name list can never pass as whole.
if ! expected_output="$(expected_names 2>"$STDERR_FILE")"; then
	echo "::error::Expected artifact names could not be derived from MATRIX_JSON, MATRIX_KEY and PATTERN: $(tr '\n' ' ' <"$STDERR_FILE")"
	exit 1
fi
while IFS= read -r expected; do
	[[ -n "$expected" ]] && EXPECTED_NAMES+=("$expected")
done <<<"$expected_output"
if ((${#EXPECTED_NAMES[@]} > 0)) && ((${#EXPECTED_NAMES[@]} != EXPECTED_COUNT)); then
	echo "::error::EXPECTED_COUNT is ${EXPECTED_COUNT} but MATRIX_JSON names ${#EXPECTED_NAMES[@]} legs ($(join_names "${EXPECTED_NAMES[@]}")); the matrix and the count disagree"
	exit 1
fi

is_expected_name() {
	local candidate="$1" expected
	for expected in "${EXPECTED_NAMES[@]}"; do
		[[ "$candidate" == "$expected" ]] && return 0
	done
	return 1
}

log_info "Waiting for ${EXPECTED_COUNT} artifact(s) matching '${PATTERN}' on run ${GITHUB_RUN_ID} (budget ${WAIT_BUDGET_SECONDS}s, backoff ${BACKOFF[*]}s)"

polls=0
matched=""
listing_answers=()
while :; do
	polls=$((polls + 1))
	status=0
	matched="$(list_matching)" || status=$?
	if ((status != 0)); then
		if ((status == 124 || status == 137)); then
			echo "::error::Artifact listing timed out after ${GH_CMD_TIMEOUT}s (poll ${polls}, exit ${status}); not retrying — only under-counts and transient server errors are retried"
		elif grep -q 'HTTP 403' "$STDERR_FILE"; then
			echo "::error::Artifact listing was forbidden (poll ${polls}): $(tr '\n' ' ' <"$STDERR_FILE"). The caller job must grant 'actions: read' alongside 'contents: read' for this reusable workflow (#803)."
		elif answer="$(transient_server_answer)"; then
			# A transient server error on the listing waits like an
			# under-count, within the same budget (#1606).
			listing_answers+=("$answer")
			now="$(elapsed)"
			if delay="$(next_delay "$polls" "$now")"; then
				log_info "Poll ${polls}: artifact listing answered HTTP ${answer} (transient server error); retrying in ${delay}s ($((WAIT_BUDGET_SECONDS - now))s of budget left)"
				sleep "$delay"
				slept=$((slept + delay))
				continue
			fi
			echo "::error::Artifact listing still answered HTTP ${answer} after ${polls} polls over ${now}s (answers seen: $(answers_seen "${listing_answers[@]}")); a transient GitHub server error outlasted the wait budget (#1606)"
		else
			echo "::error::Artifact listing failed (poll ${polls}, exit ${status}): $(tr '\n' ' ' <"$STDERR_FILE")"
		fi
		exit 1
	fi

	found_names=()
	unexpected=()
	while IFS=$'\t' read -r _ name _; do
		[[ -n "$name" ]] || continue
		# Artifact names are used as directory names below. GitHub rejects
		# path separators at upload time; refuse them here too so a listing
		# can never steer a download outside DOWNLOAD_DIR.
		if [[ "$name" == */* || "$name" == *\\* || "$name" == . || "$name" == .. ]]; then
			echo "::error::Artifact name '${name}' is not a safe directory name; refusing to download"
			exit 1
		fi
		found_names+=("$name")
		if ((${#EXPECTED_NAMES[@]} > 0)) && ! is_expected_name "$name"; then
			unexpected+=("$name")
		fi
	done <<<"$matched"
	count=${#found_names[@]}
	found_list="none"
	if ((count > 0)); then
		found_list="$(join_names "${found_names[@]}")"
	fi

	if ((count > EXPECTED_COUNT)) || ((${#unexpected[@]} > 0)); then
		reason="More artifacts than matrix legs"
		if ((${#unexpected[@]} > 0)); then
			reason="Artifacts outside the matrix ($(join_names "${unexpected[@]}"))"
		fi
		echo "::error::Found ${count} artifacts matching '${PATTERN}' but expected ${EXPECTED_COUNT}: ${found_list}. ${reason} means another call in this run uploaded under the same names; set a distinct artifact-prefix per call (#752). Not retrying."
		exit 1
	fi

	if ((count == EXPECTED_COUNT)); then
		log_success "Found ${count}/${EXPECTED_COUNT} artifacts matching '${PATTERN}' on poll ${polls} after $(elapsed)s: ${found_list}"
		break
	fi

	now="$(elapsed)"
	if delay="$(next_delay "$polls" "$now")"; then
		log_info "Poll ${polls}: found ${count}/${EXPECTED_COUNT} artifacts matching '${PATTERN}' (${found_list}); listing may lag uploads, retrying in ${delay}s ($((WAIT_BUDGET_SECONDS - now))s of budget left)"
		sleep "$delay"
		slept=$((slept + delay))
		continue
	fi

	missing=()
	for expected in ${EXPECTED_NAMES[@]+"${EXPECTED_NAMES[@]}"}; do
		present=false
		for name in ${found_names[@]+"${found_names[@]}"}; do
			if [[ "$name" == "$expected" ]]; then
				present=true
				break
			fi
		done
		[[ "$present" == true ]] || missing+=("$expected")
	done

	detail="found: ${found_list}"
	if ((${#missing[@]} > 0)); then
		detail="missing: $(join_names "${missing[@]}"); ${detail}"
	fi
	echo "::error::Expected ${EXPECTED_COUNT} artifacts matching '${PATTERN}', found ${count} after ${polls} polls over ${now}s (${detail}). A leg that never uploaded stays missing; an upload that succeeded but is still unlisted after the budget is a GitHub incident (#803)."
	exit 1
done

# The zip endpoint answers 302 to blob storage; the CLI follows it and
# streams the archive to stdout. The `>` redirection truncates the archive
# file on every attempt, so a retry never appends to a partial body or to the
# error page a failed attempt wrote.
download_one() {
	local id="$1" zip="$2"
	gh_bounded api -X GET "repos/${GITHUB_REPOSITORY}/actions/artifacts/${id}/zip" \
		>"$zip" 2>"$STDERR_FILE"
}

if [[ -n "$DOWNLOAD_DIR" ]]; then
	mkdir -p "$DOWNLOAD_DIR"
	download_attempts=0
	while IFS=$'\t' read -r id name digest; do
		[[ -n "$id" ]] || continue
		dest="${DOWNLOAD_DIR}/${name}"
		zip="${WORK_DIR}/artifact-${id}.zip"
		attempt=0
		answers=()
		while :; do
			attempt=$((attempt + 1))
			download_attempts=$((download_attempts + 1))
			status=0
			download_one "$id" "$zip" || status=$?
			if ((status == 0)); then
				break
			fi
			if ((status == 124 || status == 137)); then
				echo "::error::Download of artifact ${name} (id ${id}) timed out after ${GH_CMD_TIMEOUT}s (exit ${status}); not retrying — only HTTP 404 on a listed id and transient server errors are retried"
				exit 1
			fi
			# Two answers are retried. A 404 on an id the listing just
			# returned is the known consistency lag (#803, third occurrence);
			# HTTP 500/502/503/504 is a transient server error (#1606).
			# Anything else is a real error and fails at once, and so does a
			# diagnostic that mixes one of them with another `gh:` error line.
			if grep -q 'HTTP 404' "$STDERR_FILE" &&
				! grep '^gh:' "$STDERR_FILE" | grep -qv 'HTTP 404'; then
				answer=404
				reason="is listed but not yet downloadable (HTTP 404)"
			elif answer="$(transient_server_answer)"; then
				reason="download answered HTTP ${answer} (transient server error)"
			else
				echo "::error::Download of artifact ${name} (id ${id}) failed (exit ${status}): $(tr '\n' ' ' <"$STDERR_FILE")"
				exit 1
			fi
			answers+=("$answer")
			# Drop whatever the failed attempt wrote; the next attempt starts
			# from an empty file, and the integrity checks below only ever see
			# the archive of the attempt that succeeded.
			rm -f "$zip"
			now="$(elapsed)"
			if delay="$(next_delay "$attempt" "$now")"; then
				log_info "Artifact ${name} (id ${id}) ${reason}; retrying in ${delay}s ($((WAIT_BUDGET_SECONDS - now))s of budget left)"
				sleep "$delay"
				slept=$((slept + delay))
				continue
			fi
			if ((answer == 404)); then
				echo "::error::Artifact ${name} (id ${id}) still returned HTTP 404 after ${attempt} download attempts over ${now}s; giving up (#803). Answers seen: $(answers_seen "${answers[@]}")"
			else
				# The external canary has no signature for this message yet
				# (#1611 adds one once the message is seen in a real run).
				# A later signature must match this text exactly.
				echo "::error::Download of artifact ${name} (id ${id}) still answered HTTP ${answer} after ${attempt} attempts over ${now}s (answers seen: $(answers_seen "${answers[@]}")); a transient GitHub server error outlasted the wait budget (#1606)"
			fi
			exit 1
		done
		# Integrity, not lag or a server error: none of these checks is
		# retried, whatever happened before the download succeeded. The
		# listing's digest is the sha256 of the archive as uploaded (what
		# actions/download-artifact verifies too); absent on pre-v4 artifacts,
		# so only checked when set.
		if [[ -n "$digest" ]]; then
			actual="$(file_digest "$zip")"
			if [[ "$actual" != "$digest" ]]; then
				echo "::error::Artifact ${name} (id ${id}) digest mismatch: listing says ${digest}, download is ${actual}; not retrying"
				exit 1
			fi
		fi
		# Entry paths that escape the destination (`../` components or an
		# absolute path) are an integrity failure too: unzip 6.0 strips a
		# leading `/` but not `..`.
		if ! entries="$(unzip -Z1 "$zip" 2>/dev/null)"; then
			echo "::error::Artifact ${name} (id ${id}) downloaded but is not a valid zip; not retrying"
			exit 1
		fi
		if grep -Eq '(^|/)\.\.(/|$)|^/' <<<"$entries"; then
			echo "::error::Artifact ${name} (id ${id}) contains entries that escape the destination directory; not retrying"
			exit 1
		fi
		# Symlink entries could point outside the destination and be written
		# through by a later entry; result summaries never need them.
		# Captured first rather than piped into `grep -q`: under pipefail an
		# early grep exit can SIGPIPE unzip and turn a match into "no match".
		details="$(unzip -Z "$zip" 2>/dev/null || true)"
		if grep -Eq '^l' <<<"$details"; then
			echo "::error::Artifact ${name} (id ${id}) contains symlink entries; not retrying"
			exit 1
		fi
		mkdir -p "$dest"
		if ! unzip -oq "$zip" -d "$dest"; then
			echo "::error::Artifact ${name} (id ${id}) downloaded but is not a valid zip; not retrying"
			exit 1
		fi
		rm -f "$zip"
		log_info "Downloaded ${name} (id ${id}) to ${dest}${digest:+ (digest verified)}"
	done <<<"$matched"
	log_success "Downloaded ${EXPECTED_COUNT} artifact(s) to ${DOWNLOAD_DIR} in ${download_attempts} request(s)"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	set_github_output "polls" "$polls"
	set_github_output "artifact-count" "$EXPECTED_COUNT"
	set_github_output "elapsed-seconds" "$(elapsed)"
fi
