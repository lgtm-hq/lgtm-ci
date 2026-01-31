#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Prepare static content for GitHub Pages deployment
#
# Required environment variables:
#   STEP - Which step to run: prepare, validate, summary
#
# Optional environment variables:
#   SOURCE_PATH - Path to static content to deploy (default: dist)
#   BUILD_COMMAND - Optional build command to run first
#   ARTIFACT_NAME - Name for the pages artifact (default: github-pages)

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

case "$STEP" in
prepare)
	: "${SOURCE_PATH:=dist}"
	: "${BUILD_COMMAND:=}"

	# Run build command if provided
	# Note: BUILD_COMMAND must come from a trusted source (workflow input)
	# Using bash -c is safer than eval as it runs in a subshell
	if [[ -n "$BUILD_COMMAND" ]]; then
		log_info "Running build command: $BUILD_COMMAND"
		bash -c "$BUILD_COMMAND"
	fi

	# Validate source path exists
	if [[ ! -d "$SOURCE_PATH" ]]; then
		log_error "Source path does not exist: $SOURCE_PATH"
		exit 1
	fi

	# Check if source has content
	if [[ -z "$(ls -A "$SOURCE_PATH" 2>/dev/null)" ]]; then
		log_error "Source path is empty: $SOURCE_PATH"
		exit 1
	fi

	# Create .nojekyll file to prevent Jekyll processing
	if [[ ! -f "$SOURCE_PATH/.nojekyll" ]]; then
		touch "$SOURCE_PATH/.nojekyll"
		log_info "Created .nojekyll file"
	fi

	# Verify index.html exists (required for GitHub Pages)
	if [[ ! -f "$SOURCE_PATH/index.html" ]]; then
		log_warn "No index.html found in $SOURCE_PATH"
	fi

	# Count files
	file_count=$(find "$SOURCE_PATH" -type f | wc -l | tr -d ' ')
	log_info "Source path contains $file_count files"

	set_github_output "source-path" "$SOURCE_PATH"
	set_github_output "file-count" "$file_count"

	log_success "Content prepared for deployment from $SOURCE_PATH"
	;;

validate)
	: "${SOURCE_PATH:=dist}"

	# Validate the artifact structure
	if [[ ! -d "$SOURCE_PATH" ]]; then
		log_error "Source path not found: $SOURCE_PATH"
		set_github_output "valid" "false"
		exit 1
	fi

	# Check for common issues
	issues=()

	# Check for extremely large files (>100MB)
	large_files=$(find "$SOURCE_PATH" -type f -size +100M 2>/dev/null || true)
	if [[ -n "$large_files" ]]; then
		issues+=("Large files detected (>100MB)")
	fi

	# Check for symlinks (not supported by Pages)
	symlinks=$(find "$SOURCE_PATH" -type l 2>/dev/null || true)
	if [[ -n "$symlinks" ]]; then
		issues+=("Symbolic links detected (not supported)")
	fi

	if [[ ${#issues[@]} -gt 0 ]]; then
		log_warn "Validation warnings:"
		for issue in "${issues[@]}"; do
			log_warn "  - $issue"
		done
	fi

	set_github_output "valid" "true"
	log_success "Content validation passed"
	;;

summary)
	: "${PAGE_URL:=}"
	: "${SOURCE_PATH:=dist}"
	: "${FILE_COUNT:=0}"

	add_github_summary "## GitHub Pages Deployment"
	add_github_summary ""

	if [[ -n "$PAGE_URL" ]]; then
		add_github_summary ":white_check_mark: **Deployed successfully**"
		add_github_summary ""
		add_github_summary "- **URL:** [$PAGE_URL]($PAGE_URL)"
		add_github_summary "- **Source:** \`$SOURCE_PATH\`"
		add_github_summary "- **Files:** $FILE_COUNT"
	else
		add_github_summary ":hourglass: **Deployment in progress**"
		add_github_summary ""
		add_github_summary "- **Source:** \`$SOURCE_PATH\`"
		add_github_summary "- **Files:** $FILE_COUNT"
	fi

	add_github_summary ""
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
