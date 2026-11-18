#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run classify-lint-timeout.py and never fail the step
#
# The verdict is advisory: a missing report or a classifier fault leaves the
# outputs empty, which every consumer reads as "not a timeout flake", instead
# of changing the lint result. A composite action cannot set
# continue-on-error, so the run-quality action calls this wrapper (#1624).
#
# Environment variables:
#   REPORT        - Path to lintro's JSON report
#   GITHUB_OUTPUT - Step output file the classifier writes to

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! python3 "${SCRIPT_DIR}/classify-lint-timeout.py" --report "${REPORT:-}"; then
	echo "::warning::lint timeout classification failed"
fi
exit 0
