#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Aggregate per-leg results.v1 documents (#1080) for any language family.
#
# Reads every results.json under RESULTS_DIR (one per matrix leg, as the
# runner uploaded it), sums the counts, averages coverage, and publishes the
# aggregate as step outputs. Optionally writes the aggregate as one
# results.v1 document for the publishers.
#
# Environment:
#   RESULTS_DIR       (required) Directory containing per-leg results.json files.
#   MATRIX_JSON       (optional) Matrix JSON to validate the leg count against.
#   AGGREGATE_OUTPUT  (optional) Path to write the aggregated results.v1 document.
#
# Outputs (GITHUB_OUTPUT): tests-passed, tests-failed, tests-skipped,
#   tests-total, coverage-percent, status, passed.
#   coverage-percent is the single leg's value verbatim, or the mean of the
#   legs that report coverage formatted to two decimals; empty without
#   coverage. passed is true only when every leg's status is "passed".

set -euo pipefail

: "${RESULTS_DIR:?RESULTS_DIR is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/testing/results.sh
source "$SCRIPT_DIR/../lib/testing/results.sh"

schema="$(results_v1_schema)"

# Every leg must be a valid contract document before anything is summed.
while IFS= read -r file; do
	results_v1_validate "$file" "$schema"
done < <(find "$RESULTS_DIR" -type f -name 'results.json' | LC_ALL=C sort)

python3 -I - "$RESULTS_DIR" "${AGGREGATE_OUTPUT:-}" <<'PY'
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def load(path: Path) -> dict:
    """Load a results.v1 document keeping float literals verbatim."""
    return json.loads(path.read_text(encoding="utf-8"), parse_float=str)


results_dir = Path(sys.argv[1])
aggregate_output = sys.argv[2]
legs = sorted(results_dir.glob("**/results.json"))
if not legs:
    print(f"No results.json documents found in {results_dir}", file=sys.stderr)
    raise SystemExit(1)

github_output = os.environ.get("GITHUB_OUTPUT")
if not github_output:
    print("GITHUB_OUTPUT is required", file=sys.stderr)
    raise SystemExit(1)

matrix_json = os.environ.get("MATRIX_JSON", "")
if matrix_json:
    matrix = json.loads(matrix_json)
    expected = len(matrix.get("include", []))
    if len(legs) != expected:
        print(
            f"Expected {expected} matrix results, found {len(legs)} in {results_dir}",
            file=sys.stderr,
        )
        raise SystemExit(1)

docs = [load(leg) for leg in legs]
passed = sum(int(d["counts"]["passed"]) for d in docs)
failed = sum(int(d["counts"]["failed"]) for d in docs)
skipped = sum(int(d["counts"]["skipped"]) for d in docs)
total = sum(int(d["counts"]["total"]) for d in docs)
duration = sum(int(d["duration_ms"]) for d in docs)
coverage_raw = [d["coverage"]["lines"] for d in docs if "coverage" in d]
statuses = [d["status"] for d in docs]

coverage_percent = ""
coverage_value: object = None
if len(coverage_raw) == 1:
    # One leg: its literal, so a caller sees exactly what the runner wrote.
    coverage_percent = str(coverage_raw[0])
    coverage_value = coverage_raw[0]
elif coverage_raw:
    mean = sum(float(v) for v in coverage_raw) / len(coverage_raw)
    coverage_percent = f"{mean:.2f}"
    coverage_value = coverage_percent

if any(s == "error" for s in statuses):
    status = "error"
elif any(s == "failed" for s in statuses):
    status = "failed"
elif all(s == "no-tests" for s in statuses):
    status = "no-tests"
else:
    status = "passed"
all_passed = all(s == "passed" for s in statuses)

with Path(github_output).open("a", encoding="utf-8") as output:
    output.write(f"tests-passed={passed}\n")
    output.write(f"tests-failed={failed}\n")
    output.write(f"tests-skipped={skipped}\n")
    output.write(f"tests-total={total}\n")
    output.write(f"coverage-percent={coverage_percent}\n")
    output.write(f"status={status}\n")
    output.write(f"passed={str(all_passed).lower()}\n")

if aggregate_output:
    # Serialise with the raw float literals re-inserted so the aggregate
    # carries the same number text as the legs.
    artifacts = [a for d in docs for a in d["artifacts"]]
    tools = sorted({d["tool"] for d in docs})
    doc: dict = {
        "tool": tools[0] if len(tools) == 1 else "+".join(tools),
        "status": status,
        "counts": {
            "passed": passed,
            "failed": failed,
            "skipped": skipped,
            "total": total,
        },
        "duration_ms": duration,
    }
    if coverage_value is not None:
        doc["coverage"] = {"lines": "@@COVERAGE@@"}
    doc["artifacts"] = artifacts
    doc["source"] = {
        "runner": "aggregate-results",
        "version": docs[0]["source"]["version"],
    }
    text = json.dumps(doc, indent=2)
    if coverage_value is not None:
        text = text.replace('"@@COVERAGE@@"', str(coverage_value))
    out = Path(aggregate_output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text + "\n", encoding="utf-8")
PY

if [[ -n "${AGGREGATE_OUTPUT:-}" ]]; then
	results_v1_validate "$AGGREGATE_OUTPUT" "$schema"
fi
