#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Build and publish Python packages to PyPI
#
# Environment variables:
#   STEP: validate | build | validate-dist | summary
#   WORKING_DIRECTORY: Directory containing the package (default: .)
#   PACKAGE_NAME: Package name (for summary)
#   PACKAGE_VERSION: Package version (for summary)
#   DRY_RUN: Whether this is a dry run
#   TEST_PYPI: Whether publishing to TestPyPI
#   PUBLISHED: Whether the package was published
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
	log_info "Validating package metadata..."

	if [[ ! -f "pyproject.toml" ]]; then
		die "pyproject.toml not found in $WORKING_DIRECTORY"
	fi

	# Extract and validate version
	version=$(extract_pypi_version ".") || die "Could not extract version from pyproject.toml"
	if ! validate_version_format "$version"; then
		die "Invalid version format: $version"
	fi

	# Extract name
	name=$(grep -E '^name\s*=' "pyproject.toml" | head -1 | sed 's/.*=\s*["\x27]\([^"\x27]*\)["\x27].*/\1/')
	if [[ -z "$name" ]]; then
		die "Could not extract package name from pyproject.toml"
	fi

	log_success "Package metadata valid: $name@$version"
	;;

build)
	log_info "Building Python package..."

	# Clean previous builds
	rm -rf dist/ build/ ./*.egg-info/

	# Extract version and name first
	version=$(extract_pypi_version ".") || die "Could not extract version"
	name=$(grep -E '^name\s*=' "pyproject.toml" | head -1 | sed 's/.*=\s*["\x27]\([^"\x27]*\)["\x27].*/\1/')

	# Build using uv
	log_info "Running uv build..."
	uv build

	# Verify build output
	if [[ ! -d "dist" ]]; then
		die "Build failed: dist/ directory not created"
	fi

	wheel_count=$(find dist -name "*.whl" 2>/dev/null | wc -l)
	sdist_count=$(find dist -name "*.tar.gz" 2>/dev/null | wc -l)

	if ((wheel_count == 0 && sdist_count == 0)); then
		die "Build failed: no distribution files created"
	fi

	log_success "Build complete: $wheel_count wheel(s), $sdist_count sdist(s)"

	# List built files
	log_info "Built files:"
	ls -la dist/

	set_github_output "version" "$version"
	set_github_output "name" "$name"
	;;

validate-dist)
	log_info "Validating distribution files..."

	if [[ ! -d "dist" ]]; then
		die "dist/ directory not found"
	fi

	if validate_pypi_package "dist"; then
		log_success "Distribution validation passed"
	else
		die "Distribution validation failed"
	fi
	;;

summary)
	: "${PACKAGE_NAME:=unknown}"
	: "${PACKAGE_VERSION:=unknown}"
	: "${DRY_RUN:=false}"
	: "${TEST_PYPI:=false}"
	: "${PUBLISHED:=false}"

	add_github_summary "## PyPI Publishing"
	add_github_summary ""
	add_github_summary "| Property | Value |"
	add_github_summary "| -------- | ----- |"
	add_github_summary "| Package | $PACKAGE_NAME |"
	add_github_summary "| Version | $PACKAGE_VERSION |"

	if [[ "$TEST_PYPI" == "true" ]]; then
		add_github_summary "| Registry | TestPyPI |"
	else
		add_github_summary "| Registry | PyPI |"
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		add_github_summary "| Status | :construction: Dry Run (not published) |"
	elif [[ "$PUBLISHED" == "true" ]]; then
		add_github_summary "| Status | :white_check_mark: Published |"
		if [[ "$TEST_PYPI" == "true" ]]; then
			add_github_summary "| URL | https://test.pypi.org/project/$PACKAGE_NAME/$PACKAGE_VERSION/ |"
		else
			add_github_summary "| URL | https://pypi.org/project/$PACKAGE_NAME/$PACKAGE_VERSION/ |"
		fi
	else
		add_github_summary "| Status | :x: Not Published |"
	fi

	# List distribution files if they exist
	if [[ -d "dist" ]]; then
		add_github_summary ""
		add_github_summary "### Distribution Files"
		add_github_summary ""
		add_github_summary '```'
		find dist/ -type f -exec ls -la {} \;
		add_github_summary '```'
	fi
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
