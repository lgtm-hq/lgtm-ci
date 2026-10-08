#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Entry-point tests for scripts/ci/catalog/check-deprecations.sh (#1082).
#
# The gate, scan and report logic is covered by
# tests/python/catalog/test_governance.py; these cases pin what the wrapper
# itself decides: the default subcommand, the default base ref inside and
# outside GitHub Actions, and argument pass-through.

load "../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/catalog/check-deprecations.sh"

setup() {
	# A stand-in interpreter that prints the arguments it was given.
	FAKE_PY="${BATS_TEST_TMPDIR}/fake-python"
	cat >"${FAKE_PY}" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@"
SH
	chmod +x "${FAKE_PY}"
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
