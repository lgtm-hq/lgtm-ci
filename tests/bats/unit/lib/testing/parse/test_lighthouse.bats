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
	assert_output "perf=0 a11y=0 ret=1"
}

@test "parse_lighthouse_json: returns failure for empty file path" {
	run bash -c '
		source "$LIB_DIR/testing/parse/lighthouse.sh"
		parse_lighthouse_json ""
		ret=$?
		echo "perf=$LH_PERFORMANCE ret=$ret"
	'
	assert_success
	assert_output "perf=0 ret=1"
}

# =============================================================================
# parse_lighthouse_json tests - standard LHR format
# =============================================================================

@test "parse_lighthouse_json: parses all category scores" {
	cat >"${BATS_TEST_TMPDIR}/lhr.json" <<'EOF'
{
  "categories": {
    "performance": {"score": 0.85},
    "accessibility": {"score": 0.92},
    "best-practices": {"score": 0.88},
    "seo": {"score": 0.95},
    "pwa": {"score": 0.60}
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/lighthouse.sh\"
		parse_lighthouse_json \"${BATS_TEST_TMPDIR}/lhr.json\"
		echo \"perf=\$LH_PERFORMANCE a11y=\$LH_ACCESSIBILITY bp=\$LH_BEST_PRACTICES seo=\$LH_SEO pwa=\$LH_PWA\"
	"
	assert_success
	assert_output "perf=85 a11y=92 bp=88 seo=95 pwa=60"
}

@test "parse_lighthouse_json: handles 100% scores" {
	cat >"${BATS_TEST_TMPDIR}/lhr.json" <<'EOF'
{
  "categories": {
    "performance": {"score": 1.0},
    "accessibility": {"score": 1.0},
    "best-practices": {"score": 1.0},
    "seo": {"score": 1.0},
    "pwa": {"score": 1.0}
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/lighthouse.sh\"
		parse_lighthouse_json \"${BATS_TEST_TMPDIR}/lhr.json\"
		echo \"perf=\$LH_PERFORMANCE a11y=\$LH_ACCESSIBILITY\"
	"
	assert_success
	assert_output "perf=100 a11y=100"
}

@test "parse_lighthouse_json: handles 0% scores" {
	cat >"${BATS_TEST_TMPDIR}/lhr.json" <<'EOF'
{
  "categories": {
    "performance": {"score": 0},
    "accessibility": {"score": 0},
    "best-practices": {"score": 0},
    "seo": {"score": 0}
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/lighthouse.sh\"
		parse_lighthouse_json \"${BATS_TEST_TMPDIR}/lhr.json\"
		echo \"perf=\$LH_PERFORMANCE a11y=\$LH_ACCESSIBILITY\"
	"
	assert_success
	assert_output "perf=0 a11y=0"
}

@test "parse_lighthouse_json: handles missing PWA category" {
	cat >"${BATS_TEST_TMPDIR}/lhr.json" <<'EOF'
{
  "categories": {
    "performance": {"score": 0.90},
    "accessibility": {"score": 0.95},
    "best-practices": {"score": 0.85},
    "seo": {"score": 0.88}
  }
}
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/lighthouse.sh\"
		parse_lighthouse_json \"${BATS_TEST_TMPDIR}/lhr.json\"
		echo \"pwa=\$LH_PWA\"
	"
	assert_success
	assert_output "pwa=0"
}

@test "parse_lighthouse_json: floors decimal scores correctly" {
	cat >"${BATS_TEST_TMPDIR}/lhr.json" <<'EOF'
{
  "categories": {
    "performance": {"score": 0.899},
    "accessibility": {"score": 0.501},
    "best-practices": {"score": 0.999},
    "seo": {"score": 0.001}
  }
}
EOF

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
	cat >"${BATS_TEST_TMPDIR}/manifest.json" <<'EOF'
[
  {"url": "https://example.com/", "summary": "./lhr-0.json"},
  {"url": "https://example.com/about", "summary": "./lhr-1.json"},
  {"url": "https://example.com/contact", "summary": "./lhr-2.json"}
]
EOF

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
	cat >"${BATS_TEST_TMPDIR}/manifest.json" <<'EOF'
[
  {"url": "https://example.com/", "summary": "./lhr.json"}
]
EOF

	run bash -c "
		source \"\$LIB_DIR/testing/parse/lighthouse.sh\"
		parse_lighthouse_manifest \"${BATS_TEST_TMPDIR}/manifest.json\"
		echo \"\$LH_URLS\"
	"
	assert_success
	assert_output "https://example.com/"
}

@test "parse_lighthouse_manifest: handles empty manifest" {
	cat >"${BATS_TEST_TMPDIR}/manifest.json" <<'EOF'
[]
EOF

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
	# All scores default to 0, all fail
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
