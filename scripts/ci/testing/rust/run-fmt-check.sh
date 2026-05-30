#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run cargo fmt --check for the Rust workspace.

set -euo pipefail

: "${WORKSPACE:=true}"

cargo_args=()
if [[ "$WORKSPACE" == "true" ]]; then
	cargo_args+=(--workspace)
fi

echo "Running: cargo fmt --check ${cargo_args[*]}"
cargo fmt --check "${cargo_args[@]}"
