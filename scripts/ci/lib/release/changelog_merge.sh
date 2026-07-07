#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Merge Keep a Changelog section bodies for release automation
#
# Combines auto-generated and hand-curated changelog content under the standard
# Keep a Changelog section headings (Added, Changed, Deprecated, Removed, Fixed,
# Security).

# Guard against multiple sourcing
[[ -n "${_RELEASE_CHANGELOG_MERGE_LOADED:-}" ]] && return 0
readonly _RELEASE_CHANGELOG_MERGE_LOADED=1

readonly _KAC_SECTION_ORDER=(
	"Added"
	"Changed"
	"Deprecated"
	"Removed"
	"Fixed"
	"Security"
)

readonly _KAC_DEFAULT_SECTION="Changed"

# Normalize a ### heading to a Keep a Changelog section name when recognized.
# Usage: normalize_kac_section "Features"
normalize_kac_section() {
	local heading="${1:-}"

	case "$heading" in
	Added | Features) echo "Added" ;;
	Changed | "Breaking Changes" | Documentation | "Other Changes") echo "Changed" ;;
	Deprecated) echo "Deprecated" ;;
	Removed) echo "Removed" ;;
	Fixed | "Bug Fixes") echo "Fixed" ;;
	Security) echo "Security" ;;
	*) echo "" ;;
	esac
}

# Reset parse scratch variables (generated/final accumulators are managed by merge).
_reset_merge_state() {
	_MERGE_PROSE=""
	_MERGE_BREAKING=""
	for section in "${_KAC_SECTION_ORDER[@]}"; do
		eval "_MERGE_SECTION_${section}=''"
	done
}

# Trim leading and trailing blank lines from a section body.
# Usage: _trim_section_body "$body"
_trim_section_body() {
	local body="${1:-}"

	[[ -z "$body" ]] && return 0

	printf '%s\n' "$body" | awk '
		{ lines[NR] = $0 }
		END {
			start = 1
			end = NR
			while (start <= end && lines[start] ~ /^[[:space:]]*$/) {
				start++
			}
			while (end >= start && lines[end] ~ /^[[:space:]]*$/) {
				end--
			}
			for (i = start; i <= end; i++) {
				print lines[i]
			}
		}
	'
}

# Append a line to a named KaC section accumulator.
_append_to_section() {
	local section="${1:-}"
	local line="${2:-}"
	local current_value

	[[ -z "$section" ]] && return

	eval "current_value=\"\${_MERGE_SECTION_${section}:-}\""
	if [[ -n "$current_value" ]]; then
		current_value+=$'\n'
	fi
	current_value+="$line"
	eval "_MERGE_SECTION_${section}=\$current_value"
}

# Parse changelog body content into section arrays and prose/breaking blocks.
# Usage: parse_changelog_body "$body"
parse_changelog_body() {
	local body="${1:-}"
	local current_section=""
	local in_breaking=false
	local line heading trimmed_heading normalized

	_reset_merge_state

	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" =~ ^###\ (.+)$ ]]; then
			in_breaking=false
			heading="${BASH_REMATCH[1]}"
			trimmed_heading="${heading#"${heading%%[![:space:]]*}"}"
			trimmed_heading="${trimmed_heading%"${trimmed_heading##*[![:space:]]}"}"
			if [[ "$trimmed_heading" =~ ^[Bb]reaking\ [Cc]hanges$ ]]; then
				in_breaking=true
				current_section=""
				continue
			fi
			if [[ "$trimmed_heading" == "Previously Unreleased" ]]; then
				current_section="$_KAC_DEFAULT_SECTION"
				continue
			fi
			normalized=$(normalize_kac_section "$trimmed_heading")
			if [[ -n "$normalized" ]]; then
				current_section="$normalized"
			else
				current_section="$_KAC_DEFAULT_SECTION"
			fi
			continue
		fi

		if [[ "$line" =~ ^\[[^]]+\]: ]]; then
			continue
		fi

		if $in_breaking; then
			if [[ -n "$_MERGE_BREAKING" ]]; then
				_MERGE_BREAKING+=$'\n'
			fi
			_MERGE_BREAKING+="$line"
			continue
		fi

		if [[ -z "$current_section" && -z "$line" && -z "$_MERGE_PROSE" ]]; then
			continue
		fi

		if [[ -z "$current_section" && ! "$line" =~ ^[[:space:]]*[-*+] ]]; then
			if [[ -n "$_MERGE_PROSE" ]]; then
				_MERGE_PROSE+=$'\n'
			fi
			_MERGE_PROSE+="$line"
			continue
		fi

		if [[ -z "$current_section" ]]; then
			current_section="$_KAC_DEFAULT_SECTION"
		fi

		_append_to_section "$current_section" "$line"
	done <<<"$body"
}

# Merge generated and hand-curated changelog bodies into standard sections.
# Usage: merge_changelog_sections "$generated_body" "$existing_unreleased"
merge_changelog_sections() {
	local generated="${1:-}"
	local existing="${2:-}"
	local section left right merged output=""

	if [[ -z "$generated" && -z "$existing" ]]; then
		return 0
	fi

	parse_changelog_body "$generated"
	_MERGE_GENERATED_PROSE="$_MERGE_PROSE"
	_MERGE_GENERATED_BREAKING="$_MERGE_BREAKING"
	for section in "${_KAC_SECTION_ORDER[@]}"; do
		eval "_MERGE_GENERATED_${section}=\"\${_MERGE_SECTION_${section}:-}\""
	done

	parse_changelog_body "$existing"
	local existing_prose="$_MERGE_PROSE"
	local existing_breaking="$_MERGE_BREAKING"

	if [[ -n "$_MERGE_GENERATED_PROSE" && -n "$existing_prose" ]]; then
		_MERGE_PROSE="${_MERGE_GENERATED_PROSE}"$'\n'"${existing_prose}"
	elif [[ -n "$_MERGE_GENERATED_PROSE" ]]; then
		_MERGE_PROSE="$_MERGE_GENERATED_PROSE"
	else
		_MERGE_PROSE="$existing_prose"
	fi
	_MERGE_PROSE=$(_trim_section_body "$_MERGE_PROSE")

	if [[ -n "$_MERGE_GENERATED_BREAKING" && -n "$existing_breaking" ]]; then
		_MERGE_BREAKING="${_MERGE_GENERATED_BREAKING}"$'\n'"${existing_breaking}"
	elif [[ -n "$_MERGE_GENERATED_BREAKING" ]]; then
		_MERGE_BREAKING="$_MERGE_GENERATED_BREAKING"
	else
		_MERGE_BREAKING="$existing_breaking"
	fi
	_MERGE_BREAKING=$(_trim_section_body "$_MERGE_BREAKING")

	for section in "${_KAC_SECTION_ORDER[@]}"; do
		eval "left=\"\${_MERGE_GENERATED_${section}:-}\""
		eval "right=\"\${_MERGE_SECTION_${section}:-}\""
		merged=""
		if [[ -n "$left" && -n "$right" ]]; then
			merged="${left}"$'\n'"${right}"
		elif [[ -n "$left" ]]; then
			merged="$left"
		else
			merged="$right"
		fi
		merged=$(_trim_section_body "$merged")
		eval "_MERGE_FINAL_${section}=\$merged"
	done

	if [[ -n "$_MERGE_PROSE" ]]; then
		output="$_MERGE_PROSE"
	fi

	for section in "${_KAC_SECTION_ORDER[@]}"; do
		eval "merged=\"\${_MERGE_FINAL_${section}:-}\""
		[[ -z "$merged" ]] && continue
		if [[ -n "$output" ]]; then
			output+=$'\n\n'
		fi
		output+="### ${section}"$'\n\n'"${merged}"
	done

	if [[ -n "$_MERGE_BREAKING" ]]; then
		if [[ -n "$output" ]]; then
			output+=$'\n\n'
		fi
		output+="### Breaking changes"$'\n\n'"${_MERGE_BREAKING}"
	fi

	printf '%s' "$output"
}
