# Function reference

One line per public function in `scripts/ci/lib/`, grouped by domain (see
[README.md](README.md) for the aggregator layout). Internal helpers
(leading `_`) are omitted. `command_exists`/`log_info`/`log_success` have
minimal local fallback redefinitions in a couple of installer/network
scripts for standalone sourcing — the canonical versions are in `fs.sh` and
`log.sh` below.

<!-- markdownlint-disable MD013 -- one-line-per-function reference; entries exceed line length -->

## Core: logging & errors

- `command_exists` (fs.sh) - Check if command exists
- `require_command` (fs.sh) - Require command to exist or die
- `ensure_directory` (fs.sh) - Ensure directory exists, create if not
- `require_file` (fs.sh) - Require file to exist or die
- `check_file_exists` (fs.sh) - Check if file exists and log result (non-fatal)
- `check_dir_exists` (fs.sh) - Check if directory exists and log result (non-fatal)
- `create_temp_dir` (fs.sh) - Create a temporary directory with automatic cleanup on exit
- `write_file_atomic` (fs.sh) - Atomic file write via temp file.
- `get_git_root` (git.sh) - Get the root directory of the git repository
- `get_current_branch` (git.sh) - Get the current branch name
- `get_commit_sha` (git.sh) - Get the full commit SHA
- `get_short_sha` (git.sh) - Get the short commit SHA (exactly 7 characters)
- `is_git_repo` (git.sh) - Check if we're in a git repository
- `is_git_clean` (git.sh) - Check if the working directory is clean
- `get_git_remote_url` (git.sh) - Get the remote URL for origin
- `get_latest_tag` (git.sh) - Get the most recent reachable tag from HEAD matching a pattern
- `get_tags` (git.sh) - Get list of tags matching a pattern
- `get_latest_reachable_tag` (git.sh) - Get the highest semver among tags reachable from HEAD matching a pattern
- `tag_exists` (git.sh) - Check if a tag exists
- `log_info` / `log_success` / `log_warn` / `log_error` / `log_verbose` (log.sh) - Leveled logging to stderr
- `log_warning` (log.sh) - Alias for `log_warn`
- `die` (log.sh) - Log an error and exit
- `die_unknown_step` (log.sh) - Exit with unknown step error (for STEP-based action scripts)
- `detect_os` (platform.sh) - Detect OS name (lowercase)
- `detect_arch` (platform.sh) - Detect architecture (normalized)
- `detect_platform` (platform.sh) - Detect platform and architecture combined
- `is_macos` / `is_linux` / `is_windows` / `is_arm` (platform.sh) - Platform checks

## GitHub Actions integration

- `is_ci` (github/env.sh) - Check if running in any CI environment
- `is_github_actions` (github/env.sh) - Check if running in GitHub Actions specifically
- `is_pr_context` (github/env.sh) - Check if we're in a PR context
- `is_default_branch` (github/env.sh) - Check if we're on the default branch
- `get_github_pages_url` (github/format.sh) - Construct GitHub Pages URL for a given path
- `get_github_pages_wget_cut_dirs` (github/format.sh) - Derive wget --cut-dirs from a GitHub Pages site root URL
- `score_emoji` (github/format.sh) - Get score emoji based on threshold
- `format_score_with_color` (github/format.sh) - Format a numeric score with color-coded emoji indicator
- `format_percentage_with_color` (github/format.sh) - Format a percentage with color-coded emoji indicator
- `get_github_actions_run_url` (github/format.sh) - Format a GitHub Actions run URL
- `format_github_commit_line` (github/format.sh) - Format a commit metadata line for PR summaries and reports
- `set_github_output` / `set_github_output_multiline` (github/output.sh) - Set GitHub Actions output variables
- `set_github_env` (github/output.sh) - Set a GitHub Actions environment variable
- `add_github_path` (github/output.sh) - Add path to GitHub Actions PATH
- `configure_git_ci_user` (github/output.sh) - Configure git user for CI commits (github-actions[bot])
- `add_github_summary` (github/summary.sh) - Add content to the GitHub Actions step summary
- `add_github_summary_row` (github/summary.sh) - Add a markdown table row to the step summary
- `add_github_summary_details` (github/summary.sh) - Add a collapsible details section to the step summary

## Network: download, checksum, port

- `verify_checksum` (network/checksum.sh) - Verify file checksum
- `download_with_retries` (network/download.sh) - Download file with retries and exponential backoff
- `download_and_run_installer` (network/download.sh) - Download and execute installer script securely (avoids curl|bash)
- `download_with_pinning` (network/download.sh) - Download with an explicit pinned public key (fails closed)
- `port_available` (network/port.sh) - Check if port is available (not in use)
- `port_listening` (network/port.sh) - Check if a TCP port is accepting connections on localhost
- `wait_for_port_listen` (network/port.sh) - Wait for a TCP port to start accepting connections
- `wait_for_port` (network/port.sh) - Wait for port to become available

## Tool installer framework

- `installer_show_help` (installer/args.sh) - Show help message generated from `TOOL_*` variables
- `installer_parse_args` (installer/args.sh) - Parse standard installer arguments
- `installer_download_binary` (installer/binary.sh) - Download, verify, and install a binary
- `install_anchore_tool` (installer/binary.sh) - Install an Anchore tool (Syft, Grype) using official installer
- `installer_init` (installer/core.sh) - Initialize installer environment; sources all required libraries
- `installer_fallback_go` / `installer_fallback_brew` / `installer_fallback_cargo` (installer/fallbacks.sh) - Fallback install methods
- `installer_run_chain` (installer/fallbacks.sh) - Run a chain of installation methods until one succeeds
- `installer_run` (installer/fallbacks.sh) - Wrap installation function with dry-run check
- `installer_check_version` (installer/version.sh) - Check if tool is already installed with correct version

## Docker build & registry

- `check_docker_available` / `check_buildx_available` (docker/core.sh) - Availability checks
- `setup_buildx_builder` (docker/core.sh) - Setup Docker Buildx builder for multi-platform builds
- `get_default_platforms` / `get_current_platform` (docker/core.sh) - Platform helpers
- `needs_qemu` (docker/core.sh) - Check if QEMU is needed for cross-platform builds
- `docker_login_ghcr` / `docker_login_dockerhub` / `docker_login_generic` (docker/registry.sh) - Registry login
- `get_registry_url` / `normalize_registry_url` (docker/registry.sh) - Registry URL helpers
- `check_registry_auth` (docker/registry.sh) - Check if logged into a registry
- `generate_semver_tags` / `generate_sha_tag` / `generate_branch_tag` / `generate_pr_tag` (docker/tags.sh) - Tag generators
- `generate_docker_tags` (docker/tags.sh) - Generate all standard tags for a build

## GHCR registry & cleanup

- `ghcr_exchange_registry_token` (ghcr/registry.sh) - Exchange `GITHUB_TOKEN` for a ghcr.io pull bearer token
- `ghcr_fetch_manifest` (ghcr/registry.sh) - Fetch a manifest from ghcr.io by digest
- `ghcr_fetch_referrers` (ghcr/registry.sh) - Fetch OCI Referrers descriptors for a digest
- `ghcr_collect_referenced_digests` (ghcr/registry.sh) - Collect digests referenced by tagged manifest indexes and referrers
- `ghcr_is_ephemeral_only_tagged` (ghcr/tags.sh) - True when every tag on the version matches the ephemeral pattern

## Egress allowlist

- `egress_normalize_endpoint_lines` (egress.sh) - Normalize a multiline host:port list
- `egress_dedupe_endpoint_lines` (egress.sh) - Deduplicate host:port lines, preserving first-seen order
- `egress_merge_endpoint_lines` (egress.sh) - Merge multiple multiline endpoint lists, then dedupe
- `egress_preset_endpoints` (egress/presets.sh) - Resolve a named egress preset to its endpoint list

## SBOM format & severity

- `get_sbom_extension` / `validate_sbom_format` / `normalize_sbom_format` / `get_sbom_mime_type` (sbom/format.sh) - Format helpers
- `severity_to_number` / `number_to_severity` / `compare_severity` (sbom/severity.sh) - Severity comparison
- `severity_meets_threshold` / `should_fail_on_severity` (sbom/severity.sh) - Threshold checks
- `severity_color` / `severity_emoji` (sbom/severity.sh) - Terminal/markdown severity presentation
- `resolve_scan_target` / `validate_scan_target` / `describe_target_type` (sbom/target.sh) - Scan target resolution

## Package publish/validate

- `check_pypi_availability` / `check_npm_availability` / `check_rubygems_availability` (publish/registry.sh) - Registry availability checks
- `wait_for_package` (publish/registry.sh) - Wait for a package to be available on a registry
- `get_pypi_download_url` / `get_pypi_sha256` (publish/registry.sh) - PyPI sdist lookup
- `validate_pypi_package` / `validate_npm_package` / `validate_gem_package` (publish/validate.sh) - Package validation
- `validate_version_format` (publish/validate.sh) - Validate version string format (semver)
- `extract_pypi_version` / `extract_pypi_name` (publish/version.sh) - Read `pyproject.toml` via stdlib tomllib
- `extract_npm_version` (publish/version.sh) - Extract version from package.json
- `extract_gem_version` (publish/version.sh) - Extract version from gemspec file
- `is_prerelease_version` (publish/version.sh) - Detect if version is a prerelease
- `get_dist_tag_for_version` (publish/version.sh) - Get npm dist-tag based on version

## Release & changelog

- `determine_next_version` / `should_release` / `get_release_summary` (release.sh) - Release orchestration
- `create_release` (release.sh) - Create a release (tag + changelog)
- `analyze_commits_for_bump` / `get_commits_by_type` / `count_commits_by_type` (release/analyze.sh) - Commit-range analysis
- `has_releasable_commits` (release/analyze.sh) - Check if there are releasable commits
- `release_collect_asset_files` (release/assets.sh) - Collect files matching newline-separated glob patterns
- `format_commit_entry` / `generate_changelog_section` (release/changelog.sh) - Changelog section builders
- `generate_changelog` / `generate_release_notes` (release/changelog.sh) - Full changelog / concise release notes
- `normalize_kac_section` / `parse_changelog_body` / `merge_changelog_sections` (release/changelog_merge.sh) - Keep a Changelog merge
- `parse_conventional_commit` / `is_breaking_change` / `get_bump_for_type` (release/conventional.sh) - Conventional commit parsing
- `extract_version_pyproject` / `extract_version_package_json` / `extract_version_cargo` / `extract_version_git_tag` (release/extract.sh) - Version extraction
- `update_changelog_file` (release/fileops.sh) - Update CHANGELOG.md file
- `generate_compare_url` (release/fileops.sh) - Generate a GitHub compare URL
- `validate_semver` / `parse_version` / `bump_version` / `compare_versions` (release/version.sh) - SemVer 2.0.0 helpers
- `max_bump` / `clamp_bump` (release/version.sh) - Bump-type comparison and clamping

## Testing: detect, badge, coverage, parse

- `get_badge_color` / `get_badge_hex_color` / `get_shields_url` (testing/badge.sh) - Badge color/URL helpers
- `escape_xml` (testing/badge.sh) - Escape special XML characters to prevent injection
- `generate_badge_svg` / `generate_badge_json` / `generate_test_badge` (testing/badge.sh) - Badge generators
- `extract_coverage_percent` / `extract_coverage_details` (testing/coverage/extract.sh) - Coverage extraction
- `merge_lcov_files` / `merge_istanbul_files` / `convert_coverage` (testing/coverage/merge.sh) - Coverage merge/convert
- `check_coverage_threshold` / `get_coverage_delta` (testing/coverage/threshold.sh) - Coverage threshold checks
- `detect_test_runner` / `detect_all_runners` (testing/detect.sh) - Test runner detection
- `detect_coverage_format` / `detect_coverage_source` (testing/detect.sh) - Coverage format/source detection
- `format_test_summary` / `get_test_status` (testing/parse/common.sh) - Shared result formatting
- `parse_junit_xml` (testing/parse/junit.sh) - Parse JUnit XML report and extract test counts
- `parse_lighthouse_json` / `parse_lighthouse_manifest` (testing/parse/lighthouse.sh) - Lighthouse report parsing
- `check_lighthouse_thresholds` / `format_lighthouse_summary` (testing/parse/lighthouse.sh) - Lighthouse thresholds/summary
- `parse_playwright_json` (testing/parse/playwright.sh) - Parse Playwright JSON report and extract test counts
- `parse_pytest_json` / `parse_pytest_coverage` (testing/parse/pytest.sh) - Pytest report/coverage parsing
- `parse_vitest_json` / `parse_vitest_coverage` (testing/parse/vitest.sh) - Vitest report/coverage parsing

## Pages bundle manifest (Model B)

- `bundle_load_manifest` (bundle/workflow_artifacts.sh) - Load manifest JSON from inline JSON or a file path
- `bundle_find_workflow_run` / `bundle_find_workflow_run_on_ref` (bundle/workflow_artifacts.sh) - Resolve a workflow run for a commit or fallback ref
- `bundle_get_artifact_id` (bundle/workflow_artifacts.sh) - Resolve artifact ID from a workflow run
- `bundle_validate_zip_members` (bundle/workflow_artifacts.sh) - Zip-slip/symlink defense before extraction
- `bundle_download_artifact` (bundle/workflow_artifacts.sh) - Download and extract an artifact zip
- `bundle_resolve_site_dest` / `bundle_copy_to_site` (bundle/workflow_artifacts.sh) - Resolve and copy into `SITE_ROOT`
- `bundle_run_manifest` (bundle/workflow_artifacts.sh) - Process all manifest bundles

## Cargo version

- `parse_cargo_version` (cargo/version.sh) - Parse version from `[package]` or `[workspace.package]` in a Cargo manifest

## Pages coverage gating

- `resolve_pages_coverage_should_upload` (pages_coverage.sh) - Whether flat pages coverage HTML should upload, per
  `pages-coverage-upload-on` (see [workflow-contract.md](../workflow-contract.md))
