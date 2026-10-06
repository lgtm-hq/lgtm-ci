#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/run-vitest.sh package-manager dispatch
#          (#1077): the runner follows PACKAGE_MANAGER, never installs test
#          tooling, and never reaches for bun when another manager is selected.

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/run-vitest.sh"

setup() {
	setup_temp_dir
	save_path
	export WORK_DIR="${BATS_TEST_TMPDIR}/work"
	mkdir -p "$WORK_DIR"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
	# The CI bats job exports TEST_PATH / COVERAGE for its own run; the
	# runner reads the same names, so start every test from clean defaults.
	unset TEST_PATH COVERAGE COVERAGE_FORMAT EXTRA_ARGS PACKAGE_MANAGER
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

_github_output_value() {
	grep "^$1=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-
}

# =============================================================================
# setup: tooling is a prerequisite, never installed
# =============================================================================

@test "run-vitest setup: empty PACKAGE_MANAGER fails with the required-input message" {
	run env STEP=setup PACKAGE_MANAGER="" WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "package-manager is required for execution actions"
	assert_equal "$(_calls bun)$(_calls npm)$(_calls npx)$(_calls pnpm)" ""
}

@test "run-vitest setup: unset PACKAGE_MANAGER fails the same way" {
	run env -u PACKAGE_MANAGER STEP=setup WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "package-manager is required for execution actions"
}

@test "run-vitest setup: unsupported manager is rejected" {
	run env STEP=setup PACKAGE_MANAGER=yarn WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "Unsupported package manager: yarn"
}

@test "run-vitest setup npm: missing vitest fails with an actionable message, no install" {
	mock_command_record npm '{"name":"fixture","dependencies":{}}' 1
	run env STEP=setup PACKAGE_MANAGER=npm WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "vitest is not installed"
	assert_output --partial "install vitest as a devDependency"
	assert_output --partial "npm lockfile"
	assert_equal "$(_calls npm)" "ls --json --depth=0 vitest"
	assert_equal "$(_calls bun)" ""
	assert_equal "$(_calls npx)" ""
}

@test "run-vitest setup npm: vitest present passes without touching bun" {
	mock_command_record npm '{"name":"fixture","dependencies":{"vitest":{"version":"3.2.4"}}}'
	run env STEP=setup PACKAGE_MANAGER=npm WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_output --partial "vitest setup complete"
	assert_equal "$(_calls bun)" ""
	refute_output --partial "bun"
}

@test "run-vitest setup npm: coverage=true without a provider fails naming @vitest/coverage-v8" {
	cat >"${BATS_TEST_TMPDIR}/bin/npm" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${MOCK_CALLS}"
case "$*" in
*" vitest") echo '{"dependencies":{"vitest":{"version":"3.2.4"}}}' ;;
*) echo '{"dependencies":{}}' ;;
esac
EOF
	export MOCK_CALLS="${BATS_TEST_TMPDIR}/mock_calls_npm"
	run env STEP=setup PACKAGE_MANAGER=npm COVERAGE=true WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "coverage=true needs a vitest coverage provider"
	assert_output --partial "@vitest/coverage-v8"
	# Both providers were consulted, nothing was added.
	run _calls npm
	assert_line --index 1 "ls --json --depth=0 @vitest/coverage-v8"
	assert_line --index 2 "ls --json --depth=0 @vitest/coverage-istanbul"
	refute_output --partial "install"
}

@test "run-vitest setup npm: coverage=true accepts the istanbul provider" {
	cat >"${BATS_TEST_TMPDIR}/bin/npm" <<'EOF'
#!/usr/bin/env bash
case "$*" in
*" vitest") echo '{"dependencies":{"vitest":{}}}' ;;
*" @vitest/coverage-istanbul") echo '{"dependencies":{"@vitest/coverage-istanbul":{}}}' ;;
*) echo '{"dependencies":{}}' ;;
esac
EOF
	run env STEP=setup PACKAGE_MANAGER=npm COVERAGE=true WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
}

@test "run-vitest setup bun: missing vitest fails without bun install or bun add" {
	mock_command_record bun "$(printf '%s\n' '/tmp/node_modules (0)')"
	run env STEP=setup PACKAGE_MANAGER=bun WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "install vitest as a devDependency"
	assert_equal "$(_calls bun)" "pm ls"
}

@test "run-vitest setup pnpm: vitest present passes" {
	mock_command_record pnpm '[{"name":"fixture","devDependencies":{"vitest":{"version":"3.2.4"}}}]'
	run env STEP=setup PACKAGE_MANAGER=pnpm WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_equal "$(_calls pnpm)" "ls --json --depth 0 vitest"
	assert_equal "$(_calls bun)" ""
}

@test "run-vitest: no hard-coded bun, bunx, npx or pnpm invocation remains in the script" {
	run grep -nE '^\s*(bun|bunx|npx|pnpm) ' "$SCRIPT"
	assert_failure
	refute_output
}

# =============================================================================
# run: dispatch follows PACKAGE_MANAGER
# =============================================================================

@test "run-vitest run npm: executes npx --no-install vitest and records outputs" {
	run env STEP=run PACKAGE_MANAGER=npm WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_equal "$(_calls npx)" "--no-install vitest run --reporter=json --outputFile=vitest-results.json"
	assert_equal "$(_calls bun)" ""
	assert_equal "$(_github_output_value exit-code)" "0"
}

@test "run-vitest run npm: generated command contains no bun token" {
	run env STEP=run PACKAGE_MANAGER=npm COVERAGE=true COVERAGE_FORMAT=lcov \
		EXTRA_ARGS="--bail 1" WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	run _calls npx
	refute_output --partial "bun"
	assert_output --partial "--coverage.reporter=lcov"
	assert_output --partial "--bail 1"
}

@test "run-vitest run bun: executes bun run vitest" {
	run env STEP=run PACKAGE_MANAGER=bun WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_equal "$(_calls bun)" "run vitest run --reporter=json --outputFile=vitest-results.json"
	assert_equal "$(_calls npx)" ""
}

@test "run-vitest run pnpm: executes pnpm exec vitest" {
	run env STEP=run PACKAGE_MANAGER=pnpm TEST_PATH=tests WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_success
	assert_equal "$(_calls pnpm)" "exec vitest run tests --reporter=json --outputFile=vitest-results.json"
}

@test "run-vitest run: empty PACKAGE_MANAGER fails before running anything" {
	run env STEP=run PACKAGE_MANAGER="" WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "package-manager is required"
	assert_equal "$(_calls bun)$(_calls npx)$(_calls pnpm)" ""
}

@test "run-vitest run: vitest exit code is propagated through exit-code output" {
	mock_command_record npx "" 1
	run env STEP=run PACKAGE_MANAGER=npm WORKING_DIRECTORY="$WORK_DIR" bash "$SCRIPT"
	assert_failure 1
	assert_equal "$(_github_output_value exit-code)" "1"
}

# =============================================================================
# parse / summary: unchanged, manager-free
# =============================================================================

@test "run-vitest parse: works without PACKAGE_MANAGER" {
	cat >"${WORK_DIR}/vitest-results.json" <<'EOF'
{"numTotalTests":3,"numPassedTests":2,"numFailedTests":1,"numPendingTests":0}
EOF
	run env -u PACKAGE_MANAGER STEP=parse RESULTS_FILE="${WORK_DIR}/vitest-results.json" \
		COVERAGE_FILE="${WORK_DIR}/none.json" bash "$SCRIPT"
	assert_success
	assert_equal "$(_github_output_value tests-total)" "3"
	assert_equal "$(_github_output_value tests-failed)" "1"
}
