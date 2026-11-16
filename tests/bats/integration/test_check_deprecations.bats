#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Entry-point tests for scripts/ci/catalog/check-deprecations.sh (#1082).
#
# The gate, scan and report logic is covered by
# tests/python/catalog/test_governance.py; these cases pin what the wrapper
# itself decides: the default subcommand, the default base ref inside and
# outside GitHub Actions, and argument pass-through.

load "../../helpers/common"
load "../../helpers/fake_python"

SCRIPT="${PROJECT_ROOT}/scripts/ci/catalog/check-deprecations.sh"

setup() {
	# A stand-in interpreter that prints the arguments it was given.
	FAKE_PY="${BATS_TEST_TMPDIR}/fake-python"
	write_fake_python "${FAKE_PY}" 'printf "%s\n" "$@"'
	export PYTHON="${FAKE_PY}"
	unset DEPRECATION_BASE_REF
}

@test "check-deprecations: no arguments run the gate against origin/main locally" {
	GITHUB_ACTIONS="" run bash "${SCRIPT}"
	assert_success
	assert_line --index 0 --partial "scripts/ci/catalog/deprecations.py"
	assert_line --index 1 "gate"
	assert_line --index 2 "--base-ref"
	assert_line --index 3 "origin/main"
}

@test "check-deprecations: in GitHub Actions the base is the first parent" {
	GITHUB_ACTIONS=true run bash "${SCRIPT}"
	assert_success
	assert_line --index 3 "HEAD^1"
}

@test "check-deprecations: DEPRECATION_BASE_REF overrides the default base" {
	GITHUB_ACTIONS=true DEPRECATION_BASE_REF=release/x run bash "${SCRIPT}"
	assert_success
	assert_line --index 3 "release/x"
}

@test "check-deprecations: subcommands and flags pass through unchanged" {
	run bash "${SCRIPT}" scan --write --repository o/a
	assert_success
	assert_line --index 1 "scan"
	assert_line --index 2 "--write"
	assert_line --index 4 "o/a"
}

@test "check-deprecations: Python older than 3.11 stops with one ::error:: line (#1428)" {
	write_fake_python "${FAKE_PY}" 'echo "gate ran"' 3.10.12
	run bash "${SCRIPT}" report
	assert_failure 69
	assert_output --regexp '^::error::Python 3\.10\.12 at .* is too old'
	refute_output --partial "gate ran"
}

@test "check-deprecations: a missing interpreter stops with one ::error:: line (#1428)" {
	PYTHON=/nonexistent/python3 run bash "${SCRIPT}" report
	assert_failure 69
	assert_equal "${#lines[@]}" 1
	assert_output --regexp '^::error::PYTHON=/nonexistent/python3 is not an executable file'
}
