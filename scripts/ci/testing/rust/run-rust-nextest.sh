#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run workspace tests with cargo-nextest (JUnit output via nextest profile).

set -euo pipefail

: "${WORKSPACE:=true}"
: "${FEATURES:=--all-features}"
: "${EXTRA_ARGS:=}"
: "${NEXTEST_PROFILE:=ci}"
: "${NEXTEST_LOG_FILE:=rust-nextest.log}"

nextest_args=(run "--profile" "$NEXTEST_PROFILE")

if [[ "$WORKSPACE" == "true" ]]; then
	nextest_args+=(--workspace)
fi

if [[ -n "$FEATURES" ]]; then
	read -ra feature_args <<<"$FEATURES"
	nextest_args+=("${feature_args[@]}")
fi

if [[ -n "$EXTRA_ARGS" ]]; then
	read -ra extra <<<"$EXTRA_ARGS"
	nextest_args+=("${extra[@]}")
fi

echo "Running: cargo nextest ${nextest_args[*]}"
set +e
cargo nextest "${nextest_args[@]}" 2>&1 | tee "$NEXTEST_LOG_FILE"
exit_code=$?
set -e

exit "$exit_code"
