#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for lgtm-ci tooling sparse-checkout paths

load "../../helpers/common"

VALIDATOR="${PROJECT_ROOT}/scripts/ci/quality/validate-tooling-sparse-checkout.sh"

@test "validate-tooling-sparse-checkout: passes on repository reusables" {
	run "${VALIDATOR}"
	assert_success
	assert_output --partial "OK:"
}

@test "validate-tooling-sparse-checkout: flags script composite without scripts/ci/" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	local actions_dir="${BATS_TEST_TMPDIR}/.github/actions/validate-action-pinning"
	mkdir -p "${workflows_dir}" "${actions_dir}"
	cat >"${actions_dir}/action.yml" <<'YAML'
---
name: Validate action pinning
runs:
  using: composite
  steps:
    - shell: bash
      run: $SCRIPTS_DIR/ci/actions/validate-action-pinning.sh
YAML
	cat >"${workflows_dir}/reusable-bad-sparse.yml" <<'YAML'
---
name: Bad sparse example
on:
  workflow_call:
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout lgtm-ci tooling
        uses: actions/checkout@v4
        with:
          sparse-checkout: |
            .github/actions/
      - name: Validate action pinning
        uses: ./.lgtm-ci-tooling/.github/actions/validate-action-pinning
YAML

	WORKFLOWS_DIR="${workflows_dir}" ACTIONS_DIR="${BATS_TEST_TMPDIR}/.github/actions" \
		run "${VALIDATOR}"
	assert_failure
	assert_output --partial "scripts/ci/"
}

@test "validate-tooling-sparse-checkout: allows egress-only tooling checkout" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	local actions_dir="${BATS_TEST_TMPDIR}/.github/actions"
	mkdir -p "${workflows_dir}" "${actions_dir}/harden-runner" "${actions_dir}/resolve-egress-allowlist"
	cat >"${actions_dir}/harden-runner/action.yml" <<'YAML'
---
name: Harden runner
runs:
  using: composite
  steps:
    - uses: step-security/harden-runner@v2
YAML
	cat >"${actions_dir}/resolve-egress-allowlist/action.yml" <<'YAML'
---
name: Resolve egress allowlist
runs:
  using: composite
  steps:
    - shell: bash
      run: echo ok
YAML
	cat >"${workflows_dir}/reusable-egress-only.yml" <<'YAML'
---
name: Egress only example
on:
  workflow_call:
jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout lgtm-ci tooling
        uses: actions/checkout@v4
        with:
          sparse-checkout: |
            .github/actions/harden-runner
            .github/actions/resolve-egress-allowlist
      - name: Harden runner
        uses: ./.lgtm-ci-tooling/.github/actions/harden-runner
YAML

	WORKFLOWS_DIR="${workflows_dir}" ACTIONS_DIR="${actions_dir}" run "${VALIDATOR}"
	assert_success
}
