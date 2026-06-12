#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Dispatch update-formula repository_dispatch to a Homebrew tap
#
# Environment variables:
#   STEP: dispatch
#   FORMULA: Homebrew formula name (required)
#   VERSION: Release version (required)
#   GH_TOKEN: Token for repository_dispatch on the tap repository (required)
#   TAP_REPOSITORY: Tap owner/repo (default: lgtm-hq/homebrew-tap)
#   PYPI_PACKAGE: PyPI package name (default: FORMULA)
#   BINARY_ARM64_SHA: macOS arm64 release asset SHA256 (optional)
#   BINARY_X86_SHA: macOS x86_64 release asset SHA256 (optional)
set -euo pipefail

: "${STEP:?STEP is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
source "$SCRIPT_DIR/../lib/actions.sh"

case "$STEP" in
dispatch)
	: "${FORMULA:?FORMULA is required}"
	: "${VERSION:?VERSION is required}"
	: "${GH_TOKEN:?GH_TOKEN is required}"

	tap_repository="${TAP_REPOSITORY:-lgtm-hq/homebrew-tap}"
	pypi_package="${PYPI_PACKAGE:-$FORMULA}"
	binary_arm64_sha="${BINARY_ARM64_SHA:-}"
	binary_x86_sha="${BINARY_X86_SHA:-}"

	if [[ -z "${FORMULA// /}" ]]; then
		die "FORMULA must not be empty"
	fi
	if [[ -z "${VERSION// /}" ]]; then
		die "VERSION must not be empty"
	fi
	if [[ -z "${GH_TOKEN// /}" ]]; then
		die "GH_TOKEN must not be empty"
	fi

	log_info "Dispatching update-formula for $FORMULA@$VERSION to $tap_repository..."

	_set_dispatch_failure_outputs() {
		set_github_output "dispatched" "false"
		set_github_output "tap-repository" "$tap_repository"
	}
	trap '_set_dispatch_failure_outputs' ERR

	payload_args=(
		--arg formula "$FORMULA"
		--arg version "$VERSION"
		--arg pypi_package "$pypi_package"
	)

	if [[ -n "${binary_arm64_sha// /}" || -n "${binary_x86_sha// /}" ]]; then
		if [[ -z "${binary_arm64_sha// /}" || -z "${binary_x86_sha// /}" ]]; then
			_set_dispatch_failure_outputs
			die "binary-arm64-sha and binary-x86-sha must both be set or both omitted"
		fi
		payload_args+=(
			--arg arm64_sha "$binary_arm64_sha"
			--arg x86_sha "$binary_x86_sha"
		)
		client_payload=$(
			jq -n \
				"${payload_args[@]}" \
				'{
					formula: $formula,
					version: $version,
					"pypi-package": $pypi_package,
					"binary-assets": {
						"arm64-sha": $arm64_sha,
						"x86-sha": $x86_sha
					}
				}'
		)
	else
		client_payload=$(
			jq -n \
				"${payload_args[@]}" \
				'{
					formula: $formula,
					version: $version,
					"pypi-package": $pypi_package
				}'
		)
	fi

	request_body=$(
		jq -n \
			--arg event_type "update-formula" \
			--argjson client_payload "$client_payload" \
			'{event_type: $event_type, client_payload: $client_payload}'
	)

	GH_TOKEN="$GH_TOKEN" gh api \
		"repos/${tap_repository}/dispatches" \
		--method POST \
		--input - <<<"$request_body"

	log_success "Dispatched update-formula to $tap_repository"
	trap - ERR
	set_github_output "dispatched" "true"
	set_github_output "tap-repository" "$tap_repository"
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
