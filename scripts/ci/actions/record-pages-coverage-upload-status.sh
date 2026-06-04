#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Report whether flat pages coverage HTML was uploaded this workflow run.

set -euo pipefail

output="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if [[ "${UPLOAD_PAGES_COVERAGE_HTML:-false}" != "true" || "${COVERAGE:-false}" != "true" ]]; then
	echo "uploaded=false" >>"$output"
	exit 0
fi

# Prefer artifact presence: matrix job outputs are not reliable for pages upload.
if [[ -n "${PAGES_COVERAGE_ARTIFACT_DIR:-}" && -d "${PAGES_COVERAGE_ARTIFACT_DIR}" ]]; then
	if [[ -n "$(find "${PAGES_COVERAGE_ARTIFACT_DIR}" -type f -print -quit 2>/dev/null)" ]]; then
		echo "uploaded=true" >>"$output"
		exit 0
	fi
fi

if [[ "${PAGES_UPLOAD_OUTCOME:-}" == "success" ]]; then
	echo "uploaded=true" >>"$output"
else
	echo "uploaded=false" >>"$output"
fi
