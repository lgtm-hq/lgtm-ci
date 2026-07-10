#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Helper for the detect-changes composite action. Resolves fail-open
# when the diff base is empty/unresolvable, extracts dorny filter names, and
# maps dorny/paths-filter outputs onto the public contract:
#   changes        JSON object mapping each filter name to true/false
#   any-changed    "true" if any filter matched
#
# Glob matching is owned by dorny/paths-filter; this script does not reimplement
# a path-filter engine.
#
# Environment:
#   GITHUB_OUTPUT   Required. File to append outputs to.
#   STEP            Required. One of: resolve, map.
#   FILTERS         Required for resolve. Dorny YAML filters (or path to a
#                   filters file). Legacy `name=glob …` lines are rejected with
#                   a migration hint.
#   BASE_SHA        Base commit for the diff (resolve). Empty -> fail open.
#   HEAD_SHA        Head commit / dorny `ref` (resolve; default HEAD).
#   EVENT_NAME      github.event_name (resolve). PR events skip git reachability
#                   checks because dorny uses the Pulls API.
#   FAIL_OPEN       "true"/"false" (map).
#   FILTER_NAMES    Space-separated filter names (map).
#   DORNY_CHANGES   Dorny `changes` JSON array of matched names (map; optional).

set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${STEP:?STEP is required}"

NULL_SHA="0000000000000000000000000000000000000000"

write_changes_outputs() {
	local -a names=("$@")
	local fail_open="${FAIL_OPEN:-false}"
	local dorny_changes="${DORNY_CHANGES:-}"
	local json="{"
	local any="false"
	local first=1
	local name result

	if [[ "$fail_open" != "true" && -z "$dorny_changes" ]]; then
		dorny_changes="[]"
	fi

	for name in "${names[@]}"; do
		result="false"
		if [[ "$fail_open" == "true" ]]; then
			result="true"
		elif [[ "$dorny_changes" == *"\"${name}\""* ]]; then
			result="true"
		fi
		[[ "$result" == "true" ]] && any="true"

		[[ "$first" -eq 0 ]] && json+=","
		json+="\"${name}\":${result}"
		first=0
	done
	json+="}"

	if [[ "$first" -eq 1 ]]; then
		echo "detect-changes: FILTERS contained no filter names" >&2
		exit 1
	fi

	{
		echo "changes=${json}"
		echo "any-changed=${any}"
	} >>"$GITHUB_OUTPUT"
}

load_filters_text() {
	local filters="$1"
	# Pass legacy `name=glob …` through unchanged so extract_filter_names can
	# detect and reject it with a migration hint. Without this early-return a
	# single-line value without ':' would be treated as a file path below.
	if [[ "$filters" != *$'\n'* && "$filters" == *=* && "$filters" != *:* ]]; then
		printf '%s' "$filters"
		return 0
	fi
	# Dorny treats a single-line value without ':' as a config file path.
	if [[ "$filters" != *$'\n'* && "$filters" != *:* ]]; then
		if [[ ! -f "$filters" ]]; then
			echo "detect-changes: filters file not found: $filters" >&2
			exit 1
		fi
		filters="$(cat "$filters")"
	fi
	printf '%s' "$filters"
}

# Match a top-level dorny YAML filter key on an unindented line.
# Supports unquoted names (letters/digits/_/-/.) and single-/double-quoted
# names (e.g. "api/v2", 'frontend.app').
parse_top_level_filter_key() {
	local line="$1"
	if [[ "$line" =~ ^\"([^\"]+)\":([[:space:]]|$) ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	if [[ "$line" =~ ^\'([^\']+)\':([[:space:]]|$) ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	if [[ "$line" =~ ^([A-Za-z0-9_][A-Za-z0-9_.-]*):([[:space:]]|$) ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

looks_like_legacy_line_format() {
	local filters="$1"
	local line trimmed
	local saw_legacy=0
	local saw_yaml_key=0

	while IFS= read -r line || [[ -n "$line" ]]; do
		trimmed="${line#"${line%%[![:space:]]*}"}"
		[[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
		if [[ "$trimmed" =~ ^[A-Za-z0-9_-]+= ]]; then
			saw_legacy=1
			continue
		fi
		if parse_top_level_filter_key "$line" >/dev/null; then
			saw_yaml_key=1
		fi
	done <<<"$filters"

	[[ "$saw_legacy" -eq 1 && "$saw_yaml_key" -eq 0 ]]
}

extract_filter_names() {
	local filters="$1"
	local line trimmed name
	local -a names=()

	if looks_like_legacy_line_format "$filters"; then
		echo "detect-changes: legacy line format (name=glob …) is no longer supported" >&2
		echo "detect-changes: migrate to dorny YAML filters, e.g.:" >&2
		echo "detect-changes:   frontend:" >&2
		echo "detect-changes:     - 'packages/frontend/**'" >&2
		echo "detect-changes: See docs/actions/testing.md (detect-changes)." >&2
		exit 1
	fi

	while IFS= read -r line || [[ -n "$line" ]]; do
		trimmed="${line#"${line%%[![:space:]]*}"}"
		[[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
		# Top-level dorny filter keys are unindented `name:` entries
		# (unquoted with ._- or quoted for special characters).
		if name="$(parse_top_level_filter_key "$line")"; then
			names+=("$name")
			continue
		fi
		if [[ "$line" =~ ^[^[:space:]#].*= ]]; then
			echo "detect-changes: unexpected filter line (expected dorny YAML): $line" >&2
			exit 1
		fi
	done <<<"$filters"

	if [[ "${#names[@]}" -eq 0 ]]; then
		echo "detect-changes: FILTERS contained no filter names" >&2
		exit 1
	fi

	printf '%s\n' "${names[@]}"
}

base_is_resolvable() {
	local base="$1"
	[[ -n "$base" ]] || return 1
	# GitHub uses the null SHA as event.before on the first push of a branch.
	# Dorny handles that case natively (compare to default branch / list all
	# files as added); treat it as resolvable so we do not fail-open and skip
	# dorny.
	[[ "$base" == "$NULL_SHA" ]] && return 0
	git cat-file -e "${base}^{commit}" 2>/dev/null
}

resolve_step() {
	: "${FILTERS:?FILTERS is required}"

	local filters_text names_text
	filters_text="$(load_filters_text "$FILTERS")"
	# Command substitution (not process substitution) so extract failures exit.
	names_text="$(extract_filter_names "$filters_text")" || exit $?

	local -a names=()
	local name
	while IFS= read -r name; do
		[[ -z "$name" ]] && continue
		names+=("$name")
	done <<<"$names_text"

	if [[ "${#names[@]}" -eq 0 ]]; then
		echo "detect-changes: FILTERS contained no filter names" >&2
		exit 1
	fi

	local base_sha="${BASE_SHA:-}"
	local head_sha="${HEAD_SHA:-HEAD}"
	local event_name="${EVENT_NAME:-}"
	local fail_open="false"

	if [[ -z "$base_sha" ]]; then
		echo "detect-changes: BASE_SHA is empty; failing open (all filters true)" >&2
		fail_open="true"
	elif [[ "$event_name" != pull_request && "$event_name" != pull_request_target &&
		"$event_name" != pull_request_review && "$event_name" != pull_request_review_comment ]]; then
		# Dorny uses git for merge_group/push/other; unreachable base must not
		# fail the required check closed. PR events use the Pulls API instead.
		if ! base_is_resolvable "$base_sha"; then
			echo "detect-changes: cannot resolve base ${base_sha}; failing open (all filters true)" >&2
			fail_open="true"
		fi
	fi

	{
		echo "fail-open=${fail_open}"
		echo "filter-names=${names[*]}"
		echo "base=${base_sha}"
		echo "ref=${head_sha}"
	} >>"$GITHUB_OUTPUT"
}

map_step() {
	: "${FILTER_NAMES:?FILTER_NAMES is required}"
	FAIL_OPEN="${FAIL_OPEN:-false}"

	local -a names=()
	# shellcheck disable=SC2206
	names=($FILTER_NAMES)

	if [[ "$FAIL_OPEN" == "true" ]]; then
		echo "detect-changes: fail-open active; reporting all filters true" >&2
	fi

	write_changes_outputs "${names[@]}"
}

case "$STEP" in
resolve)
	resolve_step
	;;
map)
	map_step
	;;
*)
	echo "detect-changes: unknown STEP '${STEP}' (expected resolve or map)" >&2
	exit 1
	;;
esac
