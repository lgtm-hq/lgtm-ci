#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing/badge.sh

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
	export BATS_TEST_TMPDIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# get_badge_color tests
# =============================================================================

@test "get_badge_color: returns red for coverage below 50" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_badge_color 25'
	assert_success
	assert_output "red"
}

@test "get_badge_color: returns yellow for coverage between 50-80" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_badge_color 65'
	assert_success
	assert_output "yellow"
}

@test "get_badge_color: returns green for coverage between 80-90" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_badge_color 85'
	assert_success
	assert_output "green"
}

@test "get_badge_color: returns brightgreen for coverage >= 90" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_badge_color 95'
	assert_success
	assert_output "brightgreen"
}

@test "get_badge_color: uses custom red threshold" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_badge_color 40 30 70'
	assert_success
	assert_output "yellow"
}

@test "get_badge_color: uses custom yellow threshold" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_badge_color 75 50 70'
	assert_success
	assert_output "green"
}

@test "get_badge_color: handles zero coverage" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_badge_color 0'
	assert_success
	assert_output "red"
}

@test "get_badge_color: handles 100 coverage" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_badge_color 100'
	assert_success
	assert_output "brightgreen"
}

@test "get_badge_color: handles decimal coverage" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_badge_color 85.5'
	assert_success
	assert_output "green"
}

# =============================================================================
# get_badge_hex_color tests
# =============================================================================

@test "get_badge_hex_color: returns correct hex for red" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_badge_hex_color "red"'
	assert_success
	assert_output "#e05d44"
}

@test "get_badge_hex_color: returns correct hex for yellow" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_badge_hex_color "yellow"'
	assert_success
	assert_output "#dfb317"
}

@test "get_badge_hex_color: returns correct hex for green" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_badge_hex_color "green"'
	assert_success
	assert_output "#97ca00"
}

@test "get_badge_hex_color: returns correct hex for brightgreen" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_badge_hex_color "brightgreen"'
	assert_success
	assert_output "#44cc11"
}

@test "get_badge_hex_color: returns correct hex for blue" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_badge_hex_color "blue"'
	assert_success
	assert_output "#007ec6"
}

@test "get_badge_hex_color: returns correct hex for lightgrey" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_badge_hex_color "lightgrey"'
	assert_success
	assert_output "#9f9f9f"
}

@test "get_badge_hex_color: returns default for unknown color" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_badge_hex_color "unknown"'
	assert_success
	assert_output "#9f9f9f"
}

# =============================================================================
# escape_xml tests
# =============================================================================

@test "escape_xml: escapes ampersand" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && escape_xml "a & b"'
	assert_success
	assert_output "a &amp; b"
}

@test "escape_xml: escapes less than" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && escape_xml "a < b"'
	assert_success
	assert_output "a &lt; b"
}

@test "escape_xml: escapes greater than" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && escape_xml "a > b"'
	assert_success
	assert_output "a &gt; b"
}

@test "escape_xml: escapes double quotes" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && escape_xml "a \"b\" c"'
	assert_success
	assert_output "a &quot;b&quot; c"
}

@test "escape_xml: escapes single quotes" {
	run bash -c "source \"\$LIB_DIR/testing/badge.sh\" && escape_xml \"a 'b' c\""
	assert_success
	assert_output "a &#39;b&#39; c"
}

@test "escape_xml: handles empty string" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && escape_xml ""'
	assert_success
	assert_output ""
}

@test "escape_xml: handles multiple special characters" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && escape_xml "<script>alert(\"xss\");</script>"'
	assert_success
	assert_output "&lt;script&gt;alert(&quot;xss&quot;);&lt;/script&gt;"
}

# =============================================================================
# generate_badge_svg tests
# =============================================================================

@test "generate_badge_svg: creates SVG file" {
	local output="${BATS_TEST_TMPDIR}/badge.svg"
	run bash -c "source \"\$LIB_DIR/testing/badge.sh\" && generate_badge_svg 85.5 \"$output\""
	assert_success
	[[ -f "$output" ]]
}

@test "generate_badge_svg: SVG contains coverage percentage" {
	local output="${BATS_TEST_TMPDIR}/badge.svg"
	run bash -c "source \"\$LIB_DIR/testing/badge.sh\" && generate_badge_svg 85.5 \"$output\" && cat \"$output\""
	assert_success
	assert_output --partial "85.5%"
}

@test "generate_badge_svg: SVG contains label" {
	local output="${BATS_TEST_TMPDIR}/badge.svg"
	run bash -c "source \"\$LIB_DIR/testing/badge.sh\" && generate_badge_svg 85 \"$output\" \"coverage\" && cat \"$output\""
	assert_success
	assert_output --partial "coverage"
}

@test "generate_badge_svg: SVG uses custom label" {
	local output="${BATS_TEST_TMPDIR}/badge.svg"
	run bash -c "source \"\$LIB_DIR/testing/badge.sh\" && generate_badge_svg 85 \"$output\" \"tests\" && cat \"$output\""
	assert_success
	assert_output --partial "tests"
}

@test "generate_badge_svg: returns output path" {
	local output="${BATS_TEST_TMPDIR}/badge.svg"
	run bash -c "source \"\$LIB_DIR/testing/badge.sh\" && generate_badge_svg 85 \"$output\""
	assert_success
	assert_output "$output"
}

# =============================================================================
# generate_badge_json tests
# =============================================================================

@test "generate_badge_json: creates JSON file" {
	local output="${BATS_TEST_TMPDIR}/badge.json"
	run bash -c "source \"\$LIB_DIR/testing/badge.sh\" && generate_badge_json 85.5 \"$output\""
	assert_success
	[[ -f "$output" ]]
}

@test "generate_badge_json: JSON contains schemaVersion" {
	local output="${BATS_TEST_TMPDIR}/badge.json"
	run bash -c "source \"\$LIB_DIR/testing/badge.sh\" && generate_badge_json 85 \"$output\" && cat \"$output\""
	assert_success
	assert_output --partial '"schemaVersion": 1'
}

@test "generate_badge_json: JSON contains percentage" {
	local output="${BATS_TEST_TMPDIR}/badge.json"
	run bash -c "source \"\$LIB_DIR/testing/badge.sh\" && generate_badge_json 85 \"$output\" && cat \"$output\""
	assert_success
	assert_output --partial '"message": "85.0%"'
}

@test "generate_badge_json: JSON contains color" {
	local output="${BATS_TEST_TMPDIR}/badge.json"
	run bash -c "source \"\$LIB_DIR/testing/badge.sh\" && generate_badge_json 85 \"$output\" && cat \"$output\""
	assert_success
	assert_output --partial '"color": "green"'
}

# =============================================================================
# generate_test_badge tests
# =============================================================================

@test "generate_test_badge: creates badge for passed tests" {
	local output="${BATS_TEST_TMPDIR}/test-badge.svg"
	run bash -c "source \"\$LIB_DIR/testing/badge.sh\" && generate_test_badge \"passed\" \"$output\" 10 0 && cat \"$output\""
	assert_success
	assert_output --partial "10 passed"
}

@test "generate_test_badge: creates badge for failed tests" {
	local output="${BATS_TEST_TMPDIR}/test-badge.svg"
	run bash -c "source \"\$LIB_DIR/testing/badge.sh\" && generate_test_badge \"failed\" \"$output\" 0 5 && cat \"$output\""
	assert_success
	assert_output --partial "5 failed"
}

@test "generate_test_badge: creates badge for unknown status" {
	local output="${BATS_TEST_TMPDIR}/test-badge.svg"
	run bash -c "source \"\$LIB_DIR/testing/badge.sh\" && generate_test_badge \"unknown\" \"$output\" && cat \"$output\""
	assert_success
	assert_output --partial "unknown"
}

@test "generate_test_badge: passed with zero count shows just passed" {
	local output="${BATS_TEST_TMPDIR}/test-badge.svg"
	run bash -c "source \"\$LIB_DIR/testing/badge.sh\" && generate_test_badge \"passed\" \"$output\" 0 0 && cat \"$output\""
	assert_success
	assert_output --partial "passed"
}

@test "generate_test_badge: failed with zero count shows just failed" {
	local output="${BATS_TEST_TMPDIR}/test-badge.svg"
	run bash -c "source \"\$LIB_DIR/testing/badge.sh\" && generate_test_badge \"failed\" \"$output\" 0 0 && cat \"$output\""
	assert_success
	assert_output --partial "failed"
}

# =============================================================================
# get_shields_url tests
# =============================================================================

@test "get_shields_url: returns valid URL" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_shields_url 85.5'
	assert_success
	assert_output --partial "https://img.shields.io/badge/"
	assert_output --partial "coverage"
	assert_output --partial "green"
}

@test "get_shields_url: uses custom label" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_shields_url 50 "tests"'
	assert_success
	assert_output --partial "tests"
}

@test "get_shields_url: uses custom style" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_shields_url 50 "coverage" "for-the-badge"'
	assert_success
	assert_output --partial "style=for-the-badge"
}

@test "get_shields_url: low coverage shows red" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_shields_url 20'
	assert_success
	assert_output --partial "red"
}

@test "get_shields_url: high coverage shows brightgreen" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_shields_url 95'
	assert_success
	assert_output --partial "brightgreen"
}

@test "get_shields_url: includes percentage in URL" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_shields_url 85.5'
	assert_success
	assert_output --partial "85.5"
}

# =============================================================================
# generate_badge_svg tests - additional cases
# =============================================================================

@test "generate_badge_svg: uses custom thresholds" {
	local output="${BATS_TEST_TMPDIR}/badge.svg"
	run bash -c "source \"\$LIB_DIR/testing/badge.sh\" && generate_badge_svg 45 \"$output\" \"coverage\" 30 60 && cat \"$output\""
	assert_success
	assert_output --partial "45.0%"
	# 45 is between 30 (red) and 60 (yellow), so should be yellow
	assert_output --partial "#dfb317"
}

@test "generate_badge_svg: creates valid SVG structure" {
	local output="${BATS_TEST_TMPDIR}/badge.svg"
	run bash -c "source \"\$LIB_DIR/testing/badge.sh\" && generate_badge_svg 75 \"$output\" && cat \"$output\""
	assert_success
	assert_output --partial '<svg xmlns='
	assert_output --partial '</svg>'
	assert_output --partial 'clipPath'
}

# =============================================================================
# get_badge_hex_color tests - additional cases
# =============================================================================

@test "get_badge_hex_color: returns correct hex for lightgray (alternate spelling)" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && get_badge_hex_color "lightgray"'
	assert_success
	assert_output "#9f9f9f"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "badge.sh: exports get_badge_color function" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && bash -c "get_badge_color 85"'
	assert_success
	assert_output "green"
}

@test "badge.sh: exports escape_xml function" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && bash -c "escape_xml test"'
	assert_success
	assert_output "test"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "badge.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/testing/badge.sh"
		source "$LIB_DIR/testing/badge.sh"
		source "$LIB_DIR/testing/badge.sh"
		get_badge_color 85
	'
	assert_success
	assert_output "green"
}

@test "badge.sh: sets _LGTM_CI_TESTING_BADGE_LOADED guard" {
	run bash -c 'source "$LIB_DIR/testing/badge.sh" && echo "${_LGTM_CI_TESTING_BADGE_LOADED}"'
	assert_success
	assert_output "1"
}
