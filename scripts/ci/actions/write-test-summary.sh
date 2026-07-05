#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Write a per-matrix test summary for aggregation, for any language family.
#
# Environment:
#   MATRIX_KEY        (required) Matrix field name, e.g. python-version, rust-toolchain.
#   MATRIX_VALUE      (required) Matrix field value, e.g. 3.12, stable.
#   SUMMARY_DIR       (optional) Output directory; defaults to
#                     "<family>-result-<MATRIX_VALUE>" where <family> is the first
#                     dash-separated component of MATRIX_KEY.
#   TESTS_PASSED, TESTS_FAILED, TESTS_TOTAL, COVERAGE_PERCENT, PASSED (optional)

set -euo pipefail

: "${MATRIX_KEY:?MATRIX_KEY is required}"
: "${MATRIX_VALUE:?MATRIX_VALUE is required}"
: "${SUMMARY_DIR:=${MATRIX_KEY%%-*}-result-${MATRIX_VALUE}}"
: "${TESTS_PASSED:=0}"
: "${TESTS_FAILED:=0}"
: "${TESTS_TOTAL:=0}"
: "${COVERAGE_PERCENT:=}"
: "${PASSED:=false}"

export MATRIX_KEY MATRIX_VALUE TESTS_PASSED TESTS_FAILED TESTS_TOTAL COVERAGE_PERCENT PASSED

mkdir -p "$SUMMARY_DIR"

python3 - "$SUMMARY_DIR/summary.json" <<'PY'
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

summary = {
    os.environ["MATRIX_KEY"]: os.environ["MATRIX_VALUE"],
    "tests-passed": os.environ["TESTS_PASSED"],
    "tests-failed": os.environ["TESTS_FAILED"],
    "tests-total": os.environ["TESTS_TOTAL"],
    "coverage-percent": os.environ["COVERAGE_PERCENT"],
    "passed": os.environ["PASSED"],
}

Path(sys.argv[1]).write_text(
    json.dumps(summary, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
