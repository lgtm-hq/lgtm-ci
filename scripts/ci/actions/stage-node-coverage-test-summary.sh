#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Stage Node.js coverage summary for publish-test-summary artifact upload.

set -euo pipefail

: "${WORKING_DIRECTORY:=.}"
: "${COVERAGE_SUMMARY_FILE:?COVERAGE_SUMMARY_FILE is required}"

source_file="${WORKING_DIRECTORY}/${COVERAGE_SUMMARY_FILE}"

if [[ ! -f "$source_file" ]]; then
	echo "Coverage summary missing (${source_file}), skipping staging"
	exit 0
fi

dest="node-coverage-staged/${WORKING_DIRECTORY}/${COVERAGE_SUMMARY_FILE}"
mkdir -p "$(dirname "$dest")"
cp "$source_file" "$dest"
echo "Staged ${source_file} -> ${dest}"
