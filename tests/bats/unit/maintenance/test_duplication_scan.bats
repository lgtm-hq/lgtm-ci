#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Offline fixture coverage for duplication_scan.py / duplication_model.py.

load "../../../helpers/common"

setup() {
	require_python_yaml
	export PYTHONDONTWRITEBYTECODE=1
	CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_checks.py"
}

check_case() {
	run "$PY" "$CHECKS" "Cases.$1"
	assert_success
}

@test "duplication scan clusters parameter-only jobs and excludes product-specific logic" {
	check_case test_near_identical_jobs
}

@test "duplication scan includes short copied scripts" {
	check_case test_small_scripts
}

@test "duplication scan requires matching control flow" {
	check_case test_parameter_only_control_flow
}

@test "duplication scan retains step order" {
	check_case test_order_matters
}

@test "duplication scan removes comments while retaining quoted programs" {
	check_case test_comments_and_quotes
}

@test "duplication scan compares called scripts as logic rather than path inputs" {
	check_case test_called_scripts_are_logic
}

@test "duplication scan preserves Python indentation and shell command boundaries" {
	check_case test_python_indentation_and_shell_boundaries
}

@test "duplication scan parse errors never expose private source" {
	check_case test_private_parse_error_redaction
}

@test "duplication scan can match inline jobs against catalog composites" {
	check_case test_composite_matches_job
}

@test "duplication scan applies job-specific and whole-path exceptions" {
	check_case test_allowlist
}

@test "duplication scan fails closed on missing or invalid allowlists" {
	check_case test_allowlist_fail_closed
}

@test "duplication scan detects an existing catalog implementation" {
	check_case test_catalog_match
}

@test "duplication scan excludes existing reusable callers" {
	check_case test_adopted_calls_skipped
}

@test "duplication scan never renders private job names inputs or source" {
	check_case test_private_redaction
}

@test "duplication scan updates membership without changing cluster identity" {
	check_case test_stable_membership_and_updates
}

@test "duplication scan rerun creates no duplicate issues" {
	check_case test_rerun_deduplication
}

@test "duplication scan suppresses not-planned closures silently" {
	check_case test_not_planned_silent
}

@test "duplication scan reopens completed issues with a comment" {
	check_case test_completed_reopens
}

@test "duplication scan caps new issues at five and dry-run never writes" {
	check_case test_cap_and_dry_run
}

@test "duplication scan separates read and write tokens and reads all pages" {
	check_case test_transport_and_pagination
}

@test "duplication scan rejects truncated repository trees" {
	check_case test_truncated_tree_fails
}

@test "duplication scan workflow preserves security runner and rollout contracts" {
	check_case test_workflow_contract
}

@test "duplication scan rollout stays dry until enabled and honors dispatch input" {
	check_case test_rollout_gate_behavior
}

@test "duplication scan dry-run integrates enumeration exceptions redaction and summary" {
	check_case test_end_to_end_dry_run
}

@test "duplication scan retains executable inputs environments and job metadata" {
	check_case test_execution_inputs_and_metadata
}

@test "duplication scan resolves exact nested extensionless and cyclic scripts" {
	check_case test_exact_nested_and_extensionless_scripts
}

@test "duplication scan preserves shell substitution and arithmetic operators" {
	check_case test_shell_expansions
}

@test "duplication scan prevents markers in snippets from spoofing cluster identity" {
	check_case test_marker_spoofing
}

@test "duplication scan preserves human edits and ignores pin-only body changes" {
	check_case test_preserves_human_edits_and_pin_bumps
}

@test "duplication scan rejects GraphQL errors and inaccessible repositories" {
	check_case test_graphql_errors_and_missing_repository
}

@test "duplication scan batches blob reads and skips only known empty repositories" {
	check_case test_files_batches_and_empty_repositories
}

@test "duplication scan continues with partial coverage for invalid oversized or binary source" {
	check_case test_partial_scan
}

@test "duplication scan threshold controls public near-match suggestions" {
	check_case test_threshold_controls_near_matches
}

@test "duplication scan skips until App secrets and the allowlist exist" {
	check_case test_readiness_skips_missing_setup
}

@test "duplication scan App must cover all repositories with read-only contents" {
	check_case test_readiness_requires_all_repositories
}

@test "duplication scan live transport uses the issue token and tolerates empty repos" {
	check_case test_live_transport_end_to_end
}

@test "duplication scan and other generated workflow preset maps stay in sync" {
	run bash "${PROJECT_ROOT}/scripts/ci/egress/sync-workflow-presets.sh" --check
	assert_success
}
