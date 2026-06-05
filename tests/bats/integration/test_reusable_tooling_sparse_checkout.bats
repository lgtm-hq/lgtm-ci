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

@test "validate-tooling-sparse-checkout: fails when ACTIONS_DIR is missing" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"

	WORKFLOWS_DIR="${workflows_dir}" ACTIONS_DIR="${BATS_TEST_TMPDIR}/missing-actions" \
		run "${VALIDATOR}"
	assert_failure
	assert_output --partial "actions directory not found"
}

@test "validate-tooling-sparse-checkout: flags early checkout missing scripts/ci/ in multi-checkout job" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	local actions_dir="${BATS_TEST_TMPDIR}/.github/actions"
	mkdir -p "${workflows_dir}" \
		"${actions_dir}/validate-action-pinning" \
		"${actions_dir}/post-pr-comment"
	cat >"${actions_dir}/validate-action-pinning/action.yml" <<'YAML'
---
name: Validate action pinning
runs:
  using: composite
  steps:
    - shell: bash
      run: $SCRIPTS_DIR/ci/actions/validate-action-pinning.sh
YAML
	cat >"${actions_dir}/post-pr-comment/action.yml" <<'YAML'
---
name: Post PR comment
runs:
  using: composite
  steps:
    - shell: bash
      run: $SCRIPTS_DIR/ci/actions/post-pr-comment.sh
YAML
	cat >"${workflows_dir}/reusable-multi-checkout-bad.yml" <<'YAML'
---
name: Multi checkout bad example
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
      - name: Checkout lgtm-ci tooling
        uses: actions/checkout@v4
        with:
          sparse-checkout: |
            .github/actions/
            scripts/ci/
      - name: Post PR comment
        uses: ./.lgtm-ci-tooling/.github/actions/post-pr-comment
YAML

	WORKFLOWS_DIR="${workflows_dir}" ACTIONS_DIR="${actions_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "validate-action-pinning"
}

@test "validate-tooling-sparse-checkout: rejects scripts/cicd/ near-miss path" {
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
	cat >"${workflows_dir}/reusable-near-miss-sparse.yml" <<'YAML'
---
name: Near miss sparse example
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
            scripts/ci/
      - name: Checkout lgtm-ci tooling
        uses: actions/checkout@v4
        with:
          sparse-checkout: |
            .github/actions/
            scripts/cicd/
      - name: Validate action pinning
        uses: ./.lgtm-ci-tooling/.github/actions/validate-action-pinning
YAML

	WORKFLOWS_DIR="${workflows_dir}" ACTIONS_DIR="${BATS_TEST_TMPDIR}/.github/actions" \
		run "${VALIDATOR}"
	assert_failure
	assert_output --partial "validate-action-pinning"
}
