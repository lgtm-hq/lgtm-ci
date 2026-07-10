#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for harden-runner workflow pins

load "../../helpers/common"

VALIDATE="${PROJECT_ROOT}/scripts/ci/actions/validate-harden-runner-action-ref.sh"
HARDEN_PIN='step-security/harden-runner@bf7454d06d71f1098171f2acdf0cd4708d7b5920 # v2.20.0'

@test "validate-harden-runner-action-ref: all reusables use direct step-security/harden-runner" {
	run bash "$VALIDATE"
	assert_success
}

# Write a fixture reusable workflow. The FIRST job bootstraps the tooling
# checkout but does NOT consume it via checkout-and-harden (so `tooling`
# stays set across the job boundary). The SECOND job key is $2 (e.g. deploy
# or '"deploy"'); when $3 is "leak" it uses checkout-and-harden WITHOUT its
# own bootstrap Checkout step, so it would inherit the first job's tooling
# checkout unless the job boundary is recognized.
_write_two_job_fixture() {
	local dir="$1" key="$2" mode="$3"
	local bootstrap=""
	if [[ "$mode" != "leak" ]]; then
		bootstrap='      - name: Checkout lgtm-ci tooling
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          sparse-checkout: |
            .github/actions/checkout-and-harden
          sparse-checkout-cone-mode: true
          persist-credentials: false'
	fi
	cat >"$dir/reusable-fixture.yml" <<EOF
name: Fixture
on:
  workflow_call:
jobs:
  first:
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout lgtm-ci tooling
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          sparse-checkout: |
            .github/actions/checkout-and-harden
          sparse-checkout-cone-mode: true
          persist-credentials: false
      - name: Use tooling
        run: bash .lgtm-ci-tooling/scripts/ci/actions/noop.sh
  ${key}:
    runs-on: ubuntu-24.04
    steps:
      - name: Harden runner
        uses: ${HARDEN_PIN}
        with:
          egress-policy: block
          allowed-endpoints: \${{ inputs.allowed-endpoints }}
${bootstrap:+$bootstrap
}      - name: Checkout and harden
        id: egress
        uses: ./.lgtm-ci-tooling/.github/actions/checkout-and-harden
        with:
          egress-policy: block
EOF
}

@test "validate-harden-runner-action-ref: flags a quoted job that skips its bootstrap checkout" {
	local dir="$BATS_TEST_TMPDIR/wf"
	mkdir -p "$dir"
	_write_two_job_fixture "$dir" '"deploy"' leak
	WORKFLOWS_DIR="$dir" run bash "$VALIDATE"
	assert_failure
	assert_output --partial "Checkout lgtm-ci tooling must precede checkout-and-harden"
}

@test "validate-harden-runner-action-ref: accepts a quoted job that bootstraps its own checkout" {
	local dir="$BATS_TEST_TMPDIR/wf"
	mkdir -p "$dir"
	_write_two_job_fixture "$dir" '"deploy"' ok
	WORKFLOWS_DIR="$dir" run bash "$VALIDATE"
	assert_success
}

@test "validate-harden-runner-action-ref: still flags an unquoted job that skips its bootstrap" {
	local dir="$BATS_TEST_TMPDIR/wf"
	mkdir -p "$dir"
	_write_two_job_fixture "$dir" deploy leak
	WORKFLOWS_DIR="$dir" run bash "$VALIDATE"
	assert_failure
	assert_output --partial "Checkout lgtm-ci tooling must precede checkout-and-harden"
}

# A workflow may indent job keys deeper than two spaces (valid YAML). The job
# boundary must still be recognized at that indent so a later job cannot inherit
# a prior job tooling checkout. Discriminating: the old fixed two-space boundary
# missed 4-space job keys and let the leak pass.
@test "validate-harden-runner-action-ref: flags a 4-space-indented job that skips its bootstrap" {
	local dir="$BATS_TEST_TMPDIR/wf"
	mkdir -p "$dir"
	cat >"$dir/reusable-fixture.yml" <<EOF
name: Fixture
on:
  workflow_call:
jobs:
    first:
        runs-on: ubuntu-24.04
        steps:
            - name: Checkout lgtm-ci tooling
              uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
              with:
                  sparse-checkout: |
                      .github/actions/checkout-and-harden
                  sparse-checkout-cone-mode: true
                  persist-credentials: false
            - name: Use tooling
              run: bash .lgtm-ci-tooling/scripts/ci/actions/noop.sh
    deploy:
        runs-on: ubuntu-24.04
        steps:
            - name: Harden runner
              uses: ${HARDEN_PIN}
              with:
                  egress-policy: block
                  allowed-endpoints: \${{ inputs.allowed-endpoints }}
            - name: Checkout and harden
              id: egress
              uses: ./.lgtm-ci-tooling/.github/actions/checkout-and-harden
              with:
                  egress-policy: block
EOF
	WORKFLOWS_DIR="$dir" run bash "$VALIDATE"
	assert_failure
	assert_output --partial "Checkout lgtm-ci tooling must precede checkout-and-harden"
}

# Companion: the same 4-space layout must PASS when the second job bootstraps its
# own tooling checkout (guards against the fix over-flagging valid workflows).
@test "validate-harden-runner-action-ref: accepts a 4-space-indented job that bootstraps its own checkout" {
	local dir="$BATS_TEST_TMPDIR/wf"
	mkdir -p "$dir"
	cat >"$dir/reusable-fixture.yml" <<EOF
name: Fixture
on:
  workflow_call:
jobs:
    first:
        runs-on: ubuntu-24.04
        steps:
            - name: Checkout lgtm-ci tooling
              uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
              with:
                  sparse-checkout: |
                      .github/actions/checkout-and-harden
                  sparse-checkout-cone-mode: true
                  persist-credentials: false
            - name: Use tooling
              run: bash .lgtm-ci-tooling/scripts/ci/actions/noop.sh
    deploy:
        runs-on: ubuntu-24.04
        steps:
            - name: Harden runner
              uses: ${HARDEN_PIN}
              with:
                  egress-policy: block
                  allowed-endpoints: \${{ inputs.allowed-endpoints }}
            - name: Checkout lgtm-ci tooling
              uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
              with:
                  sparse-checkout: |
                      .github/actions/checkout-and-harden
                  sparse-checkout-cone-mode: true
                  persist-credentials: false
            - name: Checkout and harden
              id: egress
              uses: ./.lgtm-ci-tooling/.github/actions/checkout-and-harden
              with:
                  egress-policy: block
EOF
	WORKFLOWS_DIR="$dir" run bash "$VALIDATE"
	assert_success
}
