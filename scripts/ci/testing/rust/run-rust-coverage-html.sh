#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate a flat HTML coverage tree from in-job cargo llvm-cov profiling data.

set -euo pipefail

OUTPUT_DIR="${RUST_COVERAGE_HTML_DIR:-rust-coverage-html}"
TEMP_DIR="${OUTPUT_DIR}.tmp"

_validate_rust_coverage_html_dir() {
	local dir="$1"

	if [[ -z "$dir" || "$dir" == "." || "$dir" == ".." || "$dir" == "/" ]]; then
		echo "Unsafe RUST_COVERAGE_HTML_DIR: ${dir:-<empty>}" >&2
		return 1
	fi

	if [[ "$dir" == /* ]]; then
		echo "RUST_COVERAGE_HTML_DIR must be repo-relative: ${dir}" >&2
		return 1
	fi

	if [[ "$dir" == *".."* ]]; then
		echo "RUST_COVERAGE_HTML_DIR must not contain .. segments: ${dir}" >&2
		return 1
	fi

	local repo_root="${GITHUB_WORKSPACE:-}"
	if [[ -z "$repo_root" ]] && git rev-parse --show-toplevel >/dev/null 2>&1; then
		repo_root="$(git rev-parse --show-toplevel)"
	fi
	if [[ -z "$repo_root" ]]; then
		repo_root="$(pwd -P)"
	fi

	local resolved_dir
	if ! resolved_dir="$(
		python3 - "$repo_root" "$dir" <<'PY'
import os
import sys

root = os.path.realpath(sys.argv[1])
target = os.path.realpath(os.path.join(root, sys.argv[2]))
if target == root or target.startswith(root + os.sep):
    print(target)
    sys.exit(0)
sys.exit(1)
PY
	)"; then
		echo "RUST_COVERAGE_HTML_DIR must stay within repository root: ${dir}" >&2
		return 1
	fi

	return 0
}

if ! command -v cargo-llvm-cov >/dev/null 2>&1; then
	echo "cargo-llvm-cov is required; run setup-rust-coverage.sh and run-rust-coverage.sh first." >&2
	exit 1
fi

if ! _validate_rust_coverage_html_dir "$OUTPUT_DIR"; then
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
