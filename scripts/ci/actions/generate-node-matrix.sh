#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate a GitHub Actions matrix for Node.js versions.

set -euo pipefail

: "${NODE_VERSION:=20}"
: "${NODE_VERSIONS:=}"

python3 - <<'PY'
import json
import os
import sys

raw_versions = os.environ.get("NODE_VERSIONS", "").strip()
fallback_version = os.environ.get("NODE_VERSION", "20").strip() or "20"
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

matrix = {"include": [{"node-version": version} for version in versions]}

with open(github_output, "a", encoding="utf-8") as output:
    output.write(f"matrix={json.dumps(matrix, separators=(',', ':'))}\n")
    output.write(f"pages-coverage-node-version={versions[0]}\n")

print(f"Node.js matrix: {', '.join(versions)}")
print(f"Pages coverage node version: {versions[0]}")
PY
