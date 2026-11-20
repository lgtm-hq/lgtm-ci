#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Well-formed coverage, test-result and security inputs render as
# main's scripts did through every entry point no other golden covers (#1692)

load "../../../helpers/common"
load "../../../helpers/entrypoint_golden"

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "entry points: well-formed reports convert, summarise, badge, parse and format as on main (#1692)" {
	run entrypoint_golden_render "${BATS_TEST_TMPDIR}/golden"
	assert_success
	assert_output "$(cat "${PROJECT_ROOT}/tests/fixtures/entrypoint-golden/well-formed.main.txt")"
}
