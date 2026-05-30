#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Report whether flat pages coverage HTML was uploaded this workflow run.

set -euo pipefail

if [[ "${UPLOAD_PAGES_COVERAGE_HTML:-false}" != "true" || "${COVERAGE:-false}" != "true" ]]; then
	echo "uploaded=false" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
	exit 0
fi

if [[ "${PAGES_UPLOAD_OUTCOME:-}" == "success" ]]; then
	echo "uploaded=true" >>"$GITHUB_OUTPUT"
else
	echo "uploaded=false" >>"$GITHUB_OUTPUT"
fi
