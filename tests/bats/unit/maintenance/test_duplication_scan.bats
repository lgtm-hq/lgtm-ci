#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Offline fixture coverage for duplication_scan.py / duplication_model.py.

load "../../../helpers/common"

setup() {
	require_python_yaml
	export PYTHONDONTWRITEBYTECODE=1
	CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_checks.py"
	TRANSPORT_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_transport_checks.py"
	REGRESSION_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_regression_checks.py"
	PYTHON_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_python_checks.py"
}

check_case() {
	run "$PY" "${2:-$CHECKS}" "Cases.$1"
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
	check_case test_transport_and_pagination "$TRANSPORT_CHECKS"
}

@test "duplication scan rejects truncated repository trees" {
	check_case test_truncated_tree_fails "$TRANSPORT_CHECKS"
}

@test "duplication scan workflow preserves security runner and rollout contracts" {
	check_case test_workflow_contract "$TRANSPORT_CHECKS"
}

@test "duplication scan rollout stays dry until enabled and honors dispatch input" {
	check_case test_rollout_gate_behavior "$TRANSPORT_CHECKS"
}

@test "duplication scan dry-run integrates enumeration exceptions redaction and summary" {
	check_case test_end_to_end_dry_run "$TRANSPORT_CHECKS"
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
	check_case test_graphql_errors_and_missing_repository "$TRANSPORT_CHECKS"
}

@test "duplication scan batches blob reads and skips only known empty repositories" {
	check_case test_files_batches_and_empty_repositories "$TRANSPORT_CHECKS"
}

@test "duplication scan continues with partial coverage for invalid oversized or binary source" {
	check_case test_partial_scan "$TRANSPORT_CHECKS"
}

@test "duplication scan threshold controls public near-match suggestions" {
	check_case test_threshold_controls_near_matches
}

@test "duplication scan skips until App secrets and the allowlist exist" {
	check_case test_readiness_skips_missing_setup "$TRANSPORT_CHECKS"
}

@test "duplication scan App must cover all repositories with read-only contents" {
	check_case test_readiness_requires_all_repositories "$TRANSPORT_CHECKS"
}

@test "duplication scan live transport uses the issue token and tolerates empty repos" {
	check_case test_live_transport_end_to_end "$TRANSPORT_CHECKS"
}

@test "duplication scan and other generated workflow preset maps stay in sync" {
	run bash "${PROJECT_ROOT}/scripts/ci/egress/sync-workflow-presets.sh" --check
	assert_success
}

@test "duplication scan resolves scripts under step job and workflow working directories" {
	check_case test_working_directory_and_defaults "$REGRESSION_CHECKS"
}

@test "duplication scan distinguishes implicit shell from explicit and inherited bash" {
	check_case test_implicit_shell "$REGRESSION_CHECKS"
}

@test "duplication scan matches ordinary Python path strings across repositories" {
	check_case test_python_path_parameters "$REGRESSION_CHECKS"
}

@test "duplication scan keeps Python process commands conservative" {
	check_case test_python_process_commands "$REGRESSION_CHECKS"
}

@test "duplication scan keeps uninspected local Python imports repository-specific" {
	check_case test_python_local_imports "$PYTHON_CHECKS"
}

@test "duplication scan compares unshadowed stdlib imports and retains Python control flow" {
	check_case test_python_stdlib_imports "$PYTHON_CHECKS"
}

@test "duplication scan resolves executable positions and treats script arguments as data" {
	check_case test_script_arguments_are_data "$REGRESSION_CHECKS"
}

@test "duplication scan keeps shell directory changes from resolving matching root copies" {
	check_case test_shell_directory_changes "$REGRESSION_CHECKS"
}

@test "duplication scan compares script bodies behind supported wrappers and shell keywords" {
	check_case test_wrapped_script_identity "$REGRESSION_CHECKS"
}

@test "duplication scan keeps ambiguous wrapper executables repository-specific" {
	check_case test_ambiguous_wrapper_identity "$REGRESSION_CHECKS"
}

@test "duplication scan preserves script-like data around groups keywords and wrappers" {
	check_case test_wrapped_script_data "$REGRESSION_CHECKS"
}

@test "duplication scan blocks all reconciliation mutations when source coverage is partial" {
	check_case test_partial_inventory_blocks_reconciliation "$TRANSPORT_CHECKS"
}

@test "duplication scan isolates unknown external programs and resolves available bodies" {
	check_case test_external_programs "$REGRESSION_CHECKS"
}

@test "duplication scan fetches external script and local action dependencies" {
	check_case test_fetch_external_dependencies "$REGRESSION_CHECKS"
}

@test "duplication scan compares local action contents with cycle and missing guards" {
	check_case test_local_actions "$REGRESSION_CHECKS"
}

@test "duplication scan matches valid jobs against compatible catalog operation sequences" {
	check_case test_catalog_sequence_compatibility "$REGRESSION_CHECKS"
}

@test "duplication scan retains quoted whitespace in standalone scripts" {
	check_case test_quoted_script_whitespace "$REGRESSION_CHECKS"
}

@test "duplication scan escapes marker injection through all public fields" {
	check_case test_public_identifier_marker_injection "$REGRESSION_CHECKS"
}

@test "duplication scan preserves human titles and handles web line endings" {
	check_case test_human_titles_and_crlf "$REGRESSION_CHECKS"
}

@test "duplication scan caches repeated script dependency resolution" {
	check_case test_dependency_memoization "$REGRESSION_CHECKS"
}

@test "duplication scan readiness also works outside GitHub Actions" {
	check_case test_local_readiness_without_output "$REGRESSION_CHECKS"
}

@test "duplication scan rejects malformed catalog roots before indexing" {
	check_case test_catalog_shape_validation "$REGRESSION_CHECKS"
}
