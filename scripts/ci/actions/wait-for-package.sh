#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Wait for a package to be available on a registry
#
# Environment variables:
#   STEP: check | wait | summary
#   REGISTRY: pypi | npm | gem
#   PACKAGE: Package name
#   VERSION: Package version
#   MAX_WAIT: Maximum wait time in seconds (default: 600)
#   TEST_PYPI: Use TestPyPI instead of PyPI (default: false)
#   AVAILABLE: (summary step) Whether package is available (default: false)
#   ELAPSED: (summary step) Seconds elapsed waiting (default: 0)
set -euo pipefail

: "${STEP:?STEP is required}"
: "${REGISTRY:?REGISTRY is required}"
: "${PACKAGE:?PACKAGE is required}"
: "${VERSION:?VERSION is required}"
: "${MAX_WAIT:=600}"
: "${TEST_PYPI:=false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/actions.sh"
source "$SCRIPT_DIR/../lib/publish.sh"

case "$STEP" in
check)
	log_info "Checking if $PACKAGE@$VERSION is available on $REGISTRY..."

	available="false"

	case "$REGISTRY" in
	pypi)
		if check_pypi_availability "$PACKAGE" "$VERSION" "$TEST_PYPI"; then
			available="true"
		fi
		;;
	npm)
		if check_npm_availability "$PACKAGE" "$VERSION"; then
			available="true"
		fi
		;;
	gem | rubygems)
		if check_rubygems_availability "$PACKAGE" "$VERSION"; then
			available="true"
		fi
		;;
	*)
		die "Unknown registry: $REGISTRY"
		;;
	esac

	set_github_output "available" "$available"

	if [[ "$available" == "true" ]]; then
		log_success "$PACKAGE@$VERSION is available on $REGISTRY"
	else
		log_info "$PACKAGE@$VERSION is not yet available on $REGISTRY"
	fi
	;;

wait)
	log_info "Waiting for $PACKAGE@$VERSION on $REGISTRY (max ${MAX_WAIT}s)..."

	start_time=$(date +%s)
	available="false"

	if wait_for_package "$REGISTRY" "$PACKAGE" "$VERSION" "$MAX_WAIT" "$TEST_PYPI"; then
		available="true"
	fi

	elapsed=$(($(date +%s) - start_time))

	set_github_output "available" "$available"
	set_github_output "elapsed" "$elapsed"

	if [[ "$available" == "true" ]]; then
		log_success "$PACKAGE@$VERSION is now available (waited ${elapsed}s)"
	else
		log_error "Timeout waiting for $PACKAGE@$VERSION after ${elapsed}s"
		exit 1
	fi
	;;

summary)
	: "${AVAILABLE:=false}"
	: "${ELAPSED:=0}"

	add_github_summary "## Package Availability"
	add_github_summary ""
	add_github_summary "| Property | Value |"
	add_github_summary "| -------- | ----- |"
	add_github_summary "| Registry | $REGISTRY |"
	add_github_summary "| Package | $PACKAGE |"
	add_github_summary "| Version | $VERSION |"

	if [[ "$ELAPSED" != "0" ]]; then
		add_github_summary "| Wait Time | ${ELAPSED}s |"
	fi

	if [[ "$AVAILABLE" == "true" ]]; then
		add_github_summary "| Status | :white_check_mark: Available |"
	else
		add_github_summary "| Status | :x: Not Available |"
	fi
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
