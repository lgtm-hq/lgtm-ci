#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Shared helpers for Model B pages coverage upload gating.

[[ -n "${_PAGES_COVERAGE_LOADED:-}" ]] && return 0
readonly _PAGES_COVERAGE_LOADED=1

# Echo true/false for whether flat pages coverage HTML should upload.
# Exits 1 when upload-on is unsupported.
resolve_pages_coverage_should_upload() {
	local upload_on="${1:-push-main}"
	local event="${2:-${GITHUB_EVENT_NAME:-}}"
	local ref="${3:-${GITHUB_REF:-}}"

	case "$upload_on" in
	push-main)
		if [[ "$event" == "push" && "$ref" == "refs/heads/main" ]]; then
			echo "true"
		else
			echo "false"
		fi
		;;
	*)
		echo "Unsupported pages-coverage-upload-on value: ${upload_on}" >&2
		return 1
		;;
	esac
}
