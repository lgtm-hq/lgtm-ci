#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing/parse/lighthouse.sh

load "../../../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# parse_lighthouse_json tests - file handling
# =============================================================================

@test "parse_lighthouse_json: returns failure for nonexistent file" {
	run bash -c '
		source "$LIB_DIR/testing/parse/lighthouse.sh"
		parse_lighthouse_json "/nonexistent/lhr.json"
		ret=$?
		echo "perf=$LH_PERFORMANCE a11y=$LH_ACCESSIBILITY ret=$ret"
	'
	assert_success
	# No report: every score is unreadable, never 0 (#1692).
	assert_output "perf=invalid a11y=invalid ret=1"
}

@test "parse_lighthouse_json: returns failure for empty file path" {
	run bash -c '
		source "$LIB_DIR/testing/parse/lighthouse.sh"
		parse_lighthouse_json ""
		ret=$?
		echo "perf=$LH_PERFORMANCE ret=$ret"
	'
	assert_success
	assert_output "perf=invalid ret=1"
}

# =============================================================================
# parse_lighthouse_json tests - standard LHR format
# =============================================================================

@test "parse_lighthouse_json: parses all category scores" {
	install_fixture "lighthouse/parse-lighthouse-json-parses-all-category-scores.json" "${BATS_TEST_TMPDIR}/lhr.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/lighthouse.sh\"
		parse_lighthouse_json \"${BATS_TEST_TMPDIR}/lhr.json\"
		echo \"perf=\$LH_PERFORMANCE a11y=\$LH_ACCESSIBILITY bp=\$LH_BEST_PRACTICES seo=\$LH_SEO pwa=\$LH_PWA\"
	"
	assert_success
	assert_output "perf=85 a11y=92 bp=88 seo=95 pwa=60"
}

@test "parse_lighthouse_json: handles 100% scores" {
	install_fixture "lighthouse/parse-lighthouse-json-handles-100-scores.json" "${BATS_TEST_TMPDIR}/lhr.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/lighthouse.sh\"
		parse_lighthouse_json \"${BATS_TEST_TMPDIR}/lhr.json\"
		echo \"perf=\$LH_PERFORMANCE a11y=\$LH_ACCESSIBILITY\"
	"
	assert_success
	assert_output "perf=100 a11y=100"
}

@test "parse_lighthouse_json: handles 0% scores" {
	install_fixture "lighthouse/parse-lighthouse-json-handles-0-scores.json" "${BATS_TEST_TMPDIR}/lhr.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/lighthouse.sh\"
		parse_lighthouse_json \"${BATS_TEST_TMPDIR}/lhr.json\"
		echo \"perf=\$LH_PERFORMANCE a11y=\$LH_ACCESSIBILITY\"
	"
	assert_success
	assert_output "perf=0 a11y=0"
}

@test "parse_lighthouse_json: handles missing PWA category" {
	install_fixture "lighthouse/parse-lighthouse-json-handles-missing-pwa-category.json" "${BATS_TEST_TMPDIR}/lhr.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/lighthouse.sh\"
		parse_lighthouse_json \"${BATS_TEST_TMPDIR}/lhr.json\"
		echo \"pwa=\$LH_PWA\"
	"
	assert_success
	assert_output "pwa=0"
}

@test "parse_lighthouse_json: floors decimal scores correctly" {
	install_fixture "lighthouse/parse-lighthouse-json-floors-decimal-scores-correctly.json" "${BATS_TEST_TMPDIR}/lhr.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/lighthouse.sh\"
		parse_lighthouse_json \"${BATS_TEST_TMPDIR}/lhr.json\"
		echo \"perf=\$LH_PERFORMANCE a11y=\$LH_ACCESSIBILITY bp=\$LH_BEST_PRACTICES seo=\$LH_SEO\"
	"
	assert_success
	# 0.899 * 100 = 89.9, floor = 89
	# 0.501 * 100 = 50.1, floor = 50
	# 0.999 * 100 = 99.9, floor = 99
	# 0.001 * 100 = 0.1, floor = 0
	assert_output "perf=89 a11y=50 bp=99 seo=0"
}

# =============================================================================
# parse_lighthouse_manifest tests
# =============================================================================

@test "parse_lighthouse_manifest: returns failure for nonexistent file" {
	run bash -c '
		source "$LIB_DIR/testing/parse/lighthouse.sh"
		parse_lighthouse_manifest "/nonexistent/manifest.json"
		ret=$?
		echo "urls=$LH_URLS ret=$ret"
	'
	assert_success
	assert_output "urls= ret=1"
}

@test "parse_lighthouse_manifest: extracts URLs from manifest" {
	install_fixture "lighthouse/parse-lighthouse-manifest-extracts-urls-from-manifest.json" "${BATS_TEST_TMPDIR}/manifest.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/lighthouse.sh\"
		parse_lighthouse_manifest \"${BATS_TEST_TMPDIR}/manifest.json\"
		echo \"\$LH_URLS\"
	"
	assert_success
	assert_line --partial "https://example.com/"
	assert_line --partial "https://example.com/about"
	assert_line --partial "https://example.com/contact"
}

@test "parse_lighthouse_manifest: handles single URL" {
	install_fixture "lighthouse/parse-lighthouse-manifest-handles-single-url.json" "${BATS_TEST_TMPDIR}/manifest.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/lighthouse.sh\"
		parse_lighthouse_manifest \"${BATS_TEST_TMPDIR}/manifest.json\"
		echo \"\$LH_URLS\"
	"
	assert_success
	assert_output "https://example.com/"
}

@test "parse_lighthouse_manifest: handles empty manifest" {
	install_fixture "lighthouse/parse-lighthouse-manifest-handles-empty-manifest.json" "${BATS_TEST_TMPDIR}/manifest.json"

	run bash -c "
		source \"\$LIB_DIR/testing/parse/lighthouse.sh\"
		parse_lighthouse_manifest \"${BATS_TEST_TMPDIR}/manifest.json\"
		echo \"urls=\$LH_URLS\"
	"
	assert_success
	assert_output "urls="
}

# =============================================================================
# check_lighthouse_thresholds tests
# =============================================================================

@test "check_lighthouse_thresholds: passes when all scores meet defaults" {
	run bash -c '
		source "$LIB_DIR/testing/parse/lighthouse.sh"
		LH_PERFORMANCE=85
		LH_ACCESSIBILITY=95
		LH_BEST_PRACTICES=85
		LH_SEO=85
		check_lighthouse_thresholds
		echo "result=$? failed=$LH_FAILED_CATEGORIES"
	'
	assert_success
	assert_output "result=0 failed="
}

@test "check_lighthouse_thresholds: fails when performance below threshold" {
	run bash -c '
		source "$LIB_DIR/testing/parse/lighthouse.sh"
		LH_PERFORMANCE=70
		LH_ACCESSIBILITY=95
		LH_BEST_PRACTICES=85
		LH_SEO=85
		check_lighthouse_thresholds 80 90 80 80
		status=$?
		echo "failed=$LH_FAILED_CATEGORIES"
		exit "$status"
	'
	assert_failure
	assert_output "failed=performance"
}

@test "check_lighthouse_thresholds: fails when accessibility below threshold" {
	run bash -c '
		source "$LIB_DIR/testing/parse/lighthouse.sh"
		LH_PERFORMANCE=85
		LH_ACCESSIBILITY=80
		LH_BEST_PRACTICES=85
		LH_SEO=85
		check_lighthouse_thresholds 80 90 80 80
		status=$?
		echo "failed=$LH_FAILED_CATEGORIES"
		exit "$status"
	'
	assert_failure
	assert_output "failed=accessibility"
}

@test "check_lighthouse_thresholds: reports multiple failures" {
	run bash -c '
		source "$LIB_DIR/testing/parse/lighthouse.sh"
		LH_PERFORMANCE=70
		LH_ACCESSIBILITY=80
		LH_BEST_PRACTICES=70
		LH_SEO=70
		check_lighthouse_thresholds 80 90 80 80
		status=$?
		echo "failed=$LH_FAILED_CATEGORIES"
		exit "$status"
	'
	assert_failure
	assert_output "failed=performance,accessibility,best-practices,seo"
}

@test "check_lighthouse_thresholds: uses custom thresholds" {
	run bash -c '
		source "$LIB_DIR/testing/parse/lighthouse.sh"
		LH_PERFORMANCE=50
		LH_ACCESSIBILITY=50
		LH_BEST_PRACTICES=50
		LH_SEO=50
		check_lighthouse_thresholds 40 40 40 40
		echo "result=$? failed=$LH_FAILED_CATEGORIES"
	'
	assert_success
	assert_output "result=0 failed="
}

@test "check_lighthouse_thresholds: passes at exact threshold" {
	run bash -c '
		source "$LIB_DIR/testing/parse/lighthouse.sh"
		LH_PERFORMANCE=80
		LH_ACCESSIBILITY=90
		LH_BEST_PRACTICES=80
		LH_SEO=80
		check_lighthouse_thresholds 80 90 80 80
		echo "result=$? failed=$LH_FAILED_CATEGORIES"
	'
	assert_success
	assert_output "result=0 failed="
}

@test "check_lighthouse_thresholds: handles unset score variables" {
	run bash -c '
		source "$LIB_DIR/testing/parse/lighthouse.sh"
		unset LH_PERFORMANCE LH_ACCESSIBILITY LH_BEST_PRACTICES LH_SEO
		check_lighthouse_thresholds 80 90 80 80
		status=$?
		echo "failed=$LH_FAILED_CATEGORIES"
		exit "$status"
	'
	assert_failure
	# An unset score is unreadable and fails (#1692)
	assert_output "failed=performance,accessibility,best-practices,seo"
}

# =============================================================================
# format_lighthouse_summary tests
# =============================================================================

@test "format_lighthouse_summary: formats all scores" {
	run bash -c '
		source "$LIB_DIR/testing/parse/lighthouse.sh"
		LH_PERFORMANCE=85
		LH_ACCESSIBILITY=92
		LH_BEST_PRACTICES=88
		LH_SEO=95
		format_lighthouse_summary
	'
	assert_success
	assert_output "Performance: 85, Accessibility: 92, Best Practices: 88, SEO: 95"
}

@test "format_lighthouse_summary: handles 0 scores" {
	run bash -c '
		source "$LIB_DIR/testing/parse/lighthouse.sh"
		LH_PERFORMANCE=0
		LH_ACCESSIBILITY=0
		LH_BEST_PRACTICES=0
		LH_SEO=0
		format_lighthouse_summary
	'
	assert_success
	assert_output "Performance: 0, Accessibility: 0, Best Practices: 0, SEO: 0"
}

@test "format_lighthouse_summary: handles 100 scores" {
	run bash -c '
		source "$LIB_DIR/testing/parse/lighthouse.sh"
		LH_PERFORMANCE=100
		LH_ACCESSIBILITY=100
		LH_BEST_PRACTICES=100
		LH_SEO=100
		format_lighthouse_summary
	'
	assert_success
	assert_output "Performance: 100, Accessibility: 100, Best Practices: 100, SEO: 100"
}

@test "format_lighthouse_summary: uses defaults when unset" {
	run bash -c '
		source "$LIB_DIR/testing/parse/lighthouse.sh"
		unset LH_PERFORMANCE LH_ACCESSIBILITY LH_BEST_PRACTICES LH_SEO
		format_lighthouse_summary
	'
	assert_success
	assert_output "Performance: 0, Accessibility: 0, Best Practices: 0, SEO: 0"
}

# =============================================================================
# Function export tests
# =============================================================================

@test "testing/parse/lighthouse.sh: exports parse_lighthouse_json function" {
	run bash -c 'source "$LIB_DIR/testing/parse/lighthouse.sh" && bash -c "type parse_lighthouse_json"'
	assert_success
}

@test "testing/parse/lighthouse.sh: exports parse_lighthouse_manifest function" {
	run bash -c 'source "$LIB_DIR/testing/parse/lighthouse.sh" && bash -c "type parse_lighthouse_manifest"'
	assert_success
}

@test "testing/parse/lighthouse.sh: exports check_lighthouse_thresholds function" {
	run bash -c 'source "$LIB_DIR/testing/parse/lighthouse.sh" && bash -c "type check_lighthouse_thresholds"'
	assert_success
}

@test "testing/parse/lighthouse.sh: exports format_lighthouse_summary function" {
	run bash -c 'source "$LIB_DIR/testing/parse/lighthouse.sh" && bash -c "type format_lighthouse_summary"'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "testing/parse/lighthouse.sh: sets guard variable" {
	run bash -c 'source "$LIB_DIR/testing/parse/lighthouse.sh" && echo "${_LGTM_CI_TESTING_PARSE_LIGHTHOUSE_LOADED}"'
	assert_success
	assert_output "1"
}

# =============================================================================
# Unreadable scores (#1692): never 0, never a pass
# =============================================================================

# Writes a report whose performance score is the JSON value $1 (or no
# performance category with "absent"); the other three scores are 1.
write_report() {
	local file="${BATS_TEST_TMPDIR}/lhr.json"
	if [[ "$1" == absent ]]; then
		printf '%s' '{"categories":{"accessibility":{"score":1},"best-practices":{"score":1},"seo":{"score":1}}}' >"$file"
	else
		printf '{"categories":{"performance":{"score":%s},"accessibility":{"score":1},"best-practices":{"score":1},"seo":{"score":1}}}' \
			"$1" >"$file"
	fi
}

@test "parse_lighthouse_json: a score that is not a number from 0 to 1 is unreadable, never 0 or 150 (#1692)" {
	local score
	for score in 1.5 -0.1 '"1"' null absent true '{}'; do
		write_report "$score"
		run bash -c '
			source "$LIB_DIR/testing/parse/lighthouse.sh"
			parse_lighthouse_json "$1"
			echo "ret=$? perf=$LH_PERFORMANCE a11y=$LH_ACCESSIBILITY unreadable=$LH_UNREADABLE"
			check_lighthouse_thresholds 0 0 0 0
			echo "thresholds=$? failed=$LH_FAILED_CATEGORIES"
		' _ "${BATS_TEST_TMPDIR}/lhr.json"
		assert_success
		assert_line "ret=0 perf=invalid a11y=100 unreadable=performance"
		assert_line "thresholds=1 failed=performance"
	done
}

@test "parse_lighthouse_json: a category that is not an object, or a file that is not JSON, is unreadable (#1692)" {
	local file="${BATS_TEST_TMPDIR}/lhr.json" body
	for body in '{"categories":{"performance":0.9,"accessibility":{"score":1},"best-practices":{"score":1},"seo":{"score":1}}}' \
		'{"categories":[]}' 'not json {'; do
		printf '%s' "$body" >"$file"
		run bash -c '
			source "$LIB_DIR/testing/parse/lighthouse.sh"
			parse_lighthouse_json "$1"
			echo "perf=$LH_PERFORMANCE unreadable=$LH_UNREADABLE"
		' _ "$file"
		assert_success
		assert_output --partial "perf=invalid unreadable=performance"
	done
}

@test "parse_lighthouse_json: a missing file fails every threshold, even 0 (#1692)" {
	run bash -c '
		source "$LIB_DIR/testing/parse/lighthouse.sh"
		parse_lighthouse_json /nonexistent/lhr.json
		echo "ret=$? unreadable=$LH_UNREADABLE"
		check_lighthouse_thresholds 0 0 0 0
		echo "thresholds=$? failed=$LH_FAILED_CATEGORIES"
	'
	assert_success
	assert_line "ret=1 unreadable=performance,accessibility,best-practices,seo"
	assert_line "thresholds=1 failed=performance,accessibility,best-practices,seo"
}

@test "check_lighthouse_thresholds: a score above 100 never passes (#1692)" {
	run bash -c '
		source "$LIB_DIR/testing/parse/lighthouse.sh"
		LH_PERFORMANCE=150 LH_ACCESSIBILITY=100 LH_BEST_PRACTICES=0 LH_SEO=99
		check_lighthouse_thresholds 80 90 0 80
		echo "thresholds=$? failed=$LH_FAILED_CATEGORIES"
	'
	assert_success
	assert_output "thresholds=1 failed=performance"
}
