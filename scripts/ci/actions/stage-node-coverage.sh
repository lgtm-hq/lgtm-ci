#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Stage Node.js coverage artifacts under a matrix-specific directory.

set -euo pipefail

: "${NODE_VERSION:?NODE_VERSION is required}"
: "${WORKING_DIRECTORY:=.}"

target_dir="node-coverage-${NODE_VERSION}"
mkdir -p "$target_dir"

if [[ -d "${WORKING_DIRECTORY}/coverage" ]]; then
	cp -R "${WORKING_DIRECTORY}/coverage" "$target_dir/"
fi

if [[ -f "${WORKING_DIRECTORY}/vitest-results.json" ]]; then
	cp "${WORKING_DIRECTORY}/vitest-results.json" "$target_dir/"
fi
