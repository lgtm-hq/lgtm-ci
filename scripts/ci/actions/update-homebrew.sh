#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Update Homebrew formula with new version from PyPI
#
# Environment variables:
#   STEP: wait | generate | commit | pr | summary
#   TAP_REPOSITORY: Homebrew tap repository (owner/repo)
#   FORMULA: Formula name
#   PACKAGE: PyPI package name
#   VERSION: Version to update to
#   TEST_PYPI: Use TestPyPI instead of PyPI
#   MAX_WAIT: Maximum wait time in minutes (for wait step)
#   PUSH: Push changes to tap repository
#   CREATE_PR: Create PR instead of direct push
set -euo pipefail

: "${STEP:?STEP is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/actions.sh"
source "$SCRIPT_DIR/../lib/publish.sh"

# Working directory for tap clone
TAP_DIR="${RUNNER_TEMP:-/tmp}/homebrew-tap"

case "$STEP" in
wait)
	: "${PACKAGE:?PACKAGE is required}"
	: "${VERSION:?VERSION is required}"
	: "${MAX_WAIT:=10}"
	: "${TEST_PYPI:=false}"

	max_wait_seconds=$((MAX_WAIT * 60))

	log_info "Waiting for $PACKAGE@$VERSION on PyPI..."

	if wait_for_package "pypi" "$PACKAGE" "$VERSION" "$max_wait_seconds" "$TEST_PYPI"; then
		log_success "Package is available"
	else
		die "Timeout waiting for package availability"
	fi
	;;

generate)
	: "${TAP_REPOSITORY:?TAP_REPOSITORY is required}"
	: "${FORMULA:?FORMULA is required}"
	: "${PACKAGE:?PACKAGE is required}"
	: "${VERSION:?VERSION is required}"
	: "${TEST_PYPI:=false}"

	log_info "Generating/updating formula for $PACKAGE@$VERSION..."

	# Clone tap repository
	clone_homebrew_tap "$TAP_REPOSITORY" "$TAP_DIR"

	# Get download URL and SHA256 from PyPI
	download_url=$(get_pypi_download_url "$PACKAGE" "$VERSION" "$TEST_PYPI")
	if [[ -z "$download_url" ]]; then
		die "Could not get download URL from PyPI"
	fi

	sha256=$(get_pypi_sha256 "$PACKAGE" "$VERSION" "$TEST_PYPI")
	if [[ -z "$sha256" ]]; then
		die "Could not get SHA256 from PyPI"
	fi

	log_info "Download URL: $download_url"
	log_info "SHA256: $sha256"

	# Find or create formula file
	formula_file=""
	if [[ -f "$TAP_DIR/Formula/$FORMULA.rb" ]]; then
		formula_file="$TAP_DIR/Formula/$FORMULA.rb"
	elif [[ -f "$TAP_DIR/$FORMULA.rb" ]]; then
		formula_file="$TAP_DIR/$FORMULA.rb"
	fi

	if [[ -n "$formula_file" ]]; then
		log_info "Updating existing formula: $formula_file"
		update_formula_version "$formula_file" "$VERSION" "$download_url" "$sha256"
	else
		log_info "Creating new formula..."
		mkdir -p "$TAP_DIR/Formula"
		formula_file="$TAP_DIR/Formula/$FORMULA.rb"

		# Generate new formula
		generate_formula_from_pypi "$PACKAGE" "$VERSION" "A Python package" "$TEST_PYPI" >"$formula_file"
	fi

	log_success "Formula updated: $formula_file"
	set_github_output "formula-file" "$formula_file"
	;;

commit)
	: "${TAP_REPOSITORY:?TAP_REPOSITORY is required}"
	: "${FORMULA:?FORMULA is required}"
	: "${VERSION:?VERSION is required}"
	: "${PUSH:=true}"
	: "${CREATE_PR:=false}"

	log_info "Committing formula update..."

	cd "$TAP_DIR"

	# Configure git
	configure_git_ci_user

	# Stage changes
	git add -A

	# Check if there are changes
	if git diff --cached --quiet; then
		log_warn "No changes to commit"
		set_github_output "updated" "false"
		exit 0
	fi

	# Create branch for PR if needed
	if [[ "$CREATE_PR" == "true" ]]; then
		branch_name="update-$FORMULA-$VERSION"
		git checkout -b "$branch_name"
	fi

	# Commit
	git commit -m "Update $FORMULA to $VERSION"
	commit_sha=$(git rev-parse HEAD)

	log_success "Committed: $commit_sha"

	# Push if requested
	if [[ "$PUSH" == "true" ]] || [[ "$CREATE_PR" == "true" ]]; then
		if [[ "$CREATE_PR" == "true" ]]; then
			git push -u origin "$branch_name"
		else
			git push origin HEAD
		fi
		log_success "Pushed to $TAP_REPOSITORY"
	fi

	set_github_output "updated" "true"
	set_github_output "commit-sha" "$commit_sha"
	;;

pr)
	: "${TAP_REPOSITORY:?TAP_REPOSITORY is required}"
	: "${FORMULA:?FORMULA is required}"
	: "${VERSION:?VERSION is required}"

	log_info "Creating pull request..."

	cd "$TAP_DIR"

	branch_name="update-$FORMULA-$VERSION"

	# Create PR using gh CLI
	pr_url=$(gh pr create \
		--repo "$TAP_REPOSITORY" \
		--title "Update $FORMULA to $VERSION" \
		--body "Automated formula update for $FORMULA version $VERSION." \
		--head "$branch_name" \
		--base main 2>/dev/null || \
		gh pr create \
			--repo "$TAP_REPOSITORY" \
			--title "Update $FORMULA to $VERSION" \
			--body "Automated formula update for $FORMULA version $VERSION." \
			--head "$branch_name" \
			--base master)

	log_success "Created PR: $pr_url"
	set_github_output "pr-url" "$pr_url"
	;;

summary)
	: "${TAP_REPOSITORY:=}"
	: "${FORMULA:=}"
	: "${PACKAGE:=}"
	: "${VERSION:=}"
	: "${UPDATED:=false}"
	: "${COMMIT_SHA:=}"
	: "${PR_URL:=}"

	add_github_summary "## Homebrew Formula Update"
	add_github_summary ""
	add_github_summary "| Property | Value |"
	add_github_summary "| -------- | ----- |"
	add_github_summary "| Tap | $TAP_REPOSITORY |"
	add_github_summary "| Formula | $FORMULA |"
	add_github_summary "| Package | $PACKAGE |"
	add_github_summary "| Version | $VERSION |"

	if [[ "$UPDATED" == "true" ]]; then
		add_github_summary "| Status | :white_check_mark: Updated |"
		if [[ -n "$COMMIT_SHA" ]]; then
			add_github_summary "| Commit | \`$COMMIT_SHA\` |"
		fi
		if [[ -n "$PR_URL" ]]; then
			add_github_summary "| PR | $PR_URL |"
		fi
	else
		add_github_summary "| Status | :x: Not Updated |"
	fi
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
