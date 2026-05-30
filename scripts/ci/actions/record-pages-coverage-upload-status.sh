#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Report whether flat pages coverage HTML was uploaded this workflow run.

set -euo pipefail

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

PAGES_COVERAGE_UPLOAD_ON="${PAGES_COVERAGE_UPLOAD_ON:-push-main}"
EVENT="${GITHUB_EVENT_NAME:-}"
REF="${GITHUB_REF:-}"

should_upload=false
case "$PAGES_COVERAGE_UPLOAD_ON" in
push-main)
	if [[ "$EVENT" == "push" && "$REF" == "refs/heads/main" ]]; then
		should_upload=true
	fi
	;;
*)
	echo "Unsupported pages-coverage-upload-on value: ${PAGES_COVERAGE_UPLOAD_ON}" >&2
	exit 1
	;;
esac

echo "uploaded=${should_upload}" >>"$GITHUB_OUTPUT"
