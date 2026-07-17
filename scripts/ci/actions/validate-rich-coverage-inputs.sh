#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Require coverage-file when rich coverage comment generation is enabled.

set -euo pipefail

if [[ -z "${COVERAGE_FILE:-}" ]]; then
	echo "::error::rich-coverage-comment requires coverage-file (path to summary file)" >&2
	exit 1
fi
