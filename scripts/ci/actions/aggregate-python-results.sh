#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Aggregate per-matrix Python test result summaries.

set -euo pipefail

: "${RESULTS_DIR:=python-results}"

python3 - "$RESULTS_DIR" <<'PY'
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def as_int(value: object) -> int:
    """Convert a result field to an integer."""
    if value in ("", None):
        return 0
    return int(value)


def as_float(value: object) -> float | None:
    """Convert a result field to a float when present."""
    if value in ("", None):
        return None
    return float(value)


results_dir = Path(sys.argv[1])
summaries = sorted(results_dir.glob("**/summary.json"))
if not summaries:
    print(f"No matrix summaries found in {results_dir}", file=sys.stderr)
    raise SystemExit(1)

github_output = os.environ.get("GITHUB_OUTPUT")
if not github_output:
    print("GITHUB_OUTPUT is required", file=sys.stderr)
    raise SystemExit(1)

matrix_json = os.environ.get("MATRIX_JSON", "")
if matrix_json:
    matrix = json.loads(matrix_json)
    expected = len(matrix.get("include", []))
    if len(summaries) != expected:
        print(
            f"Expected {expected} matrix summaries, found {len(summaries)} in {results_dir}",
            file=sys.stderr,
        )
        raise SystemExit(1)

passed = 0
failed = 0
total = 0
coverage_values: list[float] = []
all_passed = True

for summary in summaries:
    data = json.loads(summary.read_text(encoding="utf-8"))
    passed += as_int(data.get("tests-passed"))
    failed += as_int(data.get("tests-failed"))
    total += as_int(data.get("tests-total"))
    coverage = as_float(data.get("coverage-percent"))
    if coverage is not None:
        coverage_values.append(coverage)
    if data.get("passed") != "true":
        all_passed = False

coverage_percent = ""
if coverage_values:
    coverage_percent = f"{sum(coverage_values) / len(coverage_values):.2f}"

with Path(github_output).open("a", encoding="utf-8") as output:
    output.write(f"tests-passed={passed}\n")
    output.write(f"tests-failed={failed}\n")
    output.write(f"tests-total={total}\n")
    output.write(f"coverage-percent={coverage_percent}\n")
    output.write(f"passed={str(all_passed).lower()}\n")
PY
