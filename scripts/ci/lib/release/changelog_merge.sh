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

# Build a comparison key for a "- " changelog bullet. Display text is unchanged.
# Non-bullet lines yield an empty key (fail closed: never treated as duplicates).
# Usage: _normalize_changelog_bullet_key "$line"
_normalize_changelog_bullet_key() {
	local line="${1:-}"

	[[ "$line" =~ ^-\  ]] || {
		printf ''
		return 0
	}

	# Comparison-only: lowercase, strip trailing (#N)/(sha), backticks, light
	# stopwords (a/an/the/as), collapse whitespace. Stopwords help near-dupes
	# where Unreleased restates a conventional commit with filler words.
	# SHA match avoids awk interval expressions ({n,m}) for POSIX portability.
	printf '%s\n' "$line" | awk '
		{
			line = tolower($0)
			while (1) {
				if (match(line, /[[:space:]]*\(#[0-9]+\)[[:space:]]*$/)) {
					line = substr(line, 1, RSTART - 1)
					continue
				}
				if (match(line, /[[:space:]]*\([0-9a-f]+\)[[:space:]]*$/)) {
					paren = substr(line, RSTART, RLENGTH)
					gsub(/[^0-9a-f]/, "", paren)
					hlen = length(paren)
					if (hlen >= 7 && hlen <= 40) {
						line = substr(line, 1, RSTART - 1)
						continue
					}
				}
				break
			}
			gsub(/`/, "", line)
			n = split(line, words, /[[:space:]]+/)
			out = ""
			for (i = 1; i <= n; i++) {
				w = words[i]
				if (w == "" || w == "a" || w == "an" || w == "the" || w == "as") {
					continue
				}
				out = (out == "" ? w : out " " w)
			}
			print out
		}
	'
}

# Extract **scope** from a normalized bullet key, or empty if absent.
# Usage: _changelog_bullet_scope_key "$normalized_key"
_changelog_bullet_scope_key() {
	local key="${1:-}"

	if [[ "$key" =~ ^-\ \*\*([^*]+)\*\*: ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
	else
		printf ''
	fi
}

# Return 0 when candidate should be treated as a duplicate of existing.
# Exact normalized match, or same **scope**: with one key containing the other
# when the shorter key is at least 70% the length of the longer (avoids dropping
# Unreleased bullets that substantially extend a generated line).
# Usage: _changelog_bullet_keys_duplicate "$candidate_key" "$existing_key"
_changelog_bullet_keys_duplicate() {
	local candidate="${1:-}"
	local existing="${2:-}"
	local candidate_scope existing_scope
	local shorter longer shorter_len longer_len

	[[ -z "$candidate" || -z "$existing" ]] && return 1
	[[ "$candidate" == "$existing" ]] && return 0

	candidate_scope=$(_changelog_bullet_scope_key "$candidate")
	existing_scope=$(_changelog_bullet_scope_key "$existing")
	[[ -n "$candidate_scope" && "$candidate_scope" == "$existing_scope" ]] || return 1

	if [[ ${#candidate} -le ${#existing} ]]; then
		shorter="$candidate"
		longer="$existing"
	else
		shorter="$existing"
		longer="$candidate"
	fi
	[[ "$longer" == *"$shorter"* ]] || return 1

	shorter_len=${#shorter}
	longer_len=${#longer}
	[[ "$longer_len" -gt 0 ]] || return 1
	# Integer percent: require shorter >= 70% of longer.
	[[ $((shorter_len * 100)) -ge $((longer_len * 70)) ]]
}

# Merge generated (left) and Unreleased (right) section bodies, collapsing
# duplicate "- " bullets. Prefers generated display text; keeps unique
# Unreleased bullets; preserves generated-first order. Fail closed: non-bullets
# and ambiguous lines are retained.
# Usage: _dedupe_changelog_section_bodies "$left" "$right"
_dedupe_changelog_section_bodies() {
	local left="${1:-}"
	local right="${2:-}"
	local -a generated_keys=()
	local line key existing_key is_dup output=""

	while IFS= read -r line || [[ -n "$line" ]]; do
		key=$(_normalize_changelog_bullet_key "$line")
		if [[ -n "$key" ]]; then
			generated_keys+=("$key")
		fi
		if [[ -n "$output" ]]; then
			output+=$'\n'
		fi
		output+="$line"
	done <<<"$left"

	while IFS= read -r line || [[ -n "$line" ]]; do
		key=$(_normalize_changelog_bullet_key "$line")
		if [[ -n "$key" ]]; then
			is_dup=false
			for existing_key in "${generated_keys[@]}"; do
				if _changelog_bullet_keys_duplicate "$key" "$existing_key"; then
					is_dup=true
					break
				fi
			done
			if $is_dup; then
				continue
			fi
		fi
		if [[ -n "$output" ]]; then
			output+=$'\n'
		fi
		output+="$line"
	done <<<"$right"

	printf '%s' "$output"
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
			merged=$(_dedupe_changelog_section_bodies "$left" "$right")
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
