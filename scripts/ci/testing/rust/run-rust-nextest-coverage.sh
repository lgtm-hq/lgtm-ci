#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run instrumented tests once via cargo llvm-cov nextest (JUnit + LCOV).

set -euo pipefail

: "${WORKSPACE:=true}"
: "${FEATURES:=--all-features}"
: "${EXTRA_ARGS:=}"
: "${NEXTEST_PROFILE:=ci}"
: "${LCOV_OUTPUT_FILE:=rust-coverage.lcov}"
: "${NEXTEST_LOG_FILE:=rust-nextest.log}"

nextest_args=(--profile "$NEXTEST_PROFILE")

if [[ "$WORKSPACE" == "true" ]]; then
	nextest_args+=(--workspace)
fi

if [[ -n "$FEATURES" ]]; then
	mapfile -t feature_args <<<"$FEATURES"
	nextest_args+=("${feature_args[@]}")
fi

if [[ -n "$EXTRA_ARGS" ]]; then
	mapfile -t extra <<<"$EXTRA_ARGS"
	nextest_args+=("${extra[@]}")
fi

llvm_cov_args=(
	llvm-cov
	nextest
	"${nextest_args[@]}"
	--lcov
	--output-path
	"$LCOV_OUTPUT_FILE"
)

echo "Running: cargo ${llvm_cov_args[*]}"
set +e
cargo "${llvm_cov_args[@]}" 2>&1 | tee "$NEXTEST_LOG_FILE"
exit_code=$?
set -e

if [[ -n "${GITHUB_ENV:-}" ]]; then
	echo "RUST_COVERAGE_EXIT_CODE=$exit_code" >>"$GITHUB_ENV"
fi

exit "$exit_code"
