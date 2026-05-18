#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run frontend coverage from a web app package directory.

set -euo pipefail

WEB_DIR="${WEB_WORKING_DIRECTORY:-apps/web}"
LOG_FILE="${WEB_COVERAGE_LOG:-web-coverage-output.txt}"
case "$LOG_FILE" in
/*) ;;
*) LOG_FILE="$(pwd)/$LOG_FILE" ;;
esac

set +e
(
	set -e
	cd "$WEB_DIR" || exit 1
	bun install --frozen-lockfile
	bun run test:coverage
) >"$LOG_FILE" 2>&1
exit_code=$?
set -e

cat "$LOG_FILE"

if [[ -n "${GITHUB_ENV:-}" ]]; then
	echo "WEB_COVERAGE_EXIT_CODE=$exit_code" >>"$GITHUB_ENV"
fi

exit "$exit_code"
