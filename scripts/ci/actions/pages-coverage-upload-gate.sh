#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Decide whether flat Pages coverage HTML artifacts should upload this run.

set -euo pipefail

UPLOAD_ON="${PAGES_COVERAGE_UPLOAD_ON:-push-main}"
EVENT="${GITHUB_EVENT_NAME:-}"
REF="${GITHUB_REF:-}"

should_upload=false

case "$UPLOAD_ON" in
push-main)
	if [[ "$EVENT" == "push" && "$REF" == "refs/heads/main" ]]; then
		should_upload=true
	fi
	;;
*)
	echo "Unsupported pages-coverage-upload-on value: ${UPLOAD_ON}" >&2
	exit 1
	;;
esac

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	echo "should-upload=${should_upload}" >>"$GITHUB_OUTPUT"
fi
