#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Reject multi-runtime matrix combined with coverage or PR publish.
#
# Required environment variables:
#   MULTI_VERSIONS - Comma-separated runtime versions; non-empty enables matrix mode
#   COVERAGE       - true/false
#   PUBLISH_TEST_SUMMARY - true/false
#   PLATFORM       - Human-readable platform label for error messages

set -euo pipefail

: "${MULTI_VERSIONS:=}"
: "${COVERAGE:=false}"
: "${PUBLISH_TEST_SUMMARY:=false}"
: "${PLATFORM:=test}"

versions="$(
	python3 - <<'PY'
import os

raw = os.environ.get("MULTI_VERSIONS", "").strip()
versions = [version.strip() for version in raw.split(",") if version.strip()]
print(",".join(versions))
PY
)"

if [[ -z "$versions" ]]; then
	exit 0
fi

invalid=()
if [[ "${COVERAGE}" == "true" ]]; then
	invalid+=("coverage: true")
fi
if [[ "${PUBLISH_TEST_SUMMARY}" == "true" ]]; then
	invalid+=("publish-test-summary: true")
fi

if ((${#invalid[@]} == 0)); then
	exit 0
fi

joined_invalid=$(
	IFS=", "
	echo "${invalid[*]}"
)
echo "::error::${PLATFORM}: multi-runtime matrix (${versions}) cannot be combined with ${joined_invalid}. Use compat mode (matrix, coverage: false, publish-test-summary: false) and a separate single-runtime job for coverage and PR comments."
exit 1
