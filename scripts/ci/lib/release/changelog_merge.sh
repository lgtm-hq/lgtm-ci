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

	# Comparison-only: lowercase, strip trailing (#N)/(sha), backticks, articles,
	# and the filler phrase " as a ", then collapse whitespace. Do not strip bare
	# "as" — it often carries role/format meaning (e.g. "export as CSV").
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
			gsub(/ as a /, " ", line)
			n = split(line, words, /[[:space:]]+/)
			out = ""
			for (i = 1; i <= n; i++) {
				w = words[i]
				if (w == "" || w == "a" || w == "an" || w == "the") {
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

# Extract the feature identifier (subject) from a normalized scoped bullet key.
# Strips a leading verb (add/introduce/create/new) and a .yml/.yaml/.sh
# extension, then requires the remaining token to look like a workflow or
# script identifier: kebab-case, path-like, or carrying a stripped extension.
# Anything less confident yields no output and a non-zero status (fail closed).
# Usage: _changelog_bullet_subject "$normalized_key"
_changelog_bullet_subject() {
	local key="${1:-}"
	local rest first second token had_extension=false

	[[ "$key" =~ ^-\ \*\*[^*]+\*\*:\ +(.+)$ ]] || return 1
	rest="${BASH_REMATCH[1]}"

	read -r first second _ <<<"$rest"
	case "$first" in
	add | adds | added | introduce | introduces | create | creates | new)
		token="$second"
		;;
	*)
		token="$first"
		;;
	esac

	while [[ "$token" =~ [,\;:\(\)\.]$ ]]; do
		token="${token%?}"
	done
	case "$token" in
	*.yml | *.yaml | *.sh)
		token="${token%.*}"
		had_extension=true
		;;
	esac
	while [[ "$token" =~ [,\;:\(\)\.]$ ]]; do
		token="${token%?}"
	done

	[[ -n "$token" ]] || return 1
	[[ "$token" =~ ^[a-z0-9][a-z0-9._/-]*$ ]] || return 1
	if ! $had_extension && [[ "$token" != *-* && "$token" != */* ]]; then
		return 1
	fi

	printf '%s' "$token"
}

# Extract the descriptive remainder of a scoped bullet key: everything after the
# leading verb (when present) and the feature identifier. Empty when the bullet
# is nothing but scope + identifier, which is the shape release-note generators
# emit. Non-scoped keys yield empty output.
# Usage: _changelog_bullet_description "$normalized_key"
_changelog_bullet_description() {
	local key="${1:-}"
	local rest first second remainder

	[[ "$key" =~ ^-\ \*\*[^*]+\*\*:\ +(.+)$ ]] || {
		printf ''
		return 0
	}
	rest="${BASH_REMATCH[1]}"

	read -r first second remainder <<<"$rest"
	case "$first" in
	add | adds | added | introduce | introduces | create | creates | new)
		# The identifier is "$second"; "$remainder" is already the description.
		;;
	*)
		# The identifier is "$first"; fold "$second" back into the description.
		if [[ -n "$second" ]]; then
			remainder="${second}${remainder:+ ${remainder}}"
		fi
		;;
	esac

	printf '%s' "$remainder"
}

# Decide whether two bullet descriptions describe the same change. A shared
# feature identifier is necessary but NOT sufficient: two bullets can name the
# same workflow and still describe unrelated changes to it. Compatible when
# either description is empty (one side is the bare identifier and the other
# elaborates it) or when every word of the shorter description also appears in
# the longer one. Fail closed: materially diverging descriptions are not
# duplicates, so both bullets are kept.
# Usage: _changelog_descriptions_compatible "$left" "$right"
_changelog_descriptions_compatible() {
	local left="${1:-}"
	local right="${2:-}"
	local shorter longer word
	local -a left_words=() right_words=() shorter_words=()

	if [[ -z "$left" || -z "$right" ]]; then
		return 0
	fi

	read -ra left_words <<<"$left"
	read -ra right_words <<<"$right"
	if [[ ${#left_words[@]} -le ${#right_words[@]} ]]; then
		shorter="$left"
		longer=" ${right} "
	else
		shorter="$right"
		longer=" ${left} "
	fi

	read -ra shorter_words <<<"$shorter"
	for word in ${shorter_words[@]+"${shorter_words[@]}"}; do
		[[ "$longer" == *" ${word} "* ]] || return 1
	done

	return 0
}

# Classify two bullet keys as duplicates. Prints the match kind on success:
#   exact    - identical normalized keys
#   contained - same **scope**, one key contains the other and the shorter key
#               is at least 70% the length of the longer (near-identical
#               restatement; the generated display text is canonical)
#   subject  - same **scope**, the same feature identifier AND compatible
#              descriptions, regardless of length (the Unreleased bullet
#              carries extra detail about the same change)
# Returns 1 when the keys are not duplicates. Fail closed: without a confident
# identifier on both sides, differing keys are kept as separate bullets. A
# shared identifier alone is never enough - two bullets can name the same
# workflow and describe different changes to it.
# Usage: _changelog_bullet_keys_duplicate "$candidate_key" "$existing_key"
_changelog_bullet_keys_duplicate() {
	local candidate="${1:-}"
	local existing="${2:-}"
	local candidate_scope existing_scope
	local candidate_subject existing_subject
	local candidate_description existing_description
	local shorter longer shorter_len longer_len

	[[ -z "$candidate" || -z "$existing" ]] && return 1
	if [[ "$candidate" == "$existing" ]]; then
		printf 'exact'
		return 0
	fi

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
	shorter_len=${#shorter}
	longer_len=${#longer}
	if [[ "$longer" == *"$shorter"* && "$longer_len" -gt 0 ]]; then
		# Integer percent: require shorter >= 70% of longer.
		if [[ $((shorter_len * 100)) -ge $((longer_len * 70)) ]]; then
			printf 'contained'
			return 0
		fi
	fi

	candidate_subject=$(_changelog_bullet_subject "$candidate") || return 1
	existing_subject=$(_changelog_bullet_subject "$existing") || return 1
	[[ "$candidate_subject" == "$existing_subject" ]] || return 1

	candidate_description=$(_changelog_bullet_description "$candidate")
	existing_description=$(_changelog_bullet_description "$existing")
	_changelog_descriptions_compatible \
		"$candidate_description" "$existing_description" || return 1

	printf 'subject'
}

# Split trailing "(#N)"/"(#N, #M)" and "(sha)" suffixes off a bullet line.
# Sets _CL_META_TEXT (line without the suffixes), _CL_META_REFS (raw ref digits)
# and _CL_META_SHA (first commit sha seen, if any).
# Usage: _changelog_split_trailing_meta "$line"
_changelog_split_trailing_meta() {
	local line="${1:-}"
	local matched=true

	_CL_META_REFS=""
	_CL_META_SHA=""

	while $matched; do
		matched=false
		if [[ "$line" =~ ^(.*)[[:space:]]\(#([0-9]+([[:space:]]*,[[:space:]]*#[0-9]+)*)\)[[:space:]]*$ ]]; then
			_CL_META_REFS="${BASH_REMATCH[2]} ${_CL_META_REFS}"
			line="${BASH_REMATCH[1]}"
			matched=true
			continue
		fi
		if [[ "$line" =~ ^(.*)[[:space:]]\(([0-9a-f]{7,40})\)[[:space:]]*$ ]]; then
			[[ -z "$_CL_META_SHA" ]] && _CL_META_SHA="${BASH_REMATCH[2]}"
			line="${BASH_REMATCH[1]}"
			matched=true
			continue
		fi
	done

	_CL_META_TEXT="${line%"${line##*[![:space:]]}"}"
}

# Split a logical bullet group into its lead bullet and its nested sub-bullets.
# A nested bullet is an indented line that itself begins a list item ("  - ",
# "  * ", "  + "); an indented line that does NOT begin a list item is wrapped
# continuation text and belongs to the lead. Everything from the first nested
# bullet onward (including that sub-bullet's own wrapped lines) is a child.
# Sets _CL_GROUP_LEAD and _CL_GROUP_CHILDREN.
# Usage: _split_changelog_group_children "$group"
_split_changelog_group_children() {
	local group="${1:-}"
	local line in_children=false

	_CL_GROUP_LEAD=""
	_CL_GROUP_CHILDREN=""

	while IFS= read -r line || [[ -n "$line" ]]; do
		if ! $in_children && [[ "$line" =~ ^[[:space:]]+[-*+][[:space:]] ]]; then
			in_children=true
		fi
		if $in_children; then
			if [[ -n "$_CL_GROUP_CHILDREN" ]]; then
				_CL_GROUP_CHILDREN+=$'\n'
			fi
			_CL_GROUP_CHILDREN+="$line"
		else
			if [[ -n "$_CL_GROUP_LEAD" ]]; then
				_CL_GROUP_LEAD+=$'\n'
			fi
			_CL_GROUP_LEAD+="$line"
		fi
	done <<<"$group"
}

# Collect PR references and a commit sha from EVERY line of a bullet lead, not
# just its final line: a wrapped bullet can carry "(#123)" on any of its lines.
# Sets _CL_GROUP_REFS (raw ref digits) and _CL_GROUP_SHA (first sha seen).
# Usage: _changelog_collect_group_meta "$lead"
_changelog_collect_group_meta() {
	local text="${1:-}"
	local line

	_CL_GROUP_REFS=""
	_CL_GROUP_SHA=""

	while IFS= read -r line || [[ -n "$line" ]]; do
		_changelog_split_trailing_meta "$line"
		if [[ -n "$_CL_META_REFS" ]]; then
			_CL_GROUP_REFS+=" $_CL_META_REFS"
		fi
		if [[ -z "$_CL_GROUP_SHA" && -n "$_CL_META_SHA" ]]; then
			_CL_GROUP_SHA="$_CL_META_SHA"
		fi
	done <<<"$text"
}

# Strip trailing "(#N)"/"(sha)" suffixes from every line of a bullet lead so the
# merged references can be re-attached once, at the end of the group. Lines left
# empty by the strip are dropped. Usage: _changelog_strip_group_meta "$lead"
_changelog_strip_group_meta() {
	local text="${1:-}"
	local line out=""

	while IFS= read -r line || [[ -n "$line" ]]; do
		_changelog_split_trailing_meta "$line"
		[[ -z "${_CL_META_TEXT//[[:space:]]/}" ]] && continue
		if [[ -n "$out" ]]; then
			out+=$'\n'
		fi
		out+="$_CL_META_TEXT"
	done <<<"$text"

	printf '%s' "$out"
}

# Re-attach nested sub-bullets to a surviving (deduped) parent bullet. A parent
# can be a duplicate while its sub-bullets are unique curated content, so the
# sub-bullets from BOTH sides are kept: the generated side first, then every
# Unreleased sub-bullet whose line is not already present verbatim. Dropping
# them along with the duplicate parent would silently delete release notes,
# which is strictly worse than leaving a duplicate visible.
# Usage: _changelog_join_group_children "$lead" "$left_group" "$right_group"
_changelog_join_group_children() {
	local lead="${1:-}"
	local left_group="${2:-}"
	local right_group="${3:-}"
	local left_children right_children out line

	_split_changelog_group_children "$left_group"
	left_children="$_CL_GROUP_CHILDREN"
	_split_changelog_group_children "$right_group"
	right_children="$_CL_GROUP_CHILDREN"

	out="$lead"
	if [[ -n "$left_children" ]]; then
		out+=$'\n'"$left_children"
	fi

	if [[ -n "$right_children" ]]; then
		while IFS= read -r line || [[ -n "$line" ]]; do
			[[ -z "${line//[[:space:]]/}" ]] && continue
			if [[ $'\n'"${left_children}"$'\n' == *$'\n'"${line}"$'\n'* ]]; then
				continue
			fi
			out+=$'\n'"$line"
		done <<<"$right_children"
	fi

	printf '%s' "$out"
}

# Combine a generated bullet with a duplicate Unreleased bullet: merge the PR
# references found anywhere in either bullet and keep the generated commit sha
# when present. References are merged on EVERY match kind - a duplicate is a
# duplicate, and dropping the Unreleased bullet's "(#N)" loses a real PR from
# the history. Display text is chosen per match kind: "subject" keeps the more
# informative (longer) text, while "exact"/"contained" keep the generated text
# because it is the canonical restatement. Only the lead bullet is merged;
# nested sub-bullets are re-attached by the caller.
# Usage: _merge_changelog_duplicate_group "$generated" "$unreleased" "$kind"
_merge_changelog_duplicate_group() {
	local generated="${1:-}"
	local unreleased="${2:-}"
	local kind="${3:-subject}"
	local generated_lead unreleased_lead
	local preferred refs_raw sha last head joined ref

	_split_changelog_group_children "$generated"
	generated_lead="$_CL_GROUP_LEAD"
	_split_changelog_group_children "$unreleased"
	unreleased_lead="$_CL_GROUP_LEAD"

	if [[ "$kind" == "subject" && ${#unreleased_lead} -gt ${#generated_lead} ]]; then
		preferred="$unreleased_lead"
	else
		preferred="$generated_lead"
	fi

	_changelog_collect_group_meta "$generated_lead"
	refs_raw="$_CL_GROUP_REFS"
	sha="$_CL_GROUP_SHA"
	_changelog_collect_group_meta "$unreleased_lead"
	refs_raw+=" $_CL_GROUP_REFS"
	[[ -z "$sha" ]] && sha="$_CL_GROUP_SHA"

	preferred=$(_changelog_strip_group_meta "$preferred")
	last="${preferred##*$'\n'}"
	if [[ "$preferred" == *$'\n'* ]]; then
		head="${preferred%$'\n'*}"
	else
		head=""
	fi

	joined=""
	while read -r ref; do
		[[ -z "$ref" ]] && continue
		if [[ -n "$joined" ]]; then
			joined+=", "
		fi
		joined+="#${ref}"
	done < <(printf '%s\n' "$refs_raw" | grep -oE '[0-9]+' | sort -un)

	[[ -n "$joined" ]] && last+=" (${joined})"
	[[ -n "$sha" ]] && last+=" (${sha})"

	if [[ -n "$head" ]]; then
		printf '%s\n%s' "$head" "$last"
	else
		printf '%s' "$last"
	fi
}

# Split a section body into logical bullet groups: an unindented line starts a
# group and every indented line (wrapped bullet text and nested sub-bullets) is
# folded into the preceding group so a bullet and its subtree move as a unit.
# Lead text and sub-bullets are told apart later by
# _split_changelog_group_children. Blank lines are dropped. Result lands in
# _CL_GROUPS.
# Usage: _collect_changelog_bullet_groups "$body"
_collect_changelog_bullet_groups() {
	local body="${1:-}"
	local line current="" has_current=false

	_CL_GROUPS=()

	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -z "${line//[[:space:]]/}" ]] && continue
		if $has_current && [[ "$line" =~ ^[[:space:]]+[^[:space:]] ]]; then
			current+=$'\n'"$line"
			continue
		fi
		if $has_current; then
			_CL_GROUPS+=("$current")
		fi
		current="$line"
		has_current=true
	done <<<"$body"

	if $has_current; then
		_CL_GROUPS+=("$current")
	fi
}

# Build the comparison key for a logical bullet group: the lead bullet's wrapped
# continuation lines are folded into a single line before normalization so
# wrapped bullets are keyed on their full text. Nested sub-bullets are excluded
# from the key - they are separate content that must survive a parent dedup, so
# they must not influence whether the parent is a duplicate. Groups that do not
# start with "- " yield an empty key.
# Usage: _changelog_group_key "$group"
_changelog_group_key() {
	local group="${1:-}"
	local line joined=""

	[[ "$group" =~ ^-\  ]] || {
		printf ''
		return 0
	}

	_split_changelog_group_children "$group"

	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line#"${line%%[![:space:]]*}"}"
		[[ -z "$line" ]] && continue
		if [[ -n "$joined" ]]; then
			joined+=" "
		fi
		joined+="$line"
	done <<<"$_CL_GROUP_LEAD"

	_normalize_changelog_bullet_key "$joined"
}

# Merge generated (left) and Unreleased (right) section bodies, collapsing
# duplicate bullets. Every duplicate merges both sides' PR references into the
# surviving entry; only the display text differs by match kind (near-identical
# restatements keep the generated text, same-subject duplicates keep the more
# informative text). Nested sub-bullets from both sides survive under the kept
# parent. Unique Unreleased bullets are kept and generated-first order is
# preserved. Fail closed: non-bullets and ambiguous lines are retained. Blank
# lines from either side are dropped so skipped duplicates do not leave
# orphaned separators.
# Usage: _dedupe_changelog_section_bodies "$left" "$right"
_dedupe_changelog_section_bodies() {
	local left="${1:-}"
	local right="${2:-}"
	local -a left_texts=() left_keys=() right_groups=() extra_texts=()
	local group key kind index matched merged_lead output=""

	_collect_changelog_bullet_groups "$left"
	for group in ${_CL_GROUPS[@]+"${_CL_GROUPS[@]}"}; do
		left_texts+=("$group")
		left_keys+=("$(_changelog_group_key "$group")")
	done

	_collect_changelog_bullet_groups "$right"
	right_groups=(${_CL_GROUPS[@]+"${_CL_GROUPS[@]}"})

	for group in ${right_groups[@]+"${right_groups[@]}"}; do
		key=$(_changelog_group_key "$group")
		matched=false
		if [[ -n "$key" ]]; then
			index=0
			while [[ $index -lt ${#left_keys[@]} ]]; do
				if kind=$(_changelog_bullet_keys_duplicate "$key" "${left_keys[$index]}"); then
					matched=true
					merged_lead=$(
						_merge_changelog_duplicate_group \
							"${left_texts[$index]}" "$group" "$kind"
					)
					# The parent is a duplicate; its sub-bullets may not be.
					left_texts[index]=$(
						_changelog_join_group_children \
							"$merged_lead" "${left_texts[$index]}" "$group"
					)
					break
				fi
				index=$((index + 1))
			done
		fi
		$matched && continue
		extra_texts+=("$group")
	done

	for group in ${left_texts[@]+"${left_texts[@]}"} ${extra_texts[@]+"${extra_texts[@]}"}; do
		if [[ -n "$output" ]]; then
			output+=$'\n'
		fi
		output+="$group"
	done

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
