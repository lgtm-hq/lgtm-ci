#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Decide whether flat Pages coverage HTML artifacts should upload this run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/pages_coverage.sh
source "$SCRIPT_DIR/../lib/pages_coverage.sh"

UPLOAD_ON="${PAGES_COVERAGE_UPLOAD_ON:-push-main}"
EVENT="${GITHUB_EVENT_NAME:-}"
REF="${GITHUB_REF:-}"

should_upload=$(resolve_pages_coverage_should_upload "$UPLOAD_ON" "$EVENT" "$REF")

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	echo "should-upload=${should_upload}" >>"$GITHUB_OUTPUT"
fi
