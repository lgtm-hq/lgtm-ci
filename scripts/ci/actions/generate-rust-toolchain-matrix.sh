#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate a GitHub Actions matrix for Rust toolchains.

set -euo pipefail

: "${RUST_TOOLCHAIN:=stable}"
: "${RUST_TOOLCHAINS:=}"

python3 - <<'PY'
import json
import os
import sys

raw_toolchains = os.environ.get("RUST_TOOLCHAINS", "").strip()
fallback_toolchain = os.environ.get("RUST_TOOLCHAIN", "stable").strip() or "stable"
github_output = os.environ.get("GITHUB_OUTPUT")

if not github_output:
    print("GITHUB_OUTPUT is required", file=sys.stderr)
    sys.exit(1)

toolchains = [
    toolchain.strip()
    for toolchain in (raw_toolchains or fallback_toolchain).split(",")
    if toolchain.strip()
]

if not toolchains:
    toolchains = [fallback_toolchain]

toolchains = list(dict.fromkeys(toolchains))

matrix = {"include": [{"rust-toolchain": toolchain} for toolchain in toolchains]}

with open(github_output, "a", encoding="utf-8") as output:
    output.write(f"matrix={json.dumps(matrix, separators=(',', ':'))}\n")

print(f"Rust toolchain matrix: {', '.join(toolchains)}")
PY
