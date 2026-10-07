#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/run-pytest.sh setup/run steps (#1021):
#          every project-scoped uv invocation after the frozen install is
#          `uv run --frozen`, so no step re-locks the project and fetches
#          git sources of groups the job never installed.

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/run-pytest.sh"

setup() {
	setup_temp_dir
	save_path
	export WORK_DIR="${BATS_TEST_TMPDIR}/work"
	mkdir -p "$WORK_DIR"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
	unset TEST_PATH COVERAGE COVERAGE_FORMAT COVERAGE_SOURCE MARKERS EXTRA_ARGS
	export WORKING_DIRECTORY="$WORK_DIR"
	mock_command_record uv
}

teardown() {
	restore_path
	teardown_temp_dir
}

_uv_calls() {
	cat "${BATS_TEST_TMPDIR}/mock_calls_uv"
}

# uv mock that records calls and fails only for `uv run ...` (missing
# plugin / failing pytest); `uv pip install` still succeeds.
_mock_uv_run_fails() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	local calls_file="${BATS_TEST_TMPDIR}/mock_calls_uv"
	: >"$calls_file"
	cat >"${mock_bin}/uv" <<EOF
#!/usr/bin/env bash
echo "\$@" >>'${calls_file}'
[[ "\$1" == "run" ]] && exit 1
exit 0
EOF
	chmod +x "${mock_bin}/uv"
}

@test "run-pytest setup: probes with uv run --frozen and never a plain uv run" {
	run bash -c "STEP=setup COVERAGE=true bash '$SCRIPT'"
	assert_success
	run _uv_calls
	assert_line --index 0 "run --frozen python -c import pytest; import pytest_jsonreport"
	assert_line --index 1 "run --frozen python -c import pytest_cov"
	run grep -E '^run ' "${BATS_TEST_TMPDIR}/mock_calls_uv"
	refute_output --regexp '^run (python|pytest)'
}

@test "run-pytest setup: installs missing plugins with uv pip, still no plain uv run" {
	# uv exits 1 for the import probes, so both installs happen.
	_mock_uv_run_fails
	run bash -c "STEP=setup COVERAGE=true bash '$SCRIPT'"
	assert_success
	run _uv_calls
	assert_line --index 0 "run --frozen python -c import pytest; import pytest_jsonreport"
	assert_line --index 1 "pip install pytest pytest-json-report"
	assert_line --index 2 "run --frozen python -c import pytest_cov"
	assert_line --index 3 "pip install pytest-cov"
}

@test "run-pytest run: executes pytest through uv run --frozen" {
	run bash -c "STEP=run TEST_PATH=tests bash '$SCRIPT'"
	assert_success
	run _uv_calls
	assert_line --index 0 --partial "run --frozen pytest tests --json-report --json-report-file=pytest-results.json"
	run grep "^exit-code=" "$GITHUB_OUTPUT"
	assert_output "exit-code=0"
}

@test "run-pytest run: coverage and markers compose after --frozen" {
	run bash -c "STEP=run TEST_PATH=tests COVERAGE=true COVERAGE_FORMAT=xml MARKERS='not slow' bash '$SCRIPT'"
	assert_success
	run _uv_calls
	assert_line --index 0 --partial "run --frozen pytest tests"
	assert_line --index 0 --partial "--cov --cov-report=term --cov-report=xml:coverage.xml -m not slow"
}

@test "run-pytest run: pytest failure is recorded as exit-code and propagated" {
	# The workflow runs this step with continue-on-error and reads
	# exit-code from the outputs; the script itself exits with pytest's code.
	_mock_uv_run_fails
	run bash -c "STEP=run TEST_PATH=tests bash '$SCRIPT'"
	assert_failure 1
	run grep "^exit-code=" "$GITHUB_OUTPUT"
	assert_output "exit-code=1"
}
