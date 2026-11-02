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
	SELECTION_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_selection_checks.py"
	PYTHON_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_python_checks.py"
	COVERAGE_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_coverage_checks.py"
	INLINE_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_inline_checks.py"
	INTERPRETER_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_interpreter_checks.py"
	REVISION_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_revision_checks.py"
	PUBLICATION_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_publication_checks.py"
	RUNNER_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_runner_checks.py"
	REVIEW_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_review_checks.py"
	ESCAPE_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_escape_checks.py"
	GENERATION_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_generation_checks.py"
	DEPENDENCY_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_dependency_checks.py"
	YAML_CHECKS="${PROJECT_ROOT}/tests/helpers/duplication_scan_yaml_checks.py"
}

check_case() {
	run "$PY" "${2:-$CHECKS}" "${3:-Cases}.$1"
	assert_success
}

@test "duplication scan dependency coverage ignores shell and Python comments" {
	check_case test_comment_dependencies "$DEPENDENCY_CHECKS"
}

@test "duplication scan dependency coverage ignores YAML comments descriptions and data" {
	check_case test_yaml_data_dependencies "$DEPENDENCY_CHECKS"
}

@test "duplication scan dependency coverage blocks genuine oversized external scripts" {
	check_case test_executable_oversized_dependencies "$DEPENDENCY_CHECKS"
}

@test "duplication scan dependency coverage preserves YAML execution contexts" {
	check_case test_yaml_executable_dependencies "$DEPENDENCY_CHECKS"
}

@test "duplication scan dependency coverage keeps unknown execution opaque" {
	check_case test_opaque_dependency_controls "$DEPENDENCY_CHECKS"
}

@test "duplication scan dependency coverage preserves reachable YAML environment" {
	check_case test_yaml_reachable_environment "$DEPENDENCY_CHECKS"
}

@test "duplication scan dependency coverage preserves reachable YAML inputs" {
	check_case test_yaml_reachable_inputs "$DEPENDENCY_CHECKS"
}

@test "duplication scan dependency coverage preserves runtime Python docstrings" {
	check_case test_python_runtime_docstrings "$DEPENDENCY_CHECKS"
}

@test "duplication scan dependency coverage preserves external Python docstrings" {
	check_case test_python_external_docstrings "$DEPENDENCY_CHECKS"
}

@test "duplication scan dependency coverage preserves reachable YAML matrix" {
	check_case test_yaml_reachable_matrix "$DEPENDENCY_CHECKS"
}

@test "duplication scan dependency coverage preserves Docker execution metadata" {
	check_case test_docker_execution_dependencies "$DEPENDENCY_CHECKS"
}

@test "duplication scan dependency coverage respects Python newline coordinates" {
	check_case test_python_dependency_coordinates "$DEPENDENCY_CHECKS"
}

@test "duplication scan dependency coverage protects compiler warning privacy" {
	check_case test_python_compiler_warning_privacy "$DEPENDENCY_CHECKS"
}

@test "duplication scan dependency coverage fails closed on invalid YAML defaults" {
	check_case test_invalid_yaml_dependency_fallback "$DEPENDENCY_CHECKS"
}

@test "duplication scan dependency coverage preserves runtime YAML configuration" {
	check_case test_runtime_yaml_configuration "$DEPENDENCY_CHECKS"
}

@test "duplication scan dependency coverage preserves container and shell execution" {
	check_case test_container_and_shell_dependencies "$DEPENDENCY_CHECKS"
}

@test "duplication scan dependency coverage preserves Bash startup dependencies" {
	check_case test_bash_startup_dependencies "$DEPENDENCY_CHECKS"
}

@test "duplication scan dependency coverage fails closed on recursive YAML aliases" {
	check_case test_recursive_yaml_aliases "$DEPENDENCY_CHECKS"
}

@test "duplication scan dependency coverage distinguishes runtime YAML schema paths" {
	check_case test_runtime_yaml_schema_paths "$YAML_CHECKS"
}

@test "duplication scan dependency coverage preserves scoped YAML mapping keys" {
	check_case test_scoped_yaml_mapping_keys "$YAML_CHECKS"
}

@test "duplication scan dependency coverage bounds repeated YAML alias hints" {
	check_case test_bounded_yaml_alias_hints "$YAML_CHECKS"
}

@test "duplication scan dependency coverage preserves opaque hash-prefixed runtime data" {
	check_case test_opaque_runtime_data "$YAML_CHECKS"
}

@test "duplication scan dependency coverage preserves reachable output values" {
	check_case test_reachable_output_values "$YAML_CHECKS"
}

@test "duplication scan dependency coverage retains templated comment expressions" {
	check_case test_templated_comment_dependencies "$YAML_CHECKS"
}

@test "duplication scan dependency coverage retains escaped execution data" {
	check_case test_escaped_execution_data "$YAML_CHECKS"
}

@test "duplication scan dependency coverage keeps escaped data scoped" {
	check_case test_escaped_data_scope_controls "$YAML_CHECKS"
}

@test "duplication scan dependency coverage retains runtime conditions" {
	check_case test_runtime_conditions "$YAML_CHECKS"
}

@test "duplication scan dependency coverage keeps literal comment controls inert" {
	check_case test_literal_comment_controls "$YAML_CHECKS"
}

@test "duplication scan R11 excludes cross-step and called-writer inventory and catalog matches" {
	check_case test_cross_step_generated_inventory "$GENERATION_CHECKS"
}

@test "duplication scan R11 excludes cross-step and called-writer adoption in the offline CLI" {
	check_case test_cross_step_generated_cli "$GENERATION_CHECKS"
}

@test "duplication scan R11 blocks stale script and composite lookups after writes" {
	check_case test_cross_step_generated_lookup_guards "$GENERATION_CHECKS"
}

@test "duplication scan R11 retains cross-step literal redirects and safe controls" {
	check_case test_cross_step_generated_literal_controls "$GENERATION_CHECKS"
}

@test "duplication scan R10 excludes generated executable bodies from inventory and catalog" {
	check_case test_generated_script_inventory "$GENERATION_CHECKS"
}

@test "duplication scan R10 excludes generated executable callers from the offline CLI" {
	check_case test_generated_script_cli "$GENERATION_CHECKS"
}

@test "duplication scan R10 guards executable writes before dependency lookup" {
	check_case test_generated_script_guards "$GENERATION_CHECKS"
}

@test "duplication scan R10 retains literal redirection controls and inspected bodies" {
	check_case test_generated_script_literal_controls "$GENERATION_CHECKS"
}

@test "duplication scan R9 excludes assignment escapes hiding cwd through inventory catalog and CLI" {
	check_case test_assignment_escape_directory_inventory "$ESCAPE_CHECKS"
}

@test "duplication scan R9 excludes assignment escapes hiding PATH and module selection" {
	check_case test_assignment_escape_selection_inventory "$ESCAPE_CHECKS"
}

@test "duplication scan R9 guards assignment separators before dependency lookup" {
	check_case test_assignment_escape_guards "$ESCAPE_CHECKS"
}

@test "duplication scan R9 retains ordinary assignment escapes and inert data" {
	check_case test_assignment_escape_data_controls "$ESCAPE_CHECKS"
}

@test "duplication scan R9 retains find exec terminators and guards later escaped commands" {
	check_case test_find_exec_terminator_controls "$ESCAPE_CHECKS"
}

@test "duplication scan R8 excludes escaped cwd commands through inventory catalog and CLI" {
	check_case test_escaped_directory_inventory "$ESCAPE_CHECKS"
}

@test "duplication scan R8 guards escaped executable words before dependency lookup" {
	check_case test_escaped_executable_guards "$ESCAPE_CHECKS"
}

@test "duplication scan R8 retains escaped data arguments and literal controls" {
	check_case test_escaped_data_controls "$ESCAPE_CHECKS"
}

@test "duplication scan R8 verifies quoted assignments through actual callers" {
	check_case test_quoted_assignment_caller "$ESCAPE_CHECKS"
}

@test "duplication scan R8 excludes binary file comparisons through inventory catalog and CLI" {
	check_case test_binary_file_comparison_inventory "$ESCAPE_CHECKS"
}

@test "duplication scan R8 retains unary file predicates and inert comparison controls" {
	check_case test_binary_file_comparison_controls "$ESCAPE_CHECKS"
}

@test "duplication scan R7 guards empty assignment command prefixes" {
	check_case test_empty_assignment_guards "$REVIEW_CHECKS"
}

@test "duplication scan R7 excludes empty assignment PATH and cwd mutations" {
	check_case test_empty_assignment_inventory "$REVIEW_CHECKS"
}

@test "duplication scan R7 retains empty assignment data and script controls" {
	check_case test_empty_assignment_controls "$REVIEW_CHECKS"
}

@test "duplication scan R7 inherits composite action input default opacity" {
	check_case test_action_input_defaults "$REVIEW_CHECKS"
}

@test "duplication scan R7 keeps inert action input defaults comparable" {
	check_case test_action_input_controls "$REVIEW_CHECKS"
}

@test "duplication scan R7 guards raw Python literal token boundaries" {
	check_case test_python_literal_token_boundaries "$REVIEW_CHECKS"
}

@test "duplication scan R7 guards Python literal keys through actual callers" {
	check_case test_python_literal_inventory "$REVIEW_CHECKS"
}

@test "duplication scan R7 keeps Python template interpolation opaque" {
	check_case test_python_template_strings "$REVIEW_CHECKS"
}

@test "duplication scan R7 excludes shell comparisons with path operands" {
	check_case test_shell_comparison_inventory "$REVIEW_CHECKS"
}

@test "duplication scan R7 retains filesystem predicate controls" {
	check_case test_shell_comparison_controls "$REVIEW_CHECKS"
}

@test "duplication scan guards variable-writing builtins before data exemptions" {
	check_case test_assignment_builtin_shapes "$SELECTION_CHECKS" AssignmentBuiltinCases
}

@test "duplication scan blocks builtin PATH mutations through inventory catalog and CLI" {
	check_case test_assignment_builtin_inventory "$SELECTION_CHECKS" AssignmentBuiltinCases
}

@test "duplication scan keeps the fresh parameter adjacency reproducer distinct" {
	check_case test_parameter_adjacency_inventory "$RUNNER_CHECKS"
}

@test "duplication scan guards f-strings before literal helpers on both token families" {
	check_case test_python_fstring_helper_order "$PYTHON_CHECKS" StringCases
}

@test "duplication scan keeps direct forwarded programs opaque" {
	check_case test_forwarded_command_shapes "$SELECTION_CHECKS" ExecutableSelectionCases
}

@test "duplication scan propagates runner expression opacity through environment scopes" {
	check_case test_runner_environment_scopes "$RUNNER_CHECKS"
}

@test "duplication scan retains inert runner execution metadata" {
	check_case test_runner_context_data_controls "$RUNNER_CHECKS"
}

@test "duplication scan keeps active process substitutions opaque" {
	check_case test_process_substitution "$RUNNER_CHECKS"
}

@test "duplication scan accepts reopen receipts from the authenticated writer" {
	check_case test_reopen_authenticated_writer "$REVISION_CHECKS" ReopenCases
}

@test "duplication scan rejects spoofed reopen writer identities" {
	check_case test_reopen_writer_spoof_controls "$REVISION_CHECKS" ReopenCases
}

@test "duplication scan validates write authentication before any mutation" {
	check_case test_malformed_writer_before_mutations "$REVISION_CHECKS" ReopenCases
}

@test "duplication scan verifies writer auth over the frozen write transport" {
	check_case test_writer_authentication_transport "$REVISION_CHECKS" ReopenCases
}

@test "duplication scan preserves local forwarder executable and endpoint identity" {
	check_case test_forwarded_script_inventory "$SELECTION_CHECKS" ExecutableSelectionCases
}

@test "duplication scan retains parameterization of forwarded data arguments" {
	check_case test_forwarded_data_controls "$SELECTION_CHECKS" ExecutableSelectionCases
}

@test "duplication scan retains single forwarded positional echo data" {
	check_case test_single_positional_data_control "$SELECTION_CHECKS" ExecutableSelectionCases
}

@test "duplication scan preserves command-prefix scalar executable identity" {
	check_case test_scalar_command_prefix_forwarding "$SELECTION_CHECKS" ExecutableSelectionCases
}

@test "duplication scan keeps unproven scalar contexts opaque" {
	check_case test_unproven_scalar_contexts "$SELECTION_CHECKS" ExpandedReferenceCases
}

@test "duplication scan keeps forwarding through unknown wrappers opaque" {
	check_case test_unknown_wrapper_forwarding "$SELECTION_CHECKS" ExecutableSelectionCases
}

@test "duplication scan retains unknown wrapper executable and endpoint arguments" {
	check_case test_unknown_wrapper_script_arguments "$SELECTION_CHECKS" ExecutableSelectionCases
}

@test "duplication scan does not mask forwarding behind inspected commands" {
	check_case test_resolved_command_forwarding "$SELECTION_CHECKS" ExecutableSelectionCases
}

@test "duplication scan ignores literal and commented forwarding syntax" {
	check_case test_forwarding_literal_controls "$SELECTION_CHECKS" ExecutableSelectionCases
}

@test "duplication scan keeps runner PATH file writes opaque before resolution" {
	check_case test_runner_path_command_shapes "$SELECTION_CHECKS" ExecutableSelectionCases
}

@test "duplication scan excludes cross-step runner PATH selection from adoption" {
	check_case test_runner_path_cross_step_inventory "$SELECTION_CHECKS" ExecutableSelectionCases
}

@test "duplication scan preserves inert runner PATH file references" {
	check_case test_runner_path_literal_controls "$SELECTION_CHECKS" ExecutableSelectionCases
}

@test "duplication scan keeps expanded runner-file arguments opaque" {
	check_case test_runner_file_reference_shapes "$SELECTION_CHECKS" ExpandedReferenceCases
}

@test "duplication scan excludes runner-file arguments and aliases from adoption" {
	check_case test_runner_file_reference_inventory "$SELECTION_CHECKS" ExpandedReferenceCases
}

@test "duplication scan preserves forwarded runner-file payload paths" {
	check_case test_runner_file_forwarded_paths "$SELECTION_CHECKS" ExpandedReferenceCases
}

@test "duplication scan CLI rejects unknown forwarding and cross-step PATH copies" {
	check_case test_executable_selection_cli "$SELECTION_CHECKS" ExecutableSelectionCases
}

@test "duplication scan keeps PATH-changing blocks opaque before script resolution" {
	check_case test_path_command_shapes "$SELECTION_CHECKS" ExecutableSelectionCases
}

@test "duplication scan excludes PATH selection from clusters and catalog matches" {
	check_case test_path_inventory "$SELECTION_CHECKS" ExecutableSelectionCases
}

@test "duplication scan distinguishes PATH mutations from data arguments" {
	check_case test_path_data_controls "$SELECTION_CHECKS" ExecutableSelectionCases
}

@test "duplication scan preserves non-HTTP protocol endpoints offline" {
	check_case test_protocol_endpoint_shapes "$SELECTION_CHECKS" ExecutableSelectionCases
}

@test "duplication scan publication refreshes visibility after historical pagination" {
	check_case test_late_history_visibility "$PUBLICATION_CHECKS"
}

@test "duplication scan publication preserves historical lifecycle and receipts" {
	check_case test_late_history_lifecycle "$PUBLICATION_CHECKS"
}

@test "duplication scan publication refreshes failed-scan privacy cleanup" {
	check_case test_late_failure_cleanup_visibility "$PUBLICATION_CHECKS"
}

@test "duplication scan publication refreshes every report sink after issue writes" {
	check_case test_late_report_visibility "$PUBLICATION_CHECKS"
}

@test "duplication scan publication rebuilds public near matches" {
	check_case test_late_near_match_visibility "$PUBLICATION_CHECKS"
}

@test "duplication scan preserves HTTP endpoint host query and payload identity" {
	check_case test_http_endpoint_shapes "$SHELL_CHECKS" HttpCases
}

@test "duplication scan keeps dynamic HTTP endpoints and payloads opaque" {
	check_case test_http_dynamic_shapes "$SHELL_CHECKS" HttpCases
}

@test "duplication scan excludes HTTP requests from clusters and catalog matches" {
	check_case test_http_inventory "$SHELL_CHECKS" HttpCases
}

@test "duplication scan guards HTTP command boundaries and preserves data controls" {
	check_case test_http_boundaries_and_controls "$SHELL_CHECKS" HttpCases
}

@test "duplication scan revision guards GitHub API commands after comment separators" {
	check_case test_gh_api_comment_boundaries "$SHELL_CHECKS" GhApiCases
}

@test "duplication scan revision guards quoted GitHub API command names" {
	check_case test_gh_api_quoted_commands "$SHELL_CHECKS" GhApiCases
}

@test "duplication scan revision guards directory changes after comment separators" {
	check_case test_comment_directory_guards "$SHELL_CHECKS" CommentBoundaryCases
}

@test "duplication scan revision preserves script resolution and offsets after comments" {
	check_case test_comment_script_resolution "$SHELL_CHECKS" CommentBoundaryCases
}

@test "duplication scan revision keeps comments and quoted command data inert" {
	check_case test_comment_literal_controls "$SHELL_CHECKS" CommentBoundaryCases
}

@test "duplication scan keeps GitHub API endpoints methods and payloads opaque" {
	check_case test_gh_api_command_shapes "$SHELL_CHECKS" GhApiCases
}

@test "duplication scan excludes GitHub API operations from clusters and catalog matches" {
	check_case test_gh_api_inventory "$SHELL_CHECKS" GhApiCases
}

@test "duplication scan guards GitHub API operations across shell command boundaries" {
	check_case test_gh_api_command_boundaries "$SHELL_CHECKS" GhApiCases
}

@test "duplication scan retains ordinary data controls around opaque GitHub API commands" {
	check_case test_gh_api_opacity_controls "$SHELL_CHECKS" GhApiCases
}

@test "duplication scan recovers reopen explanations after known pre-send failure" {
	check_case test_reopen_pre_send_recovery "$REVISION_CHECKS" ReopenCases
}

@test "duplication scan never duplicates uncertain reopen explanations" {
	check_case test_reopen_lost_response_and_interruption "$REVISION_CHECKS" ReopenCases
}

@test "duplication scan reconciles transaction-specific scanner comments across pages" {
	check_case test_reopen_existing_comment_and_pagination "$REVISION_CHECKS" ReopenCases
}

@test "duplication scan fails closed on malformed or failed comment lookups" {
	check_case test_reopen_comment_lookup_failures "$REVISION_CHECKS" ReopenCases
}

@test "duplication scan rejects unrelated comments and uncertain POST receipts" {
	check_case test_reopen_unrelated_comments_and_invalid_receipts "$REVISION_CHECKS" ReopenCases
}

@test "duplication scan retains reopen delivery across receipt failures and later closures" {
	check_case test_reopen_receipt_failure_and_new_transaction "$REVISION_CHECKS" ReopenCases
}

@test "duplication scan pending explanations preserve policy privacy and no-write controls" {
	check_case test_reopen_policy_and_no_write_controls "$REVISION_CHECKS" ReopenCases
}

@test "duplication scan preserves job output name and using negative pairs" {
	check_case test_output_name_and_using_negative_pairs "$REVISION_CHECKS" ContextCases
}

@test "duplication scan treats reserved output keys as user data" {
	check_case test_output_reserved_keys_are_data "$REVISION_CHECKS" ContextCases
}

@test "duplication scan retains display-only names and ordinary action normalization" {
	check_case test_execution_display_and_action_positive_controls "$REVISION_CHECKS" ContextCases
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

@test "duplication scan keeps non-YAML catalog dependencies out of YAML parsing" {
	check_case test_catalog_non_yaml_dependency "$REGRESSION_CHECKS" CatalogDependencyCases
}

@test "duplication scan guards runner-file contexts before shell quoting" {
	check_case test_runner_context_expressions "$RUNNER_CHECKS"
}

@test "duplication scan keeps indirect runner-file expansions opaque" {
	check_case test_indirect_runner_references "$RUNNER_CHECKS"
}

@test "duplication scan guards Python runner-file writes across steps" {
	check_case test_python_runner_files "$RUNNER_CHECKS"
}

@test "duplication scan rejects unproven pipeline consumers" {
	check_case test_unknown_pipeline_consumers "$RUNNER_CHECKS"
}

@test "duplication scan preserves executable stdin arguments in called scripts" {
	check_case test_called_pipeline_consumers "$RUNNER_CHECKS"
}

@test "duplication scan keeps quoted interpreters and wrappers conservative" {
	check_case test_quoted_executable_names "$RUNNER_CHECKS"
}

@test "duplication scan preserves inert references and proven data pipelines" {
	check_case test_runner_and_pipeline_data_controls "$RUNNER_CHECKS"
}
