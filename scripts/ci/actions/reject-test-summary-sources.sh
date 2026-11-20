#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail reusable-publish-test-summary.yml when both junit-artifact and
#          results-artifact-pattern are set (#1686). The step runs before any
#          artifact is downloaded; render-test-summary.sh refuses the same pair
#          again.
#
# Environment:
#   JUNIT_ARTIFACT            the junit-artifact input
#   RESULTS_ARTIFACT_PATTERN  the results-artifact-pattern input
# Exits 1 when both are non-empty, 0 otherwise. The values are never printed.

set -euo pipefail

if [[ -n "${JUNIT_ARTIFACT:-}" && -n "${RESULTS_ARTIFACT_PATTERN:-}" ]]; then
	echo "::error title=conflicting test summary sources::junit-artifact and" \
		"results-artifact-pattern cannot both be set: pass junit-artifact to count" \
		"from JUnit reports, or results-artifact-pattern to render results.v1 documents"
	exit 1
fi
exit 0
