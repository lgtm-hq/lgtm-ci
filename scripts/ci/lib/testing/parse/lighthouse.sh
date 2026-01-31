#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Lighthouse CI result parsing utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lighthouse.sh"
#   parse_lighthouse_json "lhr.json"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_PARSE_LIGHTHOUSE_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_PARSE_LIGHTHOUSE_LOADED=1

# Parse Lighthouse JSON report and extract scores
# Usage: parse_lighthouse_json "lhr.json"
# Sets: LH_PERFORMANCE, LH_ACCESSIBILITY, LH_BEST_PRACTICES, LH_SEO, LH_PWA
parse_lighthouse_json() {
	local file="${1:-}"

	if [[ ! -f "$file" ]]; then
		LH_PERFORMANCE=0
		LH_ACCESSIBILITY=0
		LH_BEST_PRACTICES=0
		LH_SEO=0
		LH_PWA=0
		return 1
	fi

	# Lighthouse scores are 0-1 floats, convert to 0-100 integers
	LH_PERFORMANCE=$(jq -r '.categories.performance.score // 0 | . * 100 | floor' "$file" 2>/dev/null || echo "0")
	LH_ACCESSIBILITY=$(jq -r '.categories.accessibility.score // 0 | . * 100 | floor' "$file" 2>/dev/null || echo "0")
	LH_BEST_PRACTICES=$(jq -r '.categories["best-practices"].score // 0 | . * 100 | floor' "$file" 2>/dev/null || echo "0")
	LH_SEO=$(jq -r '.categories.seo.score // 0 | . * 100 | floor' "$file" 2>/dev/null || echo "0")
	# PWA category may not exist in all Lighthouse configs
	LH_PWA=$(jq -r '.categories.pwa.score // 0 | . * 100 | floor' "$file" 2>/dev/null || echo "0")

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

# Check Lighthouse scores against thresholds
# Usage: check_lighthouse_thresholds 80 90 80 80
# Args: perf_threshold a11y_threshold bp_threshold seo_threshold
# Returns: 0 if all pass, 1 if any fail
# Sets: LH_FAILED_CATEGORIES (comma-separated list of failed categories)
check_lighthouse_thresholds() {
	local perf_threshold="${1:-80}"
	local a11y_threshold="${2:-90}"
	local bp_threshold="${3:-80}"
	local seo_threshold="${4:-80}"

	LH_FAILED_CATEGORIES=""
	local failed=0

	if [[ "${LH_PERFORMANCE:-0}" -lt "$perf_threshold" ]]; then
		LH_FAILED_CATEGORIES="performance"
		failed=1
	fi

	if [[ "${LH_ACCESSIBILITY:-0}" -lt "$a11y_threshold" ]]; then
		[[ -n "$LH_FAILED_CATEGORIES" ]] && LH_FAILED_CATEGORIES+=","
		LH_FAILED_CATEGORIES+="accessibility"
		failed=1
	fi

	if [[ "${LH_BEST_PRACTICES:-0}" -lt "$bp_threshold" ]]; then
		[[ -n "$LH_FAILED_CATEGORIES" ]] && LH_FAILED_CATEGORIES+=","
		LH_FAILED_CATEGORIES+="best-practices"
		failed=1
	fi

	if [[ "${LH_SEO:-0}" -lt "$seo_threshold" ]]; then
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
export -f parse_lighthouse_json parse_lighthouse_manifest check_lighthouse_thresholds format_lighthouse_summary
