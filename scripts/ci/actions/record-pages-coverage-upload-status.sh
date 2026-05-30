#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Report whether flat pages coverage HTML was uploaded this workflow run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/pages_coverage.sh
source "$SCRIPT_DIR/../lib/pages_coverage.sh"

if [[ "${UPLOAD_PAGES_COVERAGE_HTML:-false}" != "true" || "${COVERAGE:-false}" != "true" ]]; then
	echo "uploaded=false" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
	exit 0
fi

active_result="${TEST_VITEST_RESULT:-skipped}"
if [[ -n "${TEST_COMMAND:-}" ]]; then
	active_result="${TEST_CUSTOM_RESULT:-skipped}"
fi

if [[ "$active_result" != "success" ]]; then
	echo "uploaded=false" >>"$GITHUB_OUTPUT"
	exit 0
fi

should_upload=$(resolve_pages_coverage_should_upload \
	"${PAGES_COVERAGE_UPLOAD_ON:-push-main}" \
	"${GITHUB_EVENT_NAME:-}" \
	"${GITHUB_REF:-}")

echo "uploaded=${should_upload}" >>"$GITHUB_OUTPUT"
