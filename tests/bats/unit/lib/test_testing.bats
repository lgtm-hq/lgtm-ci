#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/testing.sh (aggregator)

load "../../../helpers/common"

setup() {
	if [[ -z "${LIB_DIR:-}" ]]; then
		echo "ERROR: LIB_DIR is not set — common.bash may have failed to load" >&2
		return 1
	fi
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# Aggregator loading tests
# =============================================================================

@test "testing.sh: sources testing/detect.sh" {
	run bash -c 'source "$LIB_DIR/testing.sh" && declare -f detect_test_runner >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "testing.sh: sources testing/parse.sh" {
	run bash -c 'source "$LIB_DIR/testing.sh" && declare -f parse_junit_xml >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "testing.sh: sources testing/coverage.sh" {
	run bash -c 'source "$LIB_DIR/testing.sh" && declare -f check_coverage_threshold >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "testing.sh: sources testing/badge.sh" {
	run bash -c 'source "$LIB_DIR/testing.sh" && declare -f generate_badge_svg >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

# =============================================================================
# Error handling tests
# =============================================================================

@test "testing.sh: aggregator pattern reports syntax errors in submodules" {
	# Create a minimal aggregator that sources a broken submodule
	local fake_dir="${BATS_TEST_TMPDIR}/test_aggregator"
	mkdir -p "${fake_dir}"

	echo 'if [[ ; then' >"${fake_dir}/broken.sh"

	cat >"${fake_dir}/aggregator.sh" <<'SCRIPT'
#!/usr/bin/env bash
_AGG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_AGG_DIR/broken.sh"
SCRIPT

	run bash -c "source '${fake_dir}/aggregator.sh' 2>&1"
	assert_failure
	assert_output --partial "syntax error"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "testing.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/testing.sh"
		source "$LIB_DIR/testing.sh"
		declare -f detect_test_runner >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "testing.sh: sets _LGTM_CI_TESTING_LOADED guard" {
	run bash -c 'source "$LIB_DIR/testing.sh" && echo "${_LGTM_CI_TESTING_LOADED}"'
	assert_success
	assert_output "1"
}
