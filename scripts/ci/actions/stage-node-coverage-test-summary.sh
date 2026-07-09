#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Stage Node.js coverage summary for publish-test-summary artifact upload.

set -euo pipefail

: "${WORKING_DIRECTORY:=.}"
: "${COVERAGE_SUMMARY_FILE:?COVERAGE_SUMMARY_FILE is required}"
: "${COVERAGE:?COVERAGE is required (true or false)}"

source_file="${WORKING_DIRECTORY}/${COVERAGE_SUMMARY_FILE}"

if [[ ! -f "$source_file" ]]; then
	if [[ "$COVERAGE" == "true" ]]; then
		echo "::error::Coverage was requested (coverage: true) but the coverage summary file is missing: ${source_file}. Ensure the test command writes ${COVERAGE_SUMMARY_FILE} under ${WORKING_DIRECTORY}."
		exit 1
	fi
	echo "::notice::Coverage not requested and coverage summary file absent (${source_file}); skipping coverage staging."
	exit 0
fi

dest="node-coverage-staged/${WORKING_DIRECTORY}/${COVERAGE_SUMMARY_FILE}"
mkdir -p "$(dirname "$dest")"
cp "$source_file" "$dest"
echo "Staged ${source_file} -> ${dest}"
