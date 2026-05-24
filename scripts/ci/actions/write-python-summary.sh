#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Write a per-matrix Python test summary for aggregation.

set -euo pipefail

: "${PYTHON_VERSION:?PYTHON_VERSION is required}"
: "${TESTS_PASSED:=0}"
: "${TESTS_FAILED:=0}"
: "${TESTS_TOTAL:=0}"
: "${COVERAGE_PERCENT:=}"
: "${PASSED:=false}"

summary_dir="python-result-${PYTHON_VERSION}"
mkdir -p "$summary_dir"

python3 - "$summary_dir/summary.json" <<'PY'
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

summary = {
    "python-version": os.environ["PYTHON_VERSION"],
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
