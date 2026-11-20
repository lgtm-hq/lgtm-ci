#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Lighthouse CI result parsing utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/lighthouse.sh"
#   parse_lighthouse_json "lhr.json"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_PARSE_LIGHTHOUSE_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_PARSE_LIGHTHOUSE_LOADED=1

# Value a score gets when the report does not hold it as a number from 0 to
# 1 (#1692): never 0, which a threshold of 0 would pass.
readonly LH_INVALID="invalid"

# Internal: one category score as a 0-100 integer, or LH_INVALID.
# Usage: _lighthouse_score "lhr.json" performance IF_ABSENT
# Lighthouse writes each score as a number from 0 to 1 (null for a category
# that errored). A score that is null, not a number or outside 0..1, a
# category that is not an object, and a file that is not such JSON are
# unreadable. A category the report does not have prints IF_ABSENT.
_lighthouse_score() {
	# shellcheck disable=SC2016 # jq program, not shell
	jq -r --arg c "$2" --arg absent "$3" '
		if (.categories | type) != "object" then "invalid"
		elif (.categories | has($c)) | not then $absent
		else .categories[$c]
			| if type == "object" then .score else null end
			| if type == "number" and . >= 0 and . <= 1 then (. * 100 | floor) else "invalid" end
		end' "$1" 2>/dev/null || echo "$LH_INVALID"
}

# Parse Lighthouse JSON report and extract scores
# Usage: parse_lighthouse_json "lhr.json"
# Sets: LH_PERFORMANCE, LH_ACCESSIBILITY, LH_BEST_PRACTICES, LH_SEO, LH_PWA
#       (each a 0-100 integer or LH_INVALID), LH_UNREADABLE (the required
#       categories whose score is unreadable, comma-separated, or empty)
# Returns: 0 when the file was read (check LH_UNREADABLE); 1 when it is
#          missing, every score then LH_INVALID (#1692: never 0).
parse_lighthouse_json() {
	local file="${1:-}" category variable

	if [[ ! -f "$file" ]]; then
		LH_PERFORMANCE="$LH_INVALID"
		LH_ACCESSIBILITY="$LH_INVALID"
		LH_BEST_PRACTICES="$LH_INVALID"
		LH_SEO="$LH_INVALID"
		LH_PWA="$LH_INVALID"
		LH_UNREADABLE="performance,accessibility,best-practices,seo"
		return 1
	fi

	# Lighthouse scores are 0-1 floats, convert to 0-100 integers. The four
	# gated categories are required: absent is unreadable, never 0.
	LH_PERFORMANCE=$(_lighthouse_score "$file" performance "$LH_INVALID")
	LH_ACCESSIBILITY=$(_lighthouse_score "$file" accessibility "$LH_INVALID")
	LH_BEST_PRACTICES=$(_lighthouse_score "$file" best-practices "$LH_INVALID")
	LH_SEO=$(_lighthouse_score "$file" seo "$LH_INVALID")
	# PWA category may not exist in all Lighthouse configs (absent: 0, as
	# before; it is never gated)
	LH_PWA=$(_lighthouse_score "$file" pwa 0)

	LH_UNREADABLE=""
	for category in performance accessibility best-practices seo; do
		variable="LH_${category^^}"
		variable="${variable//-/_}"
		if [[ "${!variable}" == "$LH_INVALID" ]]; then
			LH_UNREADABLE+="${LH_UNREADABLE:+,}${category}"
		fi
	done
	return 0
}

# Parse LHCI manifest.json for multi-URL runs
# Usage: parse_lighthouse_manifest "manifest.json"
# Sets: LH_URLS (newline-separated list of audited URLs)
parse_lighthouse_manifest() {
	local file="${1:-}"

	if [[ ! -f "$file" ]]; then
		LH_URLS=""
		return 1
	fi

	LH_URLS=$(jq -r '.[].url // empty' "$file" 2>/dev/null || echo "")

	return 0
}

# Internal: tell whether a score is readable and meets its threshold. A score
# that is not a whole number from 0 to 100 (LH_INVALID, unset) never does,
# whatever the threshold, 0 included (#1692).
# Usage: _lighthouse_meets SCORE THRESHOLD
_lighthouse_meets() {
	[[ "${1:-}" =~ ^[0-9]{1,3}$ ]] && ((10#$1 <= 100 && 10#$1 >= ${2:-0}))
}

# Check Lighthouse scores against thresholds
# Usage: check_lighthouse_thresholds 80 90 80 80
# Args: perf_threshold a11y_threshold bp_threshold seo_threshold
# Returns: 0 if all pass, 1 if any fail (an unreadable score always fails)
# Sets: LH_FAILED_CATEGORIES (comma-separated list of failed categories)
check_lighthouse_thresholds() {
	local perf_threshold="${1:-80}"
	local a11y_threshold="${2:-90}"
	local bp_threshold="${3:-80}"
	local seo_threshold="${4:-80}"

	LH_FAILED_CATEGORIES=""
	local failed=0

	if ! _lighthouse_meets "${LH_PERFORMANCE:-}" "$perf_threshold"; then
		LH_FAILED_CATEGORIES="performance"
		failed=1
	fi

	if ! _lighthouse_meets "${LH_ACCESSIBILITY:-}" "$a11y_threshold"; then
		[[ -n "$LH_FAILED_CATEGORIES" ]] && LH_FAILED_CATEGORIES+=","
		LH_FAILED_CATEGORIES+="accessibility"
		failed=1
	fi

	if ! _lighthouse_meets "${LH_BEST_PRACTICES:-}" "$bp_threshold"; then
		[[ -n "$LH_FAILED_CATEGORIES" ]] && LH_FAILED_CATEGORIES+=","
		LH_FAILED_CATEGORIES+="best-practices"
		failed=1
	fi

	if ! _lighthouse_meets "${LH_SEO:-}" "$seo_threshold"; then
		[[ -n "$LH_FAILED_CATEGORIES" ]] && LH_FAILED_CATEGORIES+=","
		LH_FAILED_CATEGORIES+="seo"
		failed=1
	fi

	return "$failed"
}

# Format Lighthouse summary string
# Usage: format_lighthouse_summary
# Requires: LH_PERFORMANCE, LH_ACCESSIBILITY, LH_BEST_PRACTICES, LH_SEO set
format_lighthouse_summary() {
	echo "Performance: ${LH_PERFORMANCE:-0}, Accessibility: ${LH_ACCESSIBILITY:-0}, Best Practices: ${LH_BEST_PRACTICES:-0}, SEO: ${LH_SEO:-0}"
}

# Export functions
export LH_INVALID
export -f parse_lighthouse_json parse_lighthouse_manifest check_lighthouse_thresholds format_lighthouse_summary
export -f _lighthouse_score _lighthouse_meets
