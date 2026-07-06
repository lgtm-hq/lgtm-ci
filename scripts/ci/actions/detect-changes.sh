#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Map changed paths to named filters so conditional jobs can
# early-exit green instead of being skipped by on.<event>.paths (which
# deadlocks required checks: a check that never reports blocks the PR and
# times out merge-queue entries).
#
# Writes to GITHUB_OUTPUT:
#   changes        JSON object mapping each filter name to "true"/"false"
#   any-changed    "true" if any filter matched
#
# Environment:
#   GITHUB_OUTPUT        Required. File to append outputs to.
#   FILTERS              Required. One filter per line: `name=pattern [pattern...]`.
#                        Patterns are bash-style globs matched against full
#                        repo-relative paths; `*` crosses directory separators
#                        (so `docs/*` and `docs/**` are equivalent).
#   BASE_SHA             Base commit for the diff. Empty -> fail open (all
#                        filters report true) so required checks stay safe.
#   HEAD_SHA             Head commit for the diff (default: HEAD).
#   CHANGED_FILES        Optional test seam: newline-separated file list used
#                        instead of computing a git diff.

set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${FILTERS:?FILTERS is required}"

BASE_SHA="${BASE_SHA:-}"
HEAD_SHA="${HEAD_SHA:-HEAD}"

# Resolve the changed-file list. No base ref (push without before-SHA, manual
# dispatch, shallow history) -> fail open: report every filter as changed so
# a required check runs its full job rather than silently early-exiting.
fail_open=0
if [[ -n "${CHANGED_FILES+x}" ]]; then
	# Test seam: set-but-empty means "no files changed".
	changed="$CHANGED_FILES"
elif [[ -z "$BASE_SHA" ]]; then
	echo "detect-changes: BASE_SHA is empty; failing open (all filters true)" >&2
	fail_open=1
	changed=""
elif ! changed="$(git diff --name-only "${BASE_SHA}...${HEAD_SHA}" 2>/dev/null)"; then
	# Unreachable base (shallow clone, force-push): fail open, same rationale.
	echo "detect-changes: cannot diff ${BASE_SHA}...${HEAD_SHA}; failing open (all filters true)" >&2
	fail_open=1
	changed=""
fi

matches_any_pattern() {
	local file="$1"
	shift
	local pattern
	for pattern in "$@"; do
		# shellcheck disable=SC2254
		case "$file" in
		$pattern) return 0 ;;
		esac
	done
	return 1
}

json="{"
any="false"
first=1
while IFS= read -r line; do
	# Skip blanks and comments (allowing leading whitespace).
	trimmed="${line#"${line%%[![:space:]]*}"}"
	[[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
	line="$trimmed"
	if [[ "$line" != *=* ]]; then
		echo "detect-changes: invalid filter line (expected name=patterns): $line" >&2
		exit 1
	fi
	name="${line%%=*}"
	name="${name// /}"
	read -r -a patterns <<<"${line#*=}"
	if [[ -z "$name" || "${#patterns[@]}" -eq 0 ]]; then
		echo "detect-changes: invalid filter line (empty name or patterns): $line" >&2
		exit 1
	fi
	# Names become JSON keys verbatim; restrict to characters that need no
	# escaping so the output can never be malformed JSON.
	if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
		echo "detect-changes: invalid filter name (allowed: [A-Za-z0-9_-]): $name" >&2
		exit 1
	fi

	result="false"
	if [[ "$fail_open" -eq 1 ]]; then
		result="true"
	else
		while IFS= read -r file; do
			[[ -z "$file" ]] && continue
			if matches_any_pattern "$file" "${patterns[@]}"; then
				result="true"
				break
			fi
		done <<<"$changed"
	fi
	[[ "$result" == "true" ]] && any="true"

	[[ "$first" -eq 0 ]] && json+=","
	json+="\"${name}\":${result}"
	first=0
done <<<"$FILTERS"
json+="}"

if [[ "$first" -eq 1 ]]; then
	echo "detect-changes: FILTERS contained no filter lines" >&2
	exit 1
fi

{
	echo "changes=${json}"
	echo "any-changed=${any}"
} >>"$GITHUB_OUTPUT"
