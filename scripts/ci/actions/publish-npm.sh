#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Build and publish Node.js packages to npm
#
# Environment variables:
#   STEP: validate | build | publish | summary
#   WORKING_DIRECTORY: Directory containing the package (default: .)
#   DIST_TAG: npm dist-tag (default: latest)
#   PROVENANCE: Enable provenance attestation (default: true)
#   ACCESS: Package access level (default: public)
#   NODE_AUTH_TOKEN: npm authentication token
set -euo pipefail

: "${STEP:?STEP is required}"
: "${WORKING_DIRECTORY:=.}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/actions.sh"
source "$SCRIPT_DIR/../lib/publish.sh"

# Change to working directory
cd "$WORKING_DIRECTORY"

case "$STEP" in
validate)
	log_info "Validating package.json..."

	if [[ ! -f "package.json" ]]; then
		die "package.json not found in $WORKING_DIRECTORY"
	fi

	if ! validate_npm_package "."; then
		die "package.json validation failed"
	fi

	# Check for required fields for publishing
	name=$(grep -E '^\s*"name"\s*:' package.json | sed 's/.*:\s*"\([^"]*\)".*/\1/')
	version=$(extract_npm_version ".") || die "Could not extract version"

	log_success "Package valid: $name@$version"
	;;

build)
	log_info "Building and packing npm package..."

	# Extract metadata
	name=$(grep -E '^\s*"name"\s*:' package.json | sed 's/.*:\s*"\([^"]*\)".*/\1/')
	version=$(extract_npm_version ".") || die "Could not extract version"

	# Install dependencies if needed
	if [[ -f "bun.lockb" ]] || [[ -f "bun.lock" ]]; then
		log_info "Installing dependencies with bun..."
		bun install --frozen-lockfile
	elif [[ -f "package-lock.json" ]]; then
		log_info "Installing dependencies with npm..."
		npm ci
	elif [[ -f "yarn.lock" ]]; then
		log_info "Installing dependencies with yarn..."
		yarn install --frozen-lockfile
	fi

	# Run build script if it exists (check for exact "build" key in scripts)
	if grep -qE '^\s*"build"\s*:' package.json; then
		log_info "Running build script..."
		if command -v bun >/dev/null 2>&1; then
			bun run build
		else
			npm run build
		fi
	fi

	# Pack the package
	log_info "Packing package..."
	if command -v bun >/dev/null 2>&1; then
		tarball=$(bun pm pack 2>/dev/null | tail -1) || tarball=$(npm pack 2>/dev/null | tail -1)
	else
		tarball=$(npm pack 2>/dev/null | tail -1)
	fi

	if [[ -z "$tarball" ]] || [[ ! -f "$tarball" ]]; then
		die "Failed to pack package"
	fi

	log_success "Packed: $tarball"

	set_github_output "name" "$name"
	set_github_output "version" "$version"
	set_github_output "tarball" "$tarball"
	;;

publish)
	: "${DIST_TAG:=latest}"
	: "${PROVENANCE:=true}"
	: "${ACCESS:=public}"

	log_info "Publishing to npm..."

	# Build publish command
	publish_args=(
		"--tag" "$DIST_TAG"
		"--access" "$ACCESS"
	)

	if [[ "$PROVENANCE" == "true" ]]; then
		publish_args+=("--provenance")
	fi

	# Publish using npm (provenance requires npm, not bun)
	log_info "Running: npm publish ${publish_args[*]}"
	npm publish "${publish_args[@]}"

	log_success "Published successfully"
	set_github_output "published" "true"
	;;

summary)
	: "${PACKAGE_NAME:=unknown}"
	: "${PACKAGE_VERSION:=unknown}"
	: "${DIST_TAG:=latest}"
	: "${DRY_RUN:=false}"
	: "${PUBLISHED:=false}"

	add_github_summary "## npm Publishing"
	add_github_summary ""
	add_github_summary "| Property | Value |"
	add_github_summary "| -------- | ----- |"
	add_github_summary "| Package | $PACKAGE_NAME |"
	add_github_summary "| Version | $PACKAGE_VERSION |"
	add_github_summary "| Tag | $DIST_TAG |"

	if [[ "$DRY_RUN" == "true" ]]; then
		add_github_summary "| Status | :construction: Dry Run (not published) |"
	elif [[ "$PUBLISHED" == "true" ]]; then
		add_github_summary "| Status | :white_check_mark: Published |"
		add_github_summary "| URL | https://www.npmjs.com/package/$PACKAGE_NAME/v/$PACKAGE_VERSION |"
	else
		add_github_summary "| Status | :x: Not Published |"
	fi
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
