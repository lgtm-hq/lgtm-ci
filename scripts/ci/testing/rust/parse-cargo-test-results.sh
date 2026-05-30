#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Parse cargo test output for reusable Rust test workflows
#
# Environment variables:
#   TEST_LOG_FILE - Path to cargo test log (default: rust-test.log)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"

: "${TEST_LOG_FILE:=rust-test.log}"

if [[ ! -f "$TEST_LOG_FILE" ]]; then
	log_warn "Test log not found: $TEST_LOG_FILE"
	set_github_output "tests-passed" "0"
	set_github_output "tests-failed" "0"
	set_github_output "tests-total" "0"
	set_github_output "tests-ran" "false"
	exit 0
fi

tests_passed=0
tests_failed=0
tests_ignored=0

if grep -q 'test result:' "$TEST_LOG_FILE"; then
	result_lines="$(grep 'test result:' "$TEST_LOG_FILE" || true)"
	tests_passed="$(grep -oE '[0-9]+ passed' <<<"$result_lines" | awk '{sum += $1} END {print sum + 0}')"
	tests_failed="$(grep -oE '[0-9]+ failed' <<<"$result_lines" | awk '{sum += $1} END {print sum + 0}')"
	tests_ignored="$(grep -oE '[0-9]+ ignored' <<<"$result_lines" | awk '{sum += $1} END {print sum + 0}')"
fi

# Total executed tests only — ignored tests must not reduce pass rate in PR comments.
tests_total=$((tests_passed + tests_failed))
tests_observed=$((tests_passed + tests_failed + tests_ignored))

set_github_output "tests-passed" "$tests_passed"
set_github_output "tests-failed" "$tests_failed"
set_github_output "tests-total" "$tests_total"
if [[ "$tests_observed" -gt 0 ]]; then
	set_github_output "tests-ran" "true"
else
	set_github_output "tests-ran" "false"
fi

log_info "Parsed tests: passed=$tests_passed failed=$tests_failed ignored=$tests_ignored total=$tests_total"
