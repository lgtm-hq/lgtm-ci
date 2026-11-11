#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the optional tooling token (#1451)
#
# The rules themselves are unit-tested in tests/python/test_validate_tooling_token.py;
# this file covers the shell entry point and the real tree.

load "../../helpers/common"

VALIDATOR="${PROJECT_ROOT}/scripts/ci/quality/validate-tooling-token.sh"
ALLOWLIST="${PROJECT_ROOT}/scripts/ci/quality/tooling-token-allowlist.txt"
ACTION="${PROJECT_ROOT}/.github/actions/checkout-and-harden/action.yml"
PILOT="${PROJECT_ROOT}/.github/workflows/reusable-semantic-pr-title.yml"
CALLER="${PROJECT_ROOT}/.github/workflows/semantic-pr-title.yml"

# The validator parses YAML; pick an interpreter that has PyYAML.
setup() {
	require_python_yaml
	export PYTHON="${PY}"
}

# Build a tree with a valid composite and one converted reusable.
write_fixture() {
	FIXTURE_WORKFLOWS="${BATS_TEST_TMPDIR}/.github/workflows"
	FIXTURE_ACTIONS="${BATS_TEST_TMPDIR}/.github/actions"
	FIXTURE_ALLOWLIST="${BATS_TEST_TMPDIR}/allowlist.txt"
	mkdir -p "${FIXTURE_WORKFLOWS}" "${FIXTURE_ACTIONS}/checkout-and-harden"
	cat >"${FIXTURE_ACTIONS}/checkout-and-harden/action.yml" <<'YAML'
---
name: Checkout and harden
inputs:
  tooling-token:
    required: false
    default: ""
runs:
  using: composite
  steps:
    - name: Checkout lgtm-ci tooling
      uses: actions/checkout@v4
      with:
        path: .lgtm-ci-tooling
        token: ${{ inputs.tooling-token || github.token }}
        persist-credentials: false
YAML
	cat >"${FIXTURE_WORKFLOWS}/reusable-converted.yml" <<'YAML'
---
name: Converted
on:
  workflow_call:
    secrets:
      LGTM_CI_TOOLING_TOKEN:
        required: false
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout lgtm-ci tooling
        uses: actions/checkout@v4
        with:
          path: .lgtm-ci-tooling
          token: ${{ secrets.LGTM_CI_TOOLING_TOKEN || github.token }}
          persist-credentials: false
      - name: Checkout and harden
        uses: ./.lgtm-ci-tooling/.github/actions/checkout-and-harden
        with:
          tooling-token: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}
YAML
	printf '# header\n' >"${FIXTURE_ALLOWLIST}"
}

# The fixture allowlist starts empty, so its ceiling is 0 unless a test says so.
run_fixture() {
	WORKFLOWS_DIR="${FIXTURE_WORKFLOWS}" ACTIONS_DIR="${FIXTURE_ACTIONS}" \
		ALLOWLIST_FILE="${FIXTURE_ALLOWLIST}" ALLOWLIST_CEILING="${FIXTURE_CEILING:-0}" \
		run "${VALIDATOR}"
}

# Add a reusable that checks out the tooling in flow style, without the token.
write_unconverted() {
	cat >"${FIXTURE_WORKFLOWS}/$1" <<'YAML'
---
name: Unconverted
on:
  workflow_call:
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: {path: .lgtm-ci-tooling, persist-credentials: true}
YAML
}

@test "validate-tooling-token: passes on the repository" {
	run "${VALIDATOR}"
	assert_success
	assert_output --partial "OK: tooling token contract satisfied"
}

@test "validate-tooling-token: the pilot is converted and off the allowlist" {
	run grep -Fx "reusable-semantic-pr-title.yml" "${ALLOWLIST}"
	assert_failure 1
	run grep -cF 'token: ${{ secrets.LGTM_CI_TOOLING_TOKEN || github.token }}' "${PILOT}"
	assert_output "1"
	run grep -cF 'tooling-token: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}' "${PILOT}"
	assert_output "1"
}

@test "validate-tooling-token: the allowlist is every other reusable that checks out tooling" {
	local expected
	expected="$(
		cd "${PROJECT_ROOT}/.github/workflows" &&
			grep -lE 'path: \.lgtm-ci-tooling|actions/checkout-and-harden' reusable-*.yml |
			grep -vFxf <(grep -l 'LGTM_CI_TOOLING_TOKEN' reusable-*.yml) | LC_ALL=C sort
	)"
	run grep -vE '^(#|$)' "${ALLOWLIST}"
	assert_success
	assert_output "${expected}"
}

@test "validate-tooling-token: the composite reads the token only in its checkout" {
	run grep -cF 'inputs.tooling-token' "${ACTION}"
	assert_output "1"
	run grep -F 'token: ${{ inputs.tooling-token || github.token }}' "${ACTION}"
	assert_success
	run grep -E '^        persist-credentials: false$' "${ACTION}"
	assert_success
}

@test "validate-tooling-token: lgtm-ci passes its job token to the pilot" {
	run grep -F 'LGTM_CI_TOOLING_TOKEN: ${{ github.token }}' "${CALLER}"
	assert_success
	run grep -F 'secrets: inherit' "${CALLER}"
	assert_failure 1
}

@test "validate-tooling-token: passes on a converted fixture" {
	write_fixture
	run_fixture
	assert_success
	assert_output "OK: tooling token contract satisfied (1 converted, 0 allowlisted)"
}

@test "validate-tooling-token: names file and line for a checkout without the token" {
	write_fixture
	grep -vF 'token: ${{ secrets.' "${FIXTURE_WORKFLOWS}/reusable-converted.yml" \
		>"${BATS_TEST_TMPDIR}/edited.yml"
	mv "${BATS_TEST_TMPDIR}/edited.yml" "${FIXTURE_WORKFLOWS}/reusable-converted.yml"
	run_fixture
	assert_failure 1
	assert_output --partial "reusable-converted.yml:13: [token] missing"
}

@test "validate-tooling-token: sees a flow-style checkout without the token" {
	write_fixture
	write_unconverted reusable-flow.yml
	run_fixture
	assert_failure 1
	assert_output --partial "reusable-flow.yml:9: [token] missing"
	assert_output --partial "reusable-flow.yml:10: [token] \`persist-credentials\` must be exactly \`false\`, found \`true\`"
}

@test "validate-tooling-token: checks a .yaml reusable and one named otherwise" {
	write_fixture
	write_unconverted reusable-flow.yaml
	write_unconverted called.yml
	run_fixture
	assert_failure 1
	assert_output --partial "reusable-flow.yaml:9: [token] missing"
	assert_output --partial "called.yml:9: [token] missing"
}

@test "validate-tooling-token: a new unconverted reusable cannot be added to the allowlist" {
	write_fixture
	write_unconverted reusable-old.yml
	printf 'reusable-old.yml\n' >>"${FIXTURE_ALLOWLIST}"
	FIXTURE_CEILING=1 run_fixture
	assert_success
	write_unconverted reusable-new.yml
	printf 'reusable-new.yml\nreusable-old.yml\n' >"${FIXTURE_ALLOWLIST}"
	FIXTURE_CEILING=1 run_fixture
	assert_failure 1
	assert_output --partial "allowlist.txt:1: [allowlist] 2 entries, above the ceiling of 1"
}

@test "validate-tooling-token: the ceiling cannot stay above the allowlist" {
	write_fixture
	FIXTURE_CEILING=1 run_fixture
	assert_failure 1
	assert_output --partial "allowlist.txt:1: [allowlist] 0 entries, below the ceiling of 1"
}

@test "validate-tooling-token: the committed ceiling is the committed allowlist length" {
	local count ceiling
	count="$(grep -cvE '^(#|$)' "${ALLOWLIST}")"
	ceiling="$(sed -n 's/^ALLOWLIST_CEILING = \([0-9][0-9]*\)$/\1/p' \
		"${PROJECT_ROOT}/scripts/ci/quality/validate_tooling_token.py")"
	[ -n "${ceiling}" ]
	[ "${count}" -eq "${ceiling}" ]
}

@test "validate-tooling-token: fails when an allowlisted reusable is already converted" {
	write_fixture
	printf 'reusable-converted.yml\n' >>"${FIXTURE_ALLOWLIST}"
	FIXTURE_CEILING=1 run_fixture
	assert_failure 1
	assert_output --partial "allowlist.txt:2: [allowlist] reusable-converted.yml is already converted"
}

@test "validate-tooling-token: fails when the allowlist names a missing file" {
	write_fixture
	printf 'reusable-gone.yml\n' >>"${FIXTURE_ALLOWLIST}"
	FIXTURE_CEILING=1 run_fixture
	assert_failure 1
	assert_output --partial "allowlist.txt:2: [allowlist] reusable-gone.yml does not exist"
}

@test "validate-tooling-token: fails when the workflows directory is missing" {
	write_fixture
	FIXTURE_WORKFLOWS="${BATS_TEST_TMPDIR}/absent"
	run_fixture
	assert_failure 2
	assert_output --partial "workflows directory not found"
}

@test "validate-tooling-token: fails when the allowlist is missing" {
	write_fixture
	rm "${FIXTURE_ALLOWLIST}"
	run_fixture
	assert_failure 2
	assert_output --partial "allowlist not found"
}
