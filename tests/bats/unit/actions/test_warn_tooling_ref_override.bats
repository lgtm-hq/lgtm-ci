#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/warn-tooling-ref-override.sh (#995)

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/warn-tooling-ref-override.sh"

@test "warn-tooling-ref-override: silent when no override is passed" {
	run env TOOLING_REF_OVERRIDE="" WORKFLOW_SHA="abc" bash "$SCRIPT"
	assert_success
	assert_output ""
}

@test "warn-tooling-ref-override: silent when the variable is unset" {
	run env -u TOOLING_REF_OVERRIDE bash "$SCRIPT"
	assert_success
	assert_output ""
}

@test "warn-tooling-ref-override: emits a workflow warning when an override is set" {
	run env TOOLING_REF_OVERRIDE="deadbeef" bash "$SCRIPT"
	assert_success
	assert_output --partial "::warning title=tooling-ref override::"
	assert_output --partial "tooling-ref is no longer required"
	refute_output --partial "differs from"
}

@test "warn-tooling-ref-override: names both commits when the override differs from the pin" {
	run env TOOLING_REF_OVERRIDE="deadbeef" WORKFLOW_SHA="cafef00d" bash "$SCRIPT"
	assert_success
	assert_output --partial "override deadbeef differs from workflow pin cafef00d"
}

@test "warn-tooling-ref-override: no drift note when the override equals the pin" {
	run env TOOLING_REF_OVERRIDE="cafef00d" WORKFLOW_SHA="cafef00d" bash "$SCRIPT"
	assert_success
	refute_output --partial "differs from"
}
