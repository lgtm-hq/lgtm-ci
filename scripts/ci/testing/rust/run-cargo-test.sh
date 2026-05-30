#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run cargo test for the Rust workspace.

set -euo pipefail

: "${WORKSPACE:=true}"
: "${FEATURES:=--all-features}"
: "${EXTRA_ARGS:=}"
: "${TEST_LOG_FILE:=rust-test.log}"

cargo_args=()
if [[ "$WORKSPACE" == "true" ]]; then
	cargo_args+=(--workspace)
fi
if [[ -n "$FEATURES" ]]; then
	read -ra feature_args <<<"$FEATURES"
	cargo_args+=("${feature_args[@]}")
fi

test_args=(test "${cargo_args[@]}")
if [[ -n "$EXTRA_ARGS" ]]; then
	read -ra extra <<<"$EXTRA_ARGS"
	test_args+=("${extra[@]}")
fi

echo "Running: cargo ${test_args[*]}"
cargo "${test_args[@]}" 2>&1 | tee "$TEST_LOG_FILE"
