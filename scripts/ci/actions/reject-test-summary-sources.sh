#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail reusable-publish-test-summary.yml when both junit-artifact and
#          results-artifact-pattern are set (#1686). The step runs only then,
#          before any artifact is downloaded; render-test-summary.sh refuses
#          the same pair again.

set -euo pipefail

echo "::error title=conflicting test summary sources::junit-artifact and" \
	"results-artifact-pattern cannot both be set: pass junit-artifact to count" \
	"from JUnit reports, or results-artifact-pattern to render results.v1 documents"
exit 1
