#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for run-rust-coverage-html.sh flatten layout

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	cd "$BATS_TEST_TMPDIR" || return 1
	export SCRIPT="$PROJECT_ROOT/scripts/ci/testing/rust/run-rust-coverage-html.sh"
}

teardown() {
	teardown_temp_dir
}

_install_fake_cargo_llvm_cov() {
	local mode="${1:-html}"
	local bin_dir="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/cargo-llvm-cov" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	if [[ "$mode" == "no-html" ]]; then
		cat >"${bin_dir}/cargo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	else
		cat >"${bin_dir}/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "llvm-cov" && "${2:-}" == "report" && "${3:-}" == "--html" ]]; then
	output_dir=""
	for ((i = 4; i <= $#; i++)); do
		if [[ "${!i}" == "--output-dir" ]]; then
			next=$((i + 1))
			output_dir="${!next}"
		fi
	done
	mkdir -p "${output_dir}/html"
	echo '<html>rust coverage</html>' >"${output_dir}/html/index.html"
	exit 0
fi
echo "unexpected cargo invocation: $*" >&2
exit 1
EOF
	fi
	chmod +x "${bin_dir}/cargo-llvm-cov" "${bin_dir}/cargo"
	export PATH="${bin_dir}:$PATH"
}

@test "run-rust-coverage-html: flattens cargo llvm-cov html layout" {
	_install_fake_cargo_llvm_cov

	RUST_COVERAGE_HTML_DIR=rust-coverage-html run bash "$SCRIPT"
	assert_success
	assert_file_exists rust-coverage-html/index.html
	run test ! -d rust-coverage-html/html
	assert_success
	run grep -q 'rust coverage' rust-coverage-html/index.html
	assert_success
}

@test "run-rust-coverage-html: fails when cargo-llvm-cov is missing" {
	local bash_dir
	bash_dir="$(dirname "$(command -v bash)")"

	run env PATH="${bash_dir}" bash "$SCRIPT"
	assert_failure
	assert_output --partial "cargo-llvm-cov is required"
}

@test "run-rust-coverage-html: fails when html directory is missing" {
	_install_fake_cargo_llvm_cov no-html

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "Expected"
}

@test "run-rust-coverage-html: rejects unsafe output directory" {
	_install_fake_cargo_llvm_cov

	run env RUST_COVERAGE_HTML_DIR=".." bash "$SCRIPT"
	assert_failure
	assert_output --partial "Unsafe RUST_COVERAGE_HTML_DIR"

	run env RUST_COVERAGE_HTML_DIR="/tmp/rust-coverage" bash "$SCRIPT"
	assert_failure
	assert_output --partial "repo-relative"
}
