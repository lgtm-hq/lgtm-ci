#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail the job when a coverage step reported a non-zero exit code.

set -euo pipefail

: "${COVERAGE_NAME:=Coverage}"

case "$COVERAGE_NAME" in
Rust) exit_code="${RUST_COVERAGE_EXIT_CODE:-1}" ;;
Web) exit_code="${WEB_COVERAGE_EXIT_CODE:-1}" ;;
*) exit_code="${COVERAGE_EXIT_CODE:-1}" ;;
esac

if [[ "$exit_code" != "0" ]]; then
	echo "${COVERAGE_NAME} coverage failed with exit code ${exit_code}"
	exit "$exit_code"
fi

echo "${COVERAGE_NAME} coverage completed successfully"
