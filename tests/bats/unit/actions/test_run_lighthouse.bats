#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/run-lighthouse.sh package-manager
#          dispatch (#1077): @lhci/cli is a prerequisite (on PATH or in the
#          project tree), nothing is installed, bun is never implied.

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/run-lighthouse.sh"

setup() {
	setup_temp_dir
	save_path
	export WORK_DIR="${BATS_TEST_TMPDIR}/work"
	mkdir -p "$WORK_DIR"
	cd "$WORK_DIR"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
	mock_command_record bun
	mock_command_record npm
	mock_command_record npx
	mock_command_record pnpm
}

teardown() {
	restore_path
	teardown_temp_dir
}

_calls() {
	cat "${BATS_TEST_TMPDIR}/mock_calls_$1"
}

@test "run-lighthouse setup: empty PACKAGE_MANAGER fails with the required-input message" {
	run env STEP=setup PACKAGE_MANAGER="" bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "package-manager is required for execution actions"
	assert_equal "" "$(_calls bun)$(_calls npm)$(_calls npx)$(_calls pnpm)"
}

@test "run-lighthouse setup npm: missing @lhci/cli fails with an actionable message, no install" {
	mock_command_record npm '{"name":"fixture","dependencies":{}}' 1
	run env STEP=setup PACKAGE_MANAGER=npm bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "@lhci/cli is not installed"
	assert_output --partial "install @lhci/cli as a devDependency"
	assert_equal "ls --json --depth=0 @lhci/cli" "$(_calls npm)"
	assert_equal "" "$(_calls bun)"
	assert_equal "" "$(_calls npx)"
}

@test "run-lighthouse setup npm: project-installed @lhci/cli is reported through npx --no-install" {
	mock_command_record npm '{"name":"fixture","dependencies":{"@lhci/cli":{"version":"0.14.0"}}}'
	mock_command_record npx "0.14.0"
	run env STEP=setup PACKAGE_MANAGER=npm bash "$SCRIPT"
	assert_success
	assert_output --partial "Lighthouse CI available: 0.14.0"
	assert_equal "--no-install lhci --version" "$(_calls npx)"
}

@test "run-lighthouse setup: lhci already on PATH skips the package lookup" {
	mock_command_record lhci "0.14.0"
	run env STEP=setup PACKAGE_MANAGER=pnpm bash "$SCRIPT"
	assert_success
	assert_output --partial "Lighthouse CI available: 0.14.0"
	assert_equal "--version" "$(_calls lhci)"
	assert_equal "" "$(_calls pnpm)"
}

@test "run-lighthouse run pnpm: executes pnpm exec lhci autorun with the filesystem target" {
	run env STEP=run PACKAGE_MANAGER=pnpm URL=http://localhost:3000 OUTPUT_DIR="${WORK_DIR}/out" bash "$SCRIPT"
	assert_success
	run _calls pnpm
	assert_output --partial "exec lhci autorun --upload.target=filesystem --upload.outputDir=${WORK_DIR}/out"
	assert_output --partial "--collect.url=http://localhost:3000"
	assert_equal "" "$(_calls bun)"
}

@test "run-lighthouse run: lhci on PATH is preferred over the package manager" {
	mock_command_record lhci
	run env STEP=run PACKAGE_MANAGER=npm URL=http://localhost:3000 OUTPUT_DIR="${WORK_DIR}/out" bash "$SCRIPT"
	assert_success
	run _calls lhci
	assert_output --partial "autorun"
	assert_equal "" "$(_calls npx)"
}

@test "run-lighthouse run: empty PACKAGE_MANAGER fails before running anything" {
	run env STEP=run PACKAGE_MANAGER="" URL=http://localhost:3000 bash "$SCRIPT"
	assert_failure 2
	assert_equal "" "$(_calls bun)$(_calls npx)$(_calls pnpm)"
}

@test "run-lighthouse: no hard-coded bun, bunx, npx or pnpm invocation remains in the script" {
	run grep -nE '^\s*(bun|bunx|npx|pnpm) ' "$SCRIPT"
	assert_failure
	refute_output
}
