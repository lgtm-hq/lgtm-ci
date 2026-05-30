#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run cargo clippy for the Rust workspace.

set -euo pipefail

: "${WORKSPACE:=true}"
: "${FEATURES:=--all-features}"
: "${CLIPPY_ARGS:=-- -D warnings}"

cargo_args=()
if [[ "$WORKSPACE" == "true" ]]; then
	cargo_args+=(--workspace)
fi
if [[ -n "$FEATURES" ]]; then
	read -ra feature_args <<<"$FEATURES"
	cargo_args+=("${feature_args[@]}")
fi

clippy_args=(clippy "${cargo_args[@]}")
if [[ -n "$CLIPPY_ARGS" ]]; then
	read -ra extra <<<"$CLIPPY_ARGS"
	clippy_args+=("${extra[@]}")
fi

echo "Running: cargo ${clippy_args[*]}"
cargo "${clippy_args[@]}"
