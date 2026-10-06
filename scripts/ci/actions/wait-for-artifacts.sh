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
#                  during download
#   - not retried: over-counts (a sibling call in the same run uploaded under
#                  the same names — see `artifact-prefix`, #752); any other
#                  listing/download error; integrity failures (bad zip)
#
# Aggregation itself is NOT performed here; aggregate-results.sh then runs once
# against the downloaded set with its existing strictness (#1058).
#
# Usage:
#   wait-for-artifacts.sh EXPECTED_COUNT PATTERN
#
#   EXPECTED_COUNT  Positive integer: artifacts the matrix must have produced.
#   PATTERN         Shell glob matched against artifact names, e.g.
#                   "python-results-*".
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
#                       permanent under-count names the missing legs.
#   WAIT_BUDGET_SECONDS (optional) Total wait budget (default: 90).
#   BACKOFF_SCHEDULE    (optional) Space-separated sleep seconds between polls;
#                       the last value repeats (default: "2 4 8 16 30").
#   GH_CMD_TIMEOUT      (optional) Wall-clock bound in seconds on each `gh`
#                       call (default: 30), so a stalled fetch cannot burn the
#                       job budget (#743 / #749 / #776).
#   TIMEOUT_BIN         (optional) coreutils timeout binary; auto-resolved
#                       from `timeout` then `gtimeout` when unset.
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

# Every `gh` call runs under `timeout`; a missing binary would silently restore
# unbounded calls, so fail loudly instead (#743). Auto-resolved because
# `runner-image` is a caller input: ubuntu ships `timeout`, macOS only the
# Homebrew coreutils `gtimeout`.
if [[ -n "${TIMEOUT_BIN:-}" ]]; then
	if ! command -v "$TIMEOUT_BIN" >/dev/null 2>&1; then
		echo "::error::TIMEOUT_BIN '${TIMEOUT_BIN}' not found on PATH; coreutils timeout is required to bound gh calls"
		exit 1
	fi
else
	for candidate in timeout gtimeout; do
		if command -v "$candidate" >/dev/null 2>&1; then
			TIMEOUT_BIN="$candidate"
			break
		fi
	done
	if [[ -z "${TIMEOUT_BIN:-}" ]]; then
		echo "::error::Neither 'timeout' nor 'gtimeout' is on PATH; coreutils timeout is required to bound gh calls (install coreutils or set TIMEOUT_BIN)"
		exit 1
	fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

readonly ARTIFACTS_ENDPOINT="repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/artifacts"

STDERR_FILE="$(mktemp "${TMPDIR:-/tmp}/wait-for-artifacts.XXXXXX")"
trap 'rm -f "$STDERR_FILE"' EXIT

# SIGTERM first, then SIGKILL for a `gh` that ignores it, so a wedged request
# can never outlive the bound.
gh_bounded() {
	"$TIMEOUT_BIN" --kill-after=10s "$GH_CMD_TIMEOUT" gh "$@" </dev/null
}

# Expected artifact names, one per line, when the matrix is known. Empty when
# MATRIX_JSON/MATRIX_KEY are unset or the pattern has no single `*` to fill.
# A MATRIX_JSON that does not parse is a caller bug, not a reason to fall back
# to the weaker count-only check: fail so the degradation is never silent.
expected_names() {
	[[ -n "$MATRIX_JSON" && -n "$MATRIX_KEY" ]] || return 0
	[[ "$PATTERN" == *"*"* && "${PATTERN//[^*]/}" == "*" ]] || return 0
	local prefix="${PATTERN%%\**}" suffix="${PATTERN#*\*}"
	if ! jq -e 'type == "object"' <<<"$MATRIX_JSON" >/dev/null 2>&1; then
		echo "::error::MATRIX_JSON is set but is not a JSON object; refusing to wait with an unknown matrix"
		exit 1
	fi
	jq -r --arg key "$MATRIX_KEY" --arg prefix "$prefix" --arg suffix "$suffix" \
		'.include[]? | .[$key] | select(. != null) | "\($prefix)\(.)\($suffix)"' \
		<<<"$MATRIX_JSON"
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
		| .[] | "\(.id)\t\(.name)"' <<<"$listing" |
		while IFS=$'\t' read -r id name; do
			# shellcheck disable=SC2254 # PATTERN is a glob by contract
			case "$name" in
			$PATTERN) printf '%s\t%s\n' "$id" "$name" ;;
			esac
		done
}

join_names() {
	(($# > 0)) || return 0
	printf '%s' "$1"
	shift
	(($# > 0)) && printf ', %s' "$@"
	return 0
}

# Format the deadline-bounded sleep before the next poll. Returns 1 when the
# budget cannot accommodate another delay.
next_delay() {
	local attempt="$1" elapsed="$2" idx delay
	idx=$((attempt - 1))
	if ((idx >= ${#BACKOFF[@]})); then
		idx=$((${#BACKOFF[@]} - 1))
	fi
	delay="${BACKOFF[$idx]}"
	if ((elapsed + delay > WAIT_BUDGET_SECONDS)); then
		return 1
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
while IFS= read -r expected; do
	[[ -n "$expected" ]] && EXPECTED_NAMES+=("$expected")
done < <(expected_names)
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
while :; do
	polls=$((polls + 1))
	status=0
	matched="$(list_matching)" || status=$?
	if ((status != 0)); then
		if ((status == 124 || status == 137)); then
			echo "::error::Artifact listing timed out after ${GH_CMD_TIMEOUT}s (poll ${polls}, exit ${status}); not retrying — only under-counts are retried"
		elif grep -q 'HTTP 403' "$STDERR_FILE"; then
			echo "::error::Artifact listing was forbidden (poll ${polls}): $(tr '\n' ' ' <"$STDERR_FILE"). The caller job must grant 'actions: read' alongside 'contents: read' for this reusable workflow (#803)."
		else
			echo "::error::Artifact listing failed (poll ${polls}, exit ${status}): $(tr '\n' ' ' <"$STDERR_FILE")"
		fi
		exit 1
	fi

	found_names=()
	unexpected=()
	while IFS=$'\t' read -r _ name; do
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
# streams the archive to stdout.
download_one() {
	local id="$1" zip="$2"
	gh_bounded api -X GET "repos/${GITHUB_REPOSITORY}/actions/artifacts/${id}/zip" \
		>"$zip" 2>"$STDERR_FILE"
}

if [[ -n "$DOWNLOAD_DIR" ]]; then
	mkdir -p "$DOWNLOAD_DIR"
	download_attempts=0
	while IFS=$'\t' read -r id name; do
		[[ -n "$id" ]] || continue
		dest="${DOWNLOAD_DIR}/${name}"
		zip="$(mktemp "${TMPDIR:-/tmp}/artifact-${id}.XXXXXX")"
		attempt=0
		while :; do
			attempt=$((attempt + 1))
			download_attempts=$((download_attempts + 1))
			status=0
			download_one "$id" "$zip" || status=$?
			if ((status == 0)); then
				break
			fi
			if ((status == 124 || status == 137)); then
				rm -f "$zip"
				echo "::error::Download of artifact ${name} (id ${id}) timed out after ${GH_CMD_TIMEOUT}s (exit ${status}); not retrying — only HTTP 404 on a listed id is retried"
				exit 1
			fi
			# Only a 404 on an id the listing just returned is the known
			# consistency lag (#803, third occurrence). Anything else is a
			# real error and fails at once.
			if ! grep -q 'HTTP 404' "$STDERR_FILE"; then
				rm -f "$zip"
				echo "::error::Download of artifact ${name} (id ${id}) failed (exit ${status}): $(tr '\n' ' ' <"$STDERR_FILE")"
				exit 1
			fi
			now="$(elapsed)"
			if delay="$(next_delay "$attempt" "$now")"; then
				log_info "Artifact ${name} (id ${id}) is listed but not yet downloadable (HTTP 404); retrying in ${delay}s ($((WAIT_BUDGET_SECONDS - now))s of budget left)"
				sleep "$delay"
				slept=$((slept + delay))
				continue
			fi
			rm -f "$zip"
			echo "::error::Artifact ${name} (id ${id}) still returned HTTP 404 after ${attempt} download attempts over ${now}s; giving up (#803)"
			exit 1
		done
		mkdir -p "$dest"
		# A listed, downloadable artifact that does not unzip is corruption,
		# not lag: fail immediately.
		if ! unzip -oq "$zip" -d "$dest"; then
			rm -f "$zip"
			echo "::error::Artifact ${name} (id ${id}) downloaded but is not a valid zip; not retrying"
			exit 1
		fi
		rm -f "$zip"
		log_info "Downloaded ${name} (id ${id}) to ${dest}"
	done <<<"$matched"
	log_success "Downloaded ${EXPECTED_COUNT} artifact(s) to ${DOWNLOAD_DIR} in ${download_attempts} request(s)"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	set_github_output "polls" "$polls"
	set_github_output "artifact-count" "$EXPECTED_COUNT"
	set_github_output "elapsed-seconds" "$(elapsed)"
fi
