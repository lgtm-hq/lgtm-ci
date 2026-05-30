#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run cargo fmt --check for the Rust workspace.

set -euo pipefail

: "${WORKSPACE:=true}"
: "${FEATURES:=--all-features}"

cargo_args=()
if [[ "$WORKSPACE" == "true" ]]; then
	cargo_args+=(--workspace)
fi
if [[ -n "$FEATURES" ]]; then
	read -ra feature_args <<<"$FEATURES"
	cargo_args+=("${feature_args[@]}")
fi

echo "Running: cargo fmt --check ${cargo_args[*]}"
cargo fmt --check "${cargo_args[@]}"
