#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Coverage badge generation utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/badge.sh"
#   generate_badge_svg 85.5 "badge.svg"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_BADGE_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_BADGE_LOADED=1

# =============================================================================
# Badge color utilities
# =============================================================================

# Get badge color based on coverage percentage
# Usage: get_badge_color 85.5 [red_threshold] [yellow_threshold]
# Output: color name (red, yellow, green, brightgreen)
get_badge_color() {
	local percent="${1:-0}"
	local red_threshold="${2:-50}"
	local yellow_threshold="${3:-80}"

	# Use awk for floating point comparison
	local color
	color=$(awk -v pct="$percent" -v red="$red_threshold" -v yellow="$yellow_threshold" 'BEGIN {
		if (pct < red) {
			print "red"
		} else if (pct < yellow) {
			print "yellow"
		} else if (pct < 90) {
			print "green"
		} else {
			print "brightgreen"
		}
	}')

	echo "$color"
}

# Get hex color code for badge color name
# Usage: get_badge_hex_color "green"
# Output: hex color code (e.g., "#4c1")
get_badge_hex_color() {
	local color="${1:-green}"

	case "$color" in
	red)
		echo "#e05d44"
		;;
	yellow)
		echo "#dfb317"
		;;
	green)
		echo "#97ca00"
		;;
	brightgreen)
		echo "#4c1"
		;;
	blue)
		echo "#007ec6"
		;;
	lightgrey | lightgray)
		echo "#9f9f9f"
		;;
	*)
		echo "#9f9f9f"
		;;
	esac
}

# =============================================================================
# Badge generation
# =============================================================================

# Generate an SVG coverage badge
# Usage: generate_badge_svg 85.5 "badge.svg" [label] [red_threshold] [yellow_threshold]
generate_badge_svg() {
	local percent="${1:-0}"
	local output="${2:-badge.svg}"
	local label="${3:-coverage}"
	local red_threshold="${4:-50}"
	local yellow_threshold="${5:-80}"

	# Format percentage for display
	local display_percent
	display_percent=$(printf "%.1f%%" "$percent")

	# Get color
	local color hex_color
	color=$(get_badge_color "$percent" "$red_threshold" "$yellow_threshold")
	hex_color=$(get_badge_hex_color "$color")

	# Calculate widths based on text length
	local label_width text_width total_width
	label_width=$((${#label} * 7 + 10))
	text_width=$((${#display_percent} * 7 + 10))
	total_width=$((label_width + text_width))

	# Generate SVG using shields.io style
	cat >"$output" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${total_width}" height="20" role="img" aria-label="${label}: ${display_percent}">
  <title>${label}: ${display_percent}</title>
  <linearGradient id="s" x2="0" y2="100%">
    <stop offset="0" stop-color="#bbb" stop-opacity=".1"/>
    <stop offset="1" stop-opacity=".1"/>
  </linearGradient>
  <clipPath id="r">
    <rect width="${total_width}" height="20" rx="3" fill="#fff"/>
  </clipPath>
  <g clip-path="url(#r)">
    <rect width="${label_width}" height="20" fill="#555"/>
    <rect x="${label_width}" width="${text_width}" height="20" fill="${hex_color}"/>
    <rect width="${total_width}" height="20" fill="url(#s)"/>
  </g>
  <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" text-rendering="geometricPrecision" font-size="110">
    <text aria-hidden="true" x="$((label_width * 5))" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)" textLength="$((label_width * 10 - 100))">${label}</text>
    <text x="$((label_width * 5))" y="140" transform="scale(.1)" fill="#fff" textLength="$((label_width * 10 - 100))">${label}</text>
    <text aria-hidden="true" x="$((label_width * 10 + text_width * 5))" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)" textLength="$((text_width * 10 - 100))">${display_percent}</text>
    <text x="$((label_width * 10 + text_width * 5))" y="140" transform="scale(.1)" fill="#fff" textLength="$((text_width * 10 - 100))">${display_percent}</text>
  </g>
</svg>
EOF

	echo "$output"
}

# Generate a JSON badge endpoint for shields.io dynamic badges
# Usage: generate_badge_json 85.5 "badge.json" [label] [red_threshold] [yellow_threshold]
generate_badge_json() {
	local percent="${1:-0}"
	local output="${2:-badge.json}"
	local label="${3:-coverage}"
	local red_threshold="${4:-50}"
	local yellow_threshold="${5:-80}"

	# Format percentage for display
	local display_percent
	display_percent=$(printf "%.1f%%" "$percent")

	# Get color
	local color
	color=$(get_badge_color "$percent" "$red_threshold" "$yellow_threshold")

	# Generate shields.io endpoint JSON format
	cat >"$output" <<EOF
{
  "schemaVersion": 1,
  "label": "${label}",
  "message": "${display_percent}",
  "color": "${color}"
}
EOF

	echo "$output"
}

# Generate shields.io URL for a badge
# Usage: get_shields_url 85.5 [label] [style]
# Output: shields.io badge URL
get_shields_url() {
	local percent="${1:-0}"
	local label="${2:-coverage}"
	local style="${3:-flat}"

	local display_percent color
	display_percent=$(printf "%.1f%%" "$percent")
	color=$(get_badge_color "$percent")

	# URL encode the label and message
	local encoded_label encoded_message
	encoded_label=$(echo -n "$label" | jq -sRr @uri 2>/dev/null || echo "$label")
	encoded_message=$(echo -n "$display_percent" | jq -sRr @uri 2>/dev/null || echo "$display_percent")

	echo "https://img.shields.io/badge/${encoded_label}-${encoded_message}-${color}?style=${style}"
}

# =============================================================================
# Test status badges
# =============================================================================

# Generate a test status badge
# Usage: generate_test_badge "passed" "test-badge.svg" [passed_count] [failed_count]
generate_test_badge() {
	local status="${1:-unknown}"
	local output="${2:-test-badge.svg}"
	local passed="${3:-0}"
	local failed="${4:-0}"

	local label="tests"
	local message color hex_color

	case "$status" in
	passed)
		if [[ "$passed" -gt 0 ]]; then
			message="${passed} passed"
		else
			message="passed"
		fi
		color="brightgreen"
		;;
	failed)
		if [[ "$failed" -gt 0 ]]; then
			message="${failed} failed"
		else
			message="failed"
		fi
		color="red"
		;;
	*)
		message="unknown"
		color="lightgrey"
		;;
	esac

	hex_color=$(get_badge_hex_color "$color")

	# Calculate widths
	local label_width text_width total_width
	label_width=$((${#label} * 7 + 10))
	text_width=$((${#message} * 7 + 10))
	total_width=$((label_width + text_width))

	# Generate SVG
	cat >"$output" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${total_width}" height="20" role="img" aria-label="${label}: ${message}">
  <title>${label}: ${message}</title>
  <linearGradient id="s" x2="0" y2="100%">
    <stop offset="0" stop-color="#bbb" stop-opacity=".1"/>
    <stop offset="1" stop-opacity=".1"/>
  </linearGradient>
  <clipPath id="r">
    <rect width="${total_width}" height="20" rx="3" fill="#fff"/>
  </clipPath>
  <g clip-path="url(#r)">
    <rect width="${label_width}" height="20" fill="#555"/>
    <rect x="${label_width}" width="${text_width}" height="20" fill="${hex_color}"/>
    <rect width="${total_width}" height="20" fill="url(#s)"/>
  </g>
  <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" text-rendering="geometricPrecision" font-size="110">
    <text aria-hidden="true" x="$((label_width * 5))" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)" textLength="$((label_width * 10 - 100))">${label}</text>
    <text x="$((label_width * 5))" y="140" transform="scale(.1)" fill="#fff" textLength="$((label_width * 10 - 100))">${label}</text>
    <text aria-hidden="true" x="$((label_width * 10 + text_width * 5))" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)" textLength="$((text_width * 10 - 100))">${message}</text>
    <text x="$((label_width * 10 + text_width * 5))" y="140" transform="scale(.1)" fill="#fff" textLength="$((text_width * 10 - 100))">${message}</text>
  </g>
</svg>
EOF

	echo "$output"
}

# =============================================================================
# Export functions
# =============================================================================
export -f get_badge_color get_badge_hex_color
export -f generate_badge_svg generate_badge_json get_shields_url
export -f generate_test_badge
