#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run Rust workspace coverage and write an LCOV report.

set -euo pipefail

OUTPUT_FILE="${RUST_COVERAGE_OUTPUT:-rust-coverage.lcov}"
LOG_FILE="${RUST_COVERAGE_LOG:-rust-coverage-output.txt}"
CARGO_LLVM_COV_VERSION="${CARGO_LLVM_COV_VERSION:-0.8.6}"

if ! command -v cargo-llvm-cov >/dev/null 2>&1; then
	echo "Installing cargo-llvm-cov ${CARGO_LLVM_COV_VERSION}..."
	if command -v cargo-binstall >/dev/null 2>&1; then
		cargo binstall cargo-llvm-cov \
			--version "$CARGO_LLVM_COV_VERSION" \
			--no-confirm ||
			cargo install cargo-llvm-cov \
				--locked \
				--version "$CARGO_LLVM_COV_VERSION"
	else
		cargo install cargo-llvm-cov \
			--locked \
			--version "$CARGO_LLVM_COV_VERSION"
	fi
fi

set +e
cargo llvm-cov \
	--workspace \
	--all-features \
	--lcov \
	--output-path "$OUTPUT_FILE" \
	>"$LOG_FILE" 2>&1
exit_code=$?
set -e

cat "$LOG_FILE"

if [[ -n "${GITHUB_ENV:-}" ]]; then
	echo "RUST_COVERAGE_EXIT_CODE=$exit_code" >>"$GITHUB_ENV"
fi

exit "$exit_code"
