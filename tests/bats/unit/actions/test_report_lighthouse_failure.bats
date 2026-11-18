#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/report-lighthouse-failure.sh (#1624)

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/report-lighthouse-failure.sh"
AUDIT="::error::Lighthouse audit failed. Categories below threshold: performance"

@test "report-lighthouse-failure.sh: reports a failed audit and fails" {
	run env AUDIT_FAILED=true AUDIT_ERROR="$AUDIT" LHCI_EXIT_CODE=0 bash "$SCRIPT"
	assert_failure 1
	assert_output "$AUDIT"
}

@test "report-lighthouse-failure.sh: reports a failed lhci run and fails" {
	run env AUDIT_FAILED=false AUDIT_ERROR="$AUDIT" LHCI_EXIT_CODE=3 bash "$SCRIPT"
	assert_failure 1
	assert_output "::error::Lighthouse CI exited with code 3"
}

@test "report-lighthouse-failure.sh: reports both causes, audit first" {
	run env AUDIT_FAILED=true AUDIT_ERROR="$AUDIT" LHCI_EXIT_CODE=2 bash "$SCRIPT"
	assert_failure 1
	assert_line --index 0 "$AUDIT"
	assert_line --index 1 "::error::Lighthouse CI exited with code 2"
}

@test "report-lighthouse-failure.sh: fails silently when no cause is set" {
	run env -u AUDIT_FAILED -u LHCI_EXIT_CODE bash "$SCRIPT"
	assert_failure 1
	assert_output ""
}
