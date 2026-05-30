#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Regression tests for stage-node-coverage.sh matrix layout

load "../../../helpers/common"

setup() {
	setup_temp_dir
	cd "$BATS_TEST_TMPDIR" || exit 1
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/stage-node-coverage.sh"
}

teardown() {
	teardown_temp_dir
}

@test "stage-node-coverage: keeps matrix-specific nested layout" {
	mkdir -p apps/web/coverage
	echo '{}' >apps/web/coverage/coverage-summary.json
	echo '{}' >apps/web/vitest-results.json

	NODE_VERSION=22 WORKING_DIRECTORY=apps/web run bash "$SCRIPT"
	assert_success
	assert_file_exists node-coverage-22/apps/web/coverage/coverage-summary.json
	assert_file_exists node-coverage-22/apps/web/vitest-results.json
	run test ! -e pages-coverage-html
	assert_success
}
