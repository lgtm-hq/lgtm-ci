#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Validate packages before publishing
#
# Environment variables:
#   STEP: detect | validate | summary
#   PACKAGE_TYPE: pypi | npm | gem
#   PACKAGE_PATH: Path to package directory or dist folder
set -euo pipefail

: "${STEP:?STEP is required}"
: "${PACKAGE_TYPE:?PACKAGE_TYPE is required}"
: "${PACKAGE_PATH:=.}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/actions.sh"
source "$SCRIPT_DIR/../lib/publish.sh"

case "$STEP" in
detect)
	log_info "Detecting package configuration..."

	case "$PACKAGE_TYPE" in
	pypi)
		if [[ -f "$PACKAGE_PATH/pyproject.toml" ]]; then
			log_success "Found pyproject.toml"
		elif [[ -d "$PACKAGE_PATH" ]] && compgen -G "$PACKAGE_PATH/*.whl" >/dev/null; then
			log_success "Found wheel files in dist directory"
		else
			die "No pyproject.toml or distribution files found"
		fi
		;;
	npm)
		if [[ -f "$PACKAGE_PATH/package.json" ]]; then
			log_success "Found package.json"
		else
			die "No package.json found at $PACKAGE_PATH"
		fi
		;;
	gem)
		gemspec=$(find "$PACKAGE_PATH" -maxdepth 1 -name "*.gemspec" -print -quit 2>/dev/null || true)
		if [[ -n "$gemspec" ]]; then
			log_success "Found gemspec: $gemspec"
		else
			die "No gemspec found at $PACKAGE_PATH"
		fi
		;;
	*)
		die "Unknown package type: $PACKAGE_TYPE"
		;;
	esac
	;;

validate)
	log_info "Validating $PACKAGE_TYPE package..."

	name=""
	version=""
	valid="false"

	case "$PACKAGE_TYPE" in
	pypi)
		# Extract version
		if [[ -f "$PACKAGE_PATH/pyproject.toml" ]]; then
			version=$(extract_pypi_version "$PACKAGE_PATH") || true
			name=$(grep -E '^name\s*=' "$PACKAGE_PATH/pyproject.toml" | head -1 | sed 's/.*=\s*["\x27]\([^"\x27]*\)["\x27].*/\1/' || true)
		fi

		# Validate dist files if they exist
		if [[ -d "$PACKAGE_PATH/dist" ]]; then
			if validate_pypi_package "$PACKAGE_PATH/dist"; then
				valid="true"
			fi
		elif [[ -d "$PACKAGE_PATH" ]] && compgen -G "$PACKAGE_PATH/*.whl" >/dev/null; then
			if validate_pypi_package "$PACKAGE_PATH"; then
				valid="true"
			fi
		else
			# No dist files yet, just validate metadata exists
			if [[ -n "$name" ]] && [[ -n "$version" ]]; then
				valid="true"
			fi
		fi
		;;
	npm)
		if validate_npm_package "$PACKAGE_PATH"; then
			name=$(grep -E '^\s*"name"\s*:' "$PACKAGE_PATH/package.json" | sed 's/.*:\s*"\([^"]*\)".*/\1/')
			version=$(extract_npm_version "$PACKAGE_PATH") || true
			valid="true"
		fi
		;;
	gem)
		if validate_gem_package "$PACKAGE_PATH"; then
			version=$(extract_gem_version "$PACKAGE_PATH") || true
			gemspec=$(find "$PACKAGE_PATH" -maxdepth 1 -name "*.gemspec" -print -quit 2>/dev/null || true)
			if [[ -n "$gemspec" ]]; then
				name=$(grep -E '\.(name)\s*=' "$gemspec" | head -1 | sed 's/.*=\s*["\x27]\([^"\x27]*\)["\x27].*/\1/' || true)
			fi
			valid="true"
		fi
		;;
	esac

	set_github_output "valid" "$valid"
	set_github_output "name" "$name"
	set_github_output "version" "$version"

	if [[ "$valid" == "true" ]]; then
		log_success "Package validation passed: $name@$version"
	else
		log_error "Package validation failed"
		exit 1
	fi
	;;

summary)
	: "${PACKAGE_NAME:=}"
	: "${PACKAGE_VERSION:=}"
	: "${VALID:=false}"

	add_github_summary "## Package Validation"
	add_github_summary ""
	add_github_summary "| Property | Value |"
	add_github_summary "| -------- | ----- |"
	add_github_summary "| Type | $PACKAGE_TYPE |"
	add_github_summary "| Name | $PACKAGE_NAME |"
	add_github_summary "| Version | $PACKAGE_VERSION |"

	if [[ "$VALID" == "true" ]]; then
		add_github_summary "| Status | :white_check_mark: Valid |"
	else
		add_github_summary "| Status | :x: Invalid |"
	fi
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
