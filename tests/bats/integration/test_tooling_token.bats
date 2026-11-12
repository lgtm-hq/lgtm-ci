#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the optional tooling token (#1451)
#
# The rules themselves are unit-tested in tests/python/test_validate_tooling_token.py;
# this file covers the shell entry point and the real tree.

load "../../helpers/common"

VALIDATOR="${PROJECT_ROOT}/scripts/ci/quality/validate-tooling-token.sh"
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
}

run_fixture() {
	WORKFLOWS_DIR="${FIXTURE_WORKFLOWS}" ACTIONS_DIR="${FIXTURE_ACTIONS}" \
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
	refute_output --partial "allowlisted"
}

@test "validate-tooling-token: the pilot is converted" {
	run grep -cF 'token: ${{ secrets.LGTM_CI_TOOLING_TOKEN || github.token }}' "${PILOT}"
	assert_output "1"
	run grep -cF 'tooling-token: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}' "${PILOT}"
	assert_output "1"
}

@test "validate-tooling-token: every reusable that checks out tooling names the secret" {
	cd "${PROJECT_ROOT}/.github/workflows"
	run bash -c "grep -lE 'path: \\.lgtm-ci-tooling|actions/checkout-and-harden' reusable-*.yml |
		grep -vFxf <(grep -l 'LGTM_CI_TOOLING_TOKEN' reusable-*.yml)"
	assert_output ""
}

@test "validate-tooling-token: no allowlist or baseline is left" {
	run grep -nE 'ALLOWLIST|--allowlist|--baseline' \
		"${VALIDATOR}" "${PROJECT_ROOT}/scripts/ci/quality/validate_tooling_token.py"
	assert_failure 1
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
	assert_output "OK: tooling token contract satisfied (1 converted)"
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

@test "validate-tooling-token: fails when the workflows directory is missing" {
	write_fixture
	FIXTURE_WORKFLOWS="${BATS_TEST_TMPDIR}/absent"
	run_fixture
	assert_failure 2
	assert_output --partial "workflows directory not found"
}

# Append one step to the converted fixture's job.
add_step() {
	printf '%s\n' "$@" >>"${FIXTURE_WORKFLOWS}/reusable-converted.yml"
}

@test "validate-tooling-token: a quote or a closing brace does not hide a secrets read" {
	write_fixture
	add_step '      - run: echo leak' '        env:' \
		"          T: \${{ format('}}{0}', toJSON(secrets)) }}"
	run_fixture
	assert_failure 1
	assert_output --partial "reusable-converted.yml:24: [leak] the expression reads the secrets context as a whole or by index"
}

@test "validate-tooling-token: an unconverted reusable may not misuse the token" {
	write_fixture
	cat >"${FIXTURE_WORKFLOWS}/reusable-old.yml" <<'YAML'
---
name: Unconverted
on:
  workflow_call:
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          path: .lgtm-ci-tooling
          token: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}
          persist-credentials: true
YAML
	run_fixture
	assert_failure 1
	assert_output --partial "reusable-old.yml:9: [declaration] uses the tooling token but does not declare"
	assert_output --partial "reusable-old.yml:12: [token] \`token\` must be exactly"
	assert_output --partial "reusable-old.yml:13: [token] \`persist-credentials\` must be exactly \`false\`, found \`true\`"
}

@test "validate-tooling-token: the secret does not go to a composite of another repository" {
	write_fixture
	add_step '      - uses: evil/repo/.github/actions/checkout-and-harden@main' \
		'        with:' '          tooling-token: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}'
	run_fixture
	assert_failure 1
	assert_output --partial "reusable-converted.yml:22: [unclassified] \`uses: evil/repo/.github/actions/checkout-and-harden@main\` names checkout-and-harden but is not"
	assert_output --partial "reusable-converted.yml:24: [leak] LGTM_CI_TOOLING_TOKEN may only be declared"
}

@test "validate-tooling-token: the secret does not go to a remote reusable workflow" {
	write_fixture
	cat >"${FIXTURE_WORKFLOWS}/reusable-wrapper.yml" <<'YAML'
---
name: Wrapper
on:
  workflow_call:
    secrets:
      LGTM_CI_TOOLING_TOKEN:
        required: false
jobs:
  inner:
    uses: evil/repo/.github/workflows/reusable-converted.yml@main
    secrets:
      LGTM_CI_TOOLING_TOKEN: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}
YAML
	run_fixture
	assert_failure 1
	assert_output --partial "reusable-wrapper.yml:12: [leak] forwards LGTM_CI_TOOLING_TOKEN to \`evil/repo/.github/workflows/reusable-converted.yml@main\`"
}

@test "validate-tooling-token: another composite may not check out the tooling" {
	write_fixture
	mkdir -p "${FIXTURE_ACTIONS}/stage"
	cat >"${FIXTURE_ACTIONS}/stage/action.yaml" <<'YAML'
---
name: Stage
runs:
  using: composite
  steps:
    - uses: actions/checkout@v4
      with: {path: .lgtm-ci-tooling, token: "${{ inputs.token }}"}
YAML
	run_fixture
	assert_failure 1
	assert_output --partial "stage/action.yaml:6: [composite] \`uses: actions/checkout@v4\` has \`path: .lgtm-ci-tooling\`; only checkout-and-harden may check out the tooling"
}

@test "validate-tooling-token: an unparseable workflow fails whatever its name" {
	write_fixture
	printf '[\n' >"${FIXTURE_WORKFLOWS}/callable.yml"
	run_fixture
	assert_failure 1
	assert_output --partial "callable.yml:2: [yaml] not valid YAML"
}

@test "validate-tooling-token: an empty reusable fails" {
	write_fixture
	: >"${FIXTURE_WORKFLOWS}/reusable-empty.yml"
	run_fixture
	assert_failure 1
	assert_output --partial "reusable-empty.yml:1: [yaml] the file is empty"
}

@test "validate-tooling-token: deeply nested YAML is a parse error, not a traceback" {
	write_fixture
	printf '[%.0s' $(seq 1 50000) >"${FIXTURE_WORKFLOWS}/callable.yml"
	run_fixture
	assert_failure 1
	assert_output --partial "callable.yml:1: [yaml] not valid YAML: nested too deeply to be parsed"
	refute_output --partial "Traceback"
}

@test "validate-tooling-token: an unclassified caller checkout is reported once" {
	write_fixture
	cat >"${FIXTURE_WORKFLOWS}/reusable-caller.yml" <<'YAML'
---
name: Caller checkout
on:
  workflow_call:
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          path: ${{ inputs.working-directory }}
YAML
	run_fixture
	assert_failure 1
	assert_output --partial "reusable-caller.yml:11: [unclassified] checkout \`path: \${{ inputs.working-directory }}\` cannot be told apart"
	refute_output --partial "[declaration]"
}
