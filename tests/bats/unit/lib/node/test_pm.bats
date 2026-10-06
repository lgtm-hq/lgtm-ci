#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/lib/node/pm.sh (#1077)
#
# Each helper is exercised per manager against recording mocks of bun, npm,
# npx and pnpm, so the assertions are on the exact command the helper emits.
# Nothing here touches a real package manager.

bats_require_minimum_version 1.5.0

load "../../../../helpers/common"
load "../../../../helpers/mocks"

PM_LIB="${PROJECT_ROOT}/scripts/ci/lib/node/pm.sh"

setup() {
	setup_temp_dir
	save_path
	mock_command_record bun
	mock_command_record npm
	mock_command_record npx
	mock_command_record pnpm
}

teardown() {
	restore_path
	teardown_temp_dir
}

# Run one helper under a given manager; args are passed verbatim. `-e` and
# `pipefail` match the runner scripts, so a listing command's exit status
# leaking through a pipe shows up here, not in CI.
#
# No `-u` here: kcov instruments nested bash through a BASH_ENV preamble that
# enables `set -x` with `PS4='kcov@${BASH_SOURCE}…'`, and BASH_SOURCE is unset
# in a `bash -c` child, so every traced line would abort with "unbound
# variable" under `-u`. The runner scripts (test_run_*.bats) source pm.sh as
# files under the full `set -euo pipefail`, which covers the `-u` contract;
# keeping BASH_ENV here keeps this file's coverage of pm.sh.
_pm() {
	local manager="$1"
	shift
	PACKAGE_MANAGER="$manager" \
		bash -c 'set -eo pipefail; source "$1"; shift; "$@"' _ "$PM_LIB" "$@"
}

_calls() {
	cat "${BATS_TEST_TMPDIR}/mock_calls_$1"
}

# =============================================================================
# pm_require: contract on PACKAGE_MANAGER
# =============================================================================

@test "pm_require: empty manager fails with the required-input message and exit 2" {
	run _pm "" pm_require
	assert_failure 2
	assert_output --partial "package-manager is required for execution actions"
}

@test "pm_require: unknown manager is named and rejected with exit 2" {
	run _pm yarn pm_require
	assert_failure 2
	assert_output --partial "Unsupported package manager: yarn"
	assert_output --partial "bun, npm, pnpm"
}

@test "pm_require: each supported manager echoes its name" {
	local manager
	for manager in bun npm pnpm; do
		run _pm "$manager" pm_require
		assert_success
		assert_output "$manager"
	done
}

@test "pm_require: unknown manager does not invoke any tool" {
	run _pm yarn pm_run test
	assert_failure 2
	assert_equal "$(_calls bun)$(_calls npm)$(_calls npx)$(_calls pnpm)" ""
}

# =============================================================================
# pm_run
# =============================================================================

@test "pm_run bun: bun run <script> with args" {
	run _pm bun pm_run test --watch=false
	assert_success
	assert_equal "$(_calls bun)" "run test --watch=false"
}

@test "pm_run npm: npm run <script> -- args" {
	run _pm npm pm_run test --watch=false
	assert_success
	assert_equal "$(_calls npm)" "run test -- --watch=false"
}

@test "pm_run pnpm: pnpm run <script> with args" {
	run _pm pnpm pm_run test --watch=false
	assert_success
	assert_equal "$(_calls pnpm)" "run test --watch=false"
}

@test "pm_run: script name is required" {
	run -1 _pm npm pm_run
	assert_output --partial "script name required"
}

# =============================================================================
# pm_exec
# =============================================================================

@test "pm_exec bun: bun x --no-install <bin> (never bun run, which prefers a same-named script)" {
	run _pm bun pm_exec vitest run --reporter=json
	assert_success
	assert_equal "$(_calls bun)" "x --no-install vitest run --reporter=json"
}

@test "pm_exec npm: npx --no-install <bin>" {
	run _pm npm pm_exec vitest run --reporter=json
	assert_success
	assert_equal "$(_calls npx)" "--no-install vitest run --reporter=json"
	assert_equal "$(_calls npm)" ""
}

@test "pm_exec pnpm: pnpm exec <bin>" {
	run _pm pnpm pm_exec playwright install --with-deps chromium
	assert_success
	assert_equal "$(_calls pnpm)" "exec playwright install --with-deps chromium"
}

@test "pm_exec npm: never touches bun" {
	run _pm npm pm_exec vitest run
	assert_success
	assert_equal "$(_calls bun)" ""
}

@test "pm_exec: propagates the binary's exit code" {
	mock_command_record npx "" 7
	run _pm npm pm_exec vitest run
	assert_failure 7
}

# =============================================================================
# pm_add_dev
# =============================================================================

@test "pm_add_dev bun: bun add -d" {
	run _pm bun pm_add_dev vitest @vitest/coverage-v8
	assert_success
	assert_equal "$(_calls bun)" "add -d vitest @vitest/coverage-v8"
}

@test "pm_add_dev npm: npm install --save-dev" {
	run _pm npm pm_add_dev vitest
	assert_success
	assert_equal "$(_calls npm)" "install --save-dev vitest"
}

@test "pm_add_dev pnpm: pnpm add -D" {
	run _pm pnpm pm_add_dev vitest
	assert_success
	assert_equal "$(_calls pnpm)" "add -D vitest"
}

@test "pm_add_dev: at least one package is required" {
	run _pm npm pm_add_dev
	assert_failure 2
	assert_output --partial "at least one package required"
	assert_equal "$(_calls npm)" ""
}

# =============================================================================
# pm_has
# =============================================================================

@test "pm_has bun: present in bun pm ls" {
	mock_command_record bun "$(printf '%s\n' '/tmp/node_modules (2)' '├── @vitest/coverage-v8@3.2.4' '└── vitest@3.2.4')"
	run _pm bun pm_has vitest
	assert_success
	assert_equal "$(_calls bun)" "pm ls"
}

@test "pm_has bun: absent from bun pm ls" {
	mock_command_record bun "$(printf '%s\n' '/tmp/node_modules (1)' '└── @vitest/coverage-v8@3.2.4')"
	run _pm bun pm_has vitest
	assert_failure 1
}

@test "pm_has bun: scoped package matches whole name" {
	mock_command_record bun "$(printf '%s\n' '/tmp/node_modules (1)' '└── @playwright/test@1.49.1')"
	run _pm bun pm_has @playwright/test
	assert_success
	run _pm bun pm_has playwright
	assert_failure 1
}

@test "pm_has npm: present in npm ls --json" {
	mock_command_record npm '{"name":"fixture","dependencies":{"vitest":{"version":"3.2.4"}}}'
	run _pm npm pm_has vitest
	assert_success
	assert_equal "$(_calls npm)" "ls --json --depth=0 vitest"
}

@test "pm_has npm: absent from npm ls --json even when npm exits non-zero" {
	mock_command_record npm '{"name":"fixture","dependencies":{}}' 1
	run _pm npm pm_has vitest
	assert_failure 1
}

@test "pm_has npm: present survives a non-zero npm exit for unrelated tree problems" {
	mock_command_record npm '{"name":"fixture","problems":["extraneous: x"],"dependencies":{"vitest":{"version":"3.2.4"}}}' 1
	run _pm npm pm_has vitest
	assert_success
}

@test "pm_has pnpm: present as a devDependency in pnpm ls --json" {
	mock_command_record pnpm '[{"name":"fixture","devDependencies":{"@playwright/test":{"version":"1.49.1"}}}]'
	run _pm pnpm pm_has @playwright/test
	assert_success
	assert_equal "$(_calls pnpm)" "ls --json --depth 0 @playwright/test"
}

@test "pm_has pnpm: present as a dependency in pnpm ls --json" {
	mock_command_record pnpm '[{"name":"fixture","dependencies":{"vitest":{"version":"3.2.4"}}}]'
	run _pm pnpm pm_has vitest
	assert_success
}

@test "pm_has pnpm: present survives a non-zero pnpm exit under pipefail" {
	mock_command_record pnpm '[{"name":"fixture","devDependencies":{"vitest":{"version":"3.2.4"}}}]' 1
	run _pm pnpm pm_has vitest
	assert_success
}

@test "pm_has bun: present survives a non-zero bun exit under pipefail" {
	mock_command_record bun "$(printf '%s\n' '/tmp/node_modules (1)' '└── vitest@3.2.4')" 1
	run _pm bun pm_has vitest
	assert_success
}

@test "pm_has pnpm: absent from pnpm ls --json" {
	mock_command_record pnpm '[{"name":"fixture"}]'
	run _pm pnpm pm_has vitest
	assert_failure 1
}

@test "pm_has npm: an npm that prints nothing and fails reports absent, not present" {
	mock_command_record npm "" 1
	run _pm npm pm_has vitest
	assert_failure
}

@test "pm_has npm: malformed npm output reports absent" {
	mock_command_record npm "npm ERR! something broke" 1
	run _pm npm pm_has vitest
	assert_failure
}

@test "pm_has pnpm: a pnpm that prints nothing and fails reports absent" {
	mock_command_record pnpm "" 1
	run _pm pnpm pm_has vitest
	assert_failure
}

@test "pm_has bun: a bun that prints nothing and fails reports absent" {
	mock_command_record bun "" 1
	run _pm bun pm_has vitest
	assert_failure
}

@test "pm_has: empty manager fails with exit 2 before any lookup" {
	run _pm "" pm_has vitest
	assert_failure 2
	assert_output --partial "package-manager is required"
}

# =============================================================================
# Loading
# =============================================================================

@test "pm.sh: sourcing twice is a no-op" {
	run bash -c "source '$PM_LIB' && source '$PM_LIB' && declare -f pm_has >/dev/null && echo ok"
	assert_success
	assert_output "ok"
}

@test "pm.sh: never consults lockfiles to pick a manager" {
	run grep -nE 'bun\.lock|package-lock|pnpm-lock' "$PM_LIB"
	assert_failure
	refute_output
}
