#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for stage-node-pages-coverage.sh

load "../../../helpers/common"

setup() {
	setup_temp_dir
	cd "$BATS_TEST_TMPDIR" || return 1
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/stage-node-pages-coverage.sh"
}

teardown() {
	teardown_temp_dir
}

@test "stage-node-pages-coverage: copies coverage tree to flat staging dir" {
	mkdir -p apps/web/coverage
	echo '<html>coverage</html>' >apps/web/coverage/index.html

	run env WORKING_DIRECTORY=apps/web PAGES_COVERAGE_STAGING_DIR=flat-coverage bash "$SCRIPT"
	assert_success
	assert_file_exists flat-coverage/index.html
	run grep -q 'coverage' flat-coverage/index.html
	assert_success
}

@test "stage-node-pages-coverage: fails when source directory is missing" {
	run env WORKING_DIRECTORY=missing bash "$SCRIPT"
	assert_failure
	assert_output --partial "Pages coverage source directory missing"
}

@test "stage-node-pages-coverage: fails when index.html is missing" {
	mkdir -p coverage
	run env WORKING_DIRECTORY=. bash "$SCRIPT"
	assert_failure
	assert_output --partial "Pages coverage HTML missing index.html"
}

@test "stage-node-pages-coverage: honors pages-coverage-source-subpath" {
	mkdir -p reports/html
	echo '<html>report</html>' >reports/html/index.html

	run env WORKING_DIRECTORY=. PAGES_COVERAGE_SOURCE_SUBPATH=reports/html \
		PAGES_COVERAGE_STAGING_DIR=staged bash "$SCRIPT"
	assert_success
	assert_file_exists staged/index.html
}
