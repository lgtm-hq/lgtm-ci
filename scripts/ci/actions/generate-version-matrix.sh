#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate a GitHub Actions matrix for language versions or toolchains.
#
# Environment:
#   MATRIX_KEY           (required) Matrix field name, e.g. node-version,
#                        python-version, rust-toolchain.
#   DEFAULT_VERSION      (required) Version used when VERSIONS_INPUT is empty.
#   VERSIONS_INPUT       (optional) Comma-separated versions for a matrix.
#   MATRIX_LABEL         (optional) Human-readable label for log lines;
#                        defaults to MATRIX_KEY.
#   FIRST_VERSION_OUTPUT (optional) When set, also writes
#                        "<FIRST_VERSION_OUTPUT>=<first version>" to GITHUB_OUTPUT.

set -euo pipefail

: "${MATRIX_KEY:?MATRIX_KEY is required}"
: "${DEFAULT_VERSION:?DEFAULT_VERSION is required}"
: "${VERSIONS_INPUT:=}"
: "${MATRIX_LABEL:=${MATRIX_KEY}}"
: "${FIRST_VERSION_OUTPUT:=}"

export MATRIX_KEY DEFAULT_VERSION VERSIONS_INPUT MATRIX_LABEL FIRST_VERSION_OUTPUT

python3 - <<'PY'
import json
import os
import sys

matrix_key = os.environ["MATRIX_KEY"]
matrix_label = os.environ["MATRIX_LABEL"]
raw_versions = os.environ.get("VERSIONS_INPUT", "").strip()
fallback_version = os.environ["DEFAULT_VERSION"].strip()
first_version_output = os.environ.get("FIRST_VERSION_OUTPUT", "").strip()
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

versions = list(dict.fromkeys(versions))

matrix = {"include": [{matrix_key: version} for version in versions]}

with open(github_output, "a", encoding="utf-8") as output:
    output.write(f"matrix={json.dumps(matrix, separators=(',', ':'))}\n")
    if first_version_output:
        output.write(f"{first_version_output}={versions[0]}\n")

print(f"{matrix_label} matrix: {', '.join(versions)}")
if first_version_output:
    print(f"First matrix version ({first_version_output}): {versions[0]}")
PY
