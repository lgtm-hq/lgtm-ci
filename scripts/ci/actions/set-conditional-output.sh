#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Set a GitHub Actions step output from a simple equality check.
#
# Required environment variables:
#   OUTPUT_NAME      - Output key to write
#   CONDITION_VALUE  - Value to compare (may be empty)
# Optional:
#   MATCH_VALUE      - Value that yields the true branch (default: success)
#   TRUE_VALUE       - Output when CONDITION_VALUE matches (default: true)
#   FALSE_VALUE      - Output when CONDITION_VALUE does not match (default: false)

set -euo pipefail

: "${OUTPUT_NAME:?OUTPUT_NAME is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

# CONDITION_VALUE may intentionally be empty (unset → empty string).
CONDITION_VALUE="${CONDITION_VALUE-}"
MATCH_VALUE="${MATCH_VALUE:-success}"
TRUE_VALUE="${TRUE_VALUE:-true}"
FALSE_VALUE="${FALSE_VALUE:-false}"

if [[ "${CONDITION_VALUE}" == "${MATCH_VALUE}" ]]; then
	echo "${OUTPUT_NAME}=${TRUE_VALUE}" >>"${GITHUB_OUTPUT}"
else
	echo "${OUTPUT_NAME}=${FALSE_VALUE}" >>"${GITHUB_OUTPUT}"
fi
