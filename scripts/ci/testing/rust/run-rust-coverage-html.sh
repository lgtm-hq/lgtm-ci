#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate a flat HTML coverage tree from in-job cargo llvm-cov profiling data.

set -euo pipefail

OUTPUT_DIR="${RUST_COVERAGE_HTML_DIR:-rust-coverage-html}"
TEMP_DIR="${OUTPUT_DIR}.tmp"

if ! command -v cargo-llvm-cov >/dev/null 2>&1; then
	echo "cargo-llvm-cov is required; run setup-rust-coverage.sh and run-rust-coverage.sh first." >&2
	exit 1
fi

rm -rf "${OUTPUT_DIR}" "${TEMP_DIR}"
cargo llvm-cov report --html --output-dir "${TEMP_DIR}"

# cargo-llvm-cov 0.8.x writes browsable HTML under <output-dir>/html/.
if [[ ! -d "${TEMP_DIR}/html" ]]; then
	echo "Expected ${TEMP_DIR}/html after cargo llvm-cov report --html" >&2
	exit 1
fi

if [[ ! -f "${TEMP_DIR}/html/index.html" ]]; then
	echo "Expected ${TEMP_DIR}/html/index.html after cargo llvm-cov report --html" >&2
	exit 1
fi

mv "${TEMP_DIR}/html" "${OUTPUT_DIR}"
rm -rf "${TEMP_DIR}"

echo "Rust coverage HTML written to ${OUTPUT_DIR}/"
