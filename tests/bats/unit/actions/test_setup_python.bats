#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/setup-python.sh STEP=deps (#1021):
#          every install goes through `uv sync --frozen` so a cold cache never
#          re-resolves the lockfile and fetches git sources of groups the job
#          does not install.

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/setup-python.sh"

setup() {
	setup_temp_dir
	save_path
	export WORK_DIR="${BATS_TEST_TMPDIR}/work"
	mkdir -p "$WORK_DIR"
	unset EXTRAS
	mock_command_record uv
}

teardown() {
	restore_path
	teardown_temp_dir
}

_uv_calls() {
	cat "${BATS_TEST_TMPDIR}/mock_calls_uv"
}

_run_deps() {
	run bash -c "cd '$WORK_DIR' && STEP=deps bash '$SCRIPT'"
}

@test "setup-python deps: lockfile present installs with uv sync --frozen" {
	touch "$WORK_DIR/pyproject.toml" "$WORK_DIR/uv.lock"

	_run_deps
	assert_success
	assert_output --partial "uv sync --frozen"
	run _uv_calls
	assert_line --index 0 "sync --frozen"
	refute_line "lock"
}

@test "setup-python deps: extras compose as --frozen --extra <name> per extra" {
	touch "$WORK_DIR/pyproject.toml" "$WORK_DIR/uv.lock"
	export EXTRAS="dev, full,,"

	_run_deps
	assert_success
	run _uv_calls
	assert_line --index 0 "sync --frozen --extra dev --extra full"
}

@test "setup-python deps: never calls uv sync without --frozen" {
	touch "$WORK_DIR/pyproject.toml" "$WORK_DIR/uv.lock"
	export EXTRAS="dev"

	_run_deps
	assert_success
	run grep -E '^sync( |$)' "${BATS_TEST_TMPDIR}/mock_calls_uv"
	assert_success
	run grep -E '^sync( |$)' "${BATS_TEST_TMPDIR}/mock_calls_uv"
	refute_output --regexp '^sync( (--extra [^ ]+))*$'
	run grep -vE '^sync --frozen' "${BATS_TEST_TMPDIR}/mock_calls_uv"
	assert_output ""
}

@test "setup-python deps: missing uv.lock resolves once then installs frozen" {
	touch "$WORK_DIR/pyproject.toml"

	_run_deps
	assert_success
	assert_output --partial "::warning title=uv.lock missing::"
	run _uv_calls
	assert_line --index 0 "lock"
	assert_line --index 1 "sync --frozen"
}

@test "setup-python deps: requirements.txt path uses uv pip install" {
	touch "$WORK_DIR/requirements.txt"

	_run_deps
	assert_success
	assert_output --partial "Installing from requirements.txt"
	run _uv_calls
	assert_line --index 0 "pip install -r requirements.txt"
	refute_line --partial "sync"
}

@test "setup-python deps: no dependency file skips install" {
	_run_deps
	assert_success
	assert_output --partial "No dependency file found"
	run _uv_calls
	assert_output ""
}
