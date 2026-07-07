#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/egress-audit.sh

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="scripts/ci/actions/egress-audit.sh"

setup() {
	setup_temp_dir
	setup_github_env
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

@test "egress-audit: fails without STEP" {
	run env -u STEP bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "STEP is required"
}

@test "egress-audit: fails on unknown step" {
	STEP="bogus" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "Unknown step"
}

@test "egress-audit: setup normalizes and dedupes allowed domains" {
	STEP="setup" ALLOWED_DOMAINS="b.example.com, a.example.com,b.example.com , " \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	run cat "${RUNNER_TEMP}/egress-audit/allowed-domains.txt"
	assert_output "a.example.com
b.example.com"
}

@test "egress-audit: setup writes log-dir output" {
	STEP="setup" ALLOWED_DOMAINS="example.com" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_file_contains "$GITHUB_OUTPUT" "log-dir=${RUNNER_TEMP}/egress-audit"
}

@test "egress-audit: audit initializes log and outputs" {
	STEP="setup" ALLOWED_DOMAINS="example.com" bash "${PROJECT_ROOT}/${SCRIPT}"

	STEP="audit" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	assert_file_exists "${RUNNER_TEMP}/egress-audit/egress.log"
	assert_file_contains "$GITHUB_OUTPUT" "egress-log=${RUNNER_TEMP}/egress-audit/egress.log"
	assert_file_contains "$GITHUB_OUTPUT" "violations-detected=false"
}

@test "egress-audit: audit notes block mode enforcement" {
	STEP="setup" ALLOWED_DOMAINS="example.com" bash "${PROJECT_ROOT}/${SCRIPT}"

	STEP="audit" MODE="block" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "harden-runner"
}

@test "egress-audit: report fails when setup has not run" {
	STEP="report" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "Setup step must run before report"
}

@test "egress-audit: report writes summary with allowed domains" {
	STEP="setup" ALLOWED_DOMAINS="example.com" bash "${PROJECT_ROOT}/${SCRIPT}"

	STEP="report" REPORT_FORMAT="summary" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	run get_github_step_summary
	assert_output --partial "Egress Audit Report"
	assert_output --partial "example.com"
}

@test "egress-audit: report writes json report" {
	STEP="setup" ALLOWED_DOMAINS="a.example.com,b.example.com" bash "${PROJECT_ROOT}/${SCRIPT}"

	STEP="report" REPORT_FORMAT="json" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	local report="${RUNNER_TEMP}/egress-audit/report.json"
	assert_file_exists "$report"
	run jq -r '.allowed_domains | length' "$report"
	assert_output "2"
	run jq -r '.violations_detected' "$report"
	assert_output "false"
}
