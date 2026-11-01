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
	SHELL_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_shell_checks.py"
	PYTHON_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_python_checks.py"
	COVERAGE_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_coverage_checks.py"
	INLINE_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_inline_checks.py"
	INTERPRETER_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_interpreter_checks.py"
}

check_case() {
	run "$PY" "${2:-$CHECKS}" "${3:-Cases}.$1"
	assert_success
}

@test "duplication scan redacts history after initial inventory transport or shape failure" {
	check_case test_initial_inventory_privacy_cleanup "$COVERAGE_CHECKS"
}

@test "duplication scan preserves initial failure when historical cleanup fails" {
	check_case test_initial_inventory_cleanup_failure "$COVERAGE_CHECKS"
}

@test "duplication scan initial inventory success retains live and no-write controls" {
	check_case test_initial_inventory_success_controls "$COVERAGE_CHECKS"
}

@test "duplication scan preserves Python comparison string content" {
	check_case test_python_comparison_strings "$PYTHON_CHECKS" StringCases
}

@test "duplication scan preserves Python regular-expression string content" {
	check_case test_python_regex_strings "$PYTHON_CHECKS" StringCases
}

@test "duplication scan restricts Python path parameters to direct constructor literals" {
	check_case test_python_path_parameter_context "$PYTHON_CHECKS" StringCases
}

@test "duplication scan revision preserves parameter word adjacency in standalone scripts" {
	check_case test_parameter_word_script_adjacency "$SHELL_CHECKS" ShellCases
}

@test "duplication scan revision preserves parameter word adjacency in called scripts" {
	check_case test_parameter_word_called_adjacency "$SHELL_CHECKS" ShellCases
}

@test "duplication scan revision guards incomplete double-quoted parameter expansions" {
	check_case test_quoted_parameter_opacity "$SHELL_CHECKS" ShellCases
}

@test "duplication scan revision keeps hidden shell executables out of clusters" {
	check_case test_quoted_parameter_inventory "$SHELL_CHECKS" ShellCases
}

@test "duplication scan revision keeps Python f-string expressions opaque" {
	check_case test_python_fstring_expressions "$PYTHON_CHECKS"
}

@test "duplication scan revision guards Python f-string inventory paths" {
	check_case test_python_fstring_inventory "$PYTHON_CHECKS"
}

@test "duplication scan revision guards Python f-string executable dependencies" {
	check_case test_python_fstring_dependencies "$PYTHON_CHECKS"
}

@test "duplication scan regression validates visibility across coverage snapshots" {
	check_case test_visibility_coverage_snapshots "$COVERAGE_CHECKS"
}

@test "duplication scan regression rechecks visibility before publication" {
	check_case test_publication_visibility_recheck "$COVERAGE_CHECKS"
}

@test "duplication scan regression rechecks visibility after source failure" {
	check_case test_failed_scan_visibility_recheck "$COVERAGE_CHECKS"
}

@test "duplication scan regression cleans every historical example on partial scans" {
	check_case test_multiple_example_privacy_cleanup
}

@test "duplication scan regression refreshes every historical example independently" {
	check_case test_multiple_example_refresh
}

@test "duplication scan regression preserves external action subpath case" {
	check_case test_external_action_subpath_case
}

@test "duplication scan bare runner Python retains conditional suite membership" {
	check_case test_bare_runner_python_flow "$INTERPRETER_CHECKS"
}

@test "duplication scan bare runner Python retains floor division operands" {
	check_case test_bare_runner_python_operators "$INTERPRETER_CHECKS"
}

@test "duplication scan keeps unsupported runner dispatch repository-specific" {
	check_case test_runner_execution_opaque "$INTERPRETER_CHECKS"
}

@test "duplication scan caches runner execution independently of direct interpreters" {
	check_case test_runner_execution_memoization "$INTERPRETER_CHECKS"
}

@test "duplication scan runner identity survives nested actions and Python imports" {
	check_case test_runner_nested_actions_and_dependencies "$INTERPRETER_CHECKS"
}

@test "duplication scan script interpreters preserve Python flow in non-Python filenames" {
	check_case test_python_non_python_suffix_flow "$INTERPRETER_CHECKS"
}

@test "duplication scan script interpreters normalize shell code in Python filenames" {
	check_case test_shell_python_suffix "$INTERPRETER_CHECKS"
}

@test "duplication scan script interpreters follow direct shebangs before suffixes" {
	check_case test_direct_shebang_parser "$INTERPRETER_CHECKS"
}

@test "duplication scan script interpreters memoize each execution identity separately" {
	check_case test_interpreter_memoization "$INTERPRETER_CHECKS"
}

@test "duplication scan script interpreters keep unsupported and ambiguous execution opaque" {
	check_case test_unsupported_script_interpreters "$INTERPRETER_CHECKS"
}

@test "duplication scan script interpreters still compare safe equivalent Python" {
	check_case test_interpreter_safe_equivalence "$INTERPRETER_CHECKS"
}

@test "duplication scan inline Python preserves indentation under effective shells" {
	check_case test_inline_python_indentation "$INLINE_CHECKS"
}

@test "duplication scan inline Python compares safe equivalent token structures" {
	check_case test_inline_python_equivalence "$INLINE_CHECKS"
}

@test "duplication scan inline run normalization follows step job workflow shell precedence" {
	check_case test_effective_shell_precedence "$INLINE_CHECKS"
}

@test "duplication scan inline runs keep unsupported and dynamic shells opaque" {
	check_case test_unsupported_run_shells "$INLINE_CHECKS"
}

@test "duplication scan inline Python reuses import and process dependency guards" {
	check_case test_inline_python_dependencies "$INLINE_CHECKS"
}

@test "duplication scan inline run shell declarations retain literal executable and arguments" {
	check_case test_literal_run_shells "$INLINE_CHECKS"
}

@test "duplication scan inline runs preserve shell identity in recursive local actions" {
	check_case test_recursive_run_shells "$INLINE_CHECKS"
}

@test "duplication scan inline runs still normalize ordinary shell templates" {
	check_case test_supported_shell_templates "$INLINE_CHECKS"
}

@test "duplication scan keeps multiprocessing executable selection opaque" {
	check_case test_python_multiprocessing_executable_selection "$PYTHON_CHECKS"
}

@test "duplication scan keeps event-loop subprocess methods opaque" {
	check_case test_python_loop_subprocess_launchers "$PYTHON_CHECKS"
}

@test "duplication scan keeps computed namespace and native launchers opaque" {
	check_case test_python_namespace_launchers "$PYTHON_CHECKS"
}

@test "duplication scan proves source installation coverage before normal mutations" {
	check_case test_source_installation_coverage "$COVERAGE_CHECKS"
}

@test "duplication scan blocks malformed or unreadable source coverage metadata" {
	check_case test_invalid_coverage_metadata "$COVERAGE_CHECKS"
}

@test "duplication scan requires independent all-repository App grant evidence" {
	check_case test_independent_app_coverage "$COVERAGE_CHECKS"
}

@test "duplication scan verifies every installation and inventory page" {
	check_case test_coverage_pagination "$COVERAGE_CHECKS"
}

@test "duplication scan coverage failures preserve historical privacy and membership" {
	check_case test_coverage_privacy_cleanup "$COVERAGE_CHECKS"
}

@test "duplication scan keeps concatenated shell words distinct from separate arguments" {
	check_case test_shell_word_concatenation "$SHELL_CHECKS" ShellCases
}

@test "duplication scan keeps heredoc payloads opaque in command shapes" {
	check_case test_heredoc_command_shapes "$SHELL_CHECKS" ShellCases
}

@test "duplication scan regression guards parameter hash heredocs" {
	check_case test_parameter_hash_heredocs "$SHELL_CHECKS" ShellCases
}

@test "duplication scan regression guards parameter hash executables" {
	check_case test_parameter_hash_executables "$SHELL_CHECKS" ShellCases
}

@test "duplication scan regression keeps parameter substitutions opaque" {
	check_case test_parameter_substitutions_opaque "$SHELL_CHECKS" ShellCases
}

@test "duplication scan regression guards POSIX nested subshell heredocs" {
	check_case test_posix_nested_subshell_heredocs "$SHELL_CHECKS" ShellCases
}

@test "duplication scan regression guards escaped quotes before heredocs" {
	check_case test_escaped_quotes_heredocs "$SHELL_CHECKS" ShellCases
}

@test "duplication scan regression preserves shell comment words before executables" {
	check_case test_shell_comment_words_executables "$SHELL_CHECKS" ShellCases
}

@test "duplication scan regression guards continued directory commands" {
	check_case test_continued_directory_commands "$SHELL_CHECKS" ShellCases
}

@test "duplication scan regression preserves shell lexing controls" {
	check_case test_shell_lexing_controls "$SHELL_CHECKS" ShellCases
}

@test "duplication scan keeps heredoc workflow and script inventories repository-scoped" {
	check_case test_heredoc_inventory "$SHELL_CHECKS" ShellCases
}

@test "duplication scan preserves heredoc-like quoted data and comment boundaries" {
	check_case test_heredoc_literal_boundaries "$SHELL_CHECKS" ShellCases
}

@test "duplication scan preserves shebang identity for directly executed scripts" {
	check_case test_direct_script_shebangs "$SHELL_CHECKS" ShellCases
}

@test "duplication scan cleans historical privacy independently of clusters and source coverage" {
	check_case test_independent_privacy_cleanup "$TRANSPORT_CHECKS"
}

@test "duplication scan cleans historical privacy after failed tree and blob API reads" {
	check_case test_failed_inventory_privacy_cleanup "$TRANSPORT_CHECKS"
}

@test "duplication scan cleans historical privacy after malformed source API responses" {
	check_case test_malformed_inventory_privacy_cleanup "$TRANSPORT_CHECKS"
}

@test "duplication scan keeps computed Python process launchers opaque" {
	check_case test_python_computed_process_launchers "$PYTHON_CHECKS"
}

@test "duplication scan keeps Windows startfile process launchers opaque" {
	check_case test_python_startfile_launchers "$PYTHON_CHECKS"
}

@test "duplication scan still compares ordinary Python launcher strings and data paths" {
	check_case test_python_launcher_data_controls "$PYTHON_CHECKS"
}

@test "duplication scan cleans suppressed issue source without changing adoption decisions" {
	check_case test_suppressed_source_privacy "$TRANSPORT_CHECKS"
}

@test "duplication scan keeps runpy file and module execution repository-specific" {
	check_case test_python_runpy_execution "$PYTHON_CHECKS"
}

@test "duplication scan preserves Python numeric strings unless versions are explicit inputs" {
	check_case test_python_numeric_strings "$PYTHON_CHECKS"
}

@test "duplication scan preserves decimal command durations thresholds and timeouts" {
	check_case test_decimal_command_arguments "$PYTHON_CHECKS"
}

@test "duplication scan keeps uninspected Python module invocations repository-specific" {
	check_case test_python_module_commands "$PYTHON_CHECKS"
}

@test "duplication scan preserves Python numeric thresholds in scripts and workflow calls" {
	check_case test_python_numeric_thresholds "$PYTHON_CHECKS"
}

@test "duplication scan still masks Python path parameters and safe version inputs" {
	check_case test_python_known_parameters "$PYTHON_CHECKS"
}

@test "duplication scan preserves Python floor division and augmented assignment" {
	check_case test_python_operators "$PYTHON_CHECKS"
}

@test "duplication scan marks non-mapping YAML roots invalid and blocks writes" {
	check_case test_non_mapping_yaml_roots "$TRANSPORT_CHECKS"
}

@test "duplication scan readiness rejects malformed existing allowlists" {
	check_case test_readiness_validates_exceptions "$TRANSPORT_CHECKS"
}

@test "duplication scan redacts historical source when public repositories become private" {
	check_case test_historical_source_privacy
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
	check_case test_live_transport_end_to_end "$COVERAGE_CHECKS"
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

@test "duplication scan keeps Python eval and compile execution repository-specific" {
	check_case test_python_dynamic_evaluation "$REGRESSION_CHECKS"
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
