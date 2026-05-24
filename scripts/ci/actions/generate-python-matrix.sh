#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate a GitHub Actions matrix for Python versions.

set -euo pipefail

: "${PYTHON_VERSION:=3.12}"
: "${PYTHON_VERSIONS:=}"

python3 - <<'PY'
import json
import os
import sys

raw_versions = os.environ.get("PYTHON_VERSIONS", "").strip()
fallback_version = os.environ.get("PYTHON_VERSION", "3.12").strip() or "3.12"
github_output = os.environ.get("GITHUB_OUTPUT")

if not github_output:
    print("GITHUB_OUTPUT is required", file=sys.stderr)
    sys.exit(1)

versions = [
    version.strip()
    for version in (raw_versions or fallback_version).split(",")
    if version.strip()
]

if not versions:
    versions = [fallback_version]

matrix = {"include": [{"python-version": version} for version in versions]}

with open(github_output, "a", encoding="utf-8") as output:
    output.write(f"matrix={json.dumps(matrix, separators=(',', ':'))}\n")

print(f"Python matrix: {', '.join(versions)}")
PY
