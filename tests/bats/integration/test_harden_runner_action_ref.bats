#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for harden-runner workflow pins

load "../../helpers/common"

VALIDATE="${PROJECT_ROOT}/scripts/ci/actions/validate-harden-runner-action-ref.sh"
# Derive the fixture pin from the validator so Renovate SHA bumps stay in sync.
HARDEN_LINE="$(sed -nE "s/^HARDEN_SHA='([a-f0-9]{40})' # (v[0-9.]+).*/\\1 \\2/p" "$VALIDATE")"
HARDEN_SHA="${HARDEN_LINE%% *}"
HARDEN_TAG="${HARDEN_LINE#* }"
HARDEN_PIN="step-security/harden-runner@${HARDEN_SHA} # ${HARDEN_TAG}"

setup() {
	if [[ -z "$HARDEN_SHA" || -z "$HARDEN_TAG" || "$HARDEN_SHA" == "$HARDEN_TAG" ]]; then
		echo "failed to parse HARDEN_SHA/HARDEN_TAG from ${VALIDATE}" >&2
		return 1
	fi
}

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
          allowed-endpoints: \${{ fromJSON(env.LGTM_CI_EGRESS_PRESETS)['github-minimal'] }}
${bootstrap:+$bootstrap
}      - name: Checkout and harden
        id: egress
        uses: ./.lgtm-ci-tooling/.github/actions/checkout-and-harden
        with:
          tooling-ref: abc
EOF
}

# Write a one-job fixture whose harden-runner allowed-endpoints is $2 (raw
# YAML value, may span lines when it starts with a block indicator).
_write_allowlist_fixture() {
	local dir="$1" allowlist="$2"
	cat >"$dir/reusable-fixture.yml" <<EOF
name: Fixture
on:
  workflow_call:
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - name: Harden runner
        uses: ${HARDEN_PIN}
        with:
          egress-policy: block
          allowed-endpoints: ${allowlist}
      - name: Checkout repository
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
EOF
}

@test "validate-harden-runner-action-ref: accepts the caller-selectable preset composition" {
	local dir="$BATS_TEST_TMPDIR/wf"
	mkdir -p "$dir"
	_write_allowlist_fixture "$dir" ">-
            \${{ (inputs.allowed-endpoints-mode != 'append' && inputs.allowed-endpoints != '')
            && inputs.allowed-endpoints
            || format('{0} {1}',
            fromJSON(env.LGTM_CI_EGRESS_PRESETS)[inputs.egress-preset || 'quality'],
            inputs.allowed-endpoints) }}"
	WORKFLOWS_DIR="$dir" run bash "$VALIDATE"
	assert_success
}

@test "validate-harden-runner-action-ref: flags a raw inputs.allowed-endpoints pass-through" {
	# Pre-#913 shape: enforces the caller list but ignores egress-preset.
	local dir="$BATS_TEST_TMPDIR/wf"
	mkdir -p "$dir"
	_write_allowlist_fixture "$dir" '\${{ inputs.allowed-endpoints }}'
	WORKFLOWS_DIR="$dir" run bash "$VALIDATE"
	assert_failure
	assert_output --partial "must select a preset via fromJSON(env.LGTM_CI_EGRESS_PRESETS)"
}

@test "validate-harden-runner-action-ref: flags a hand-maintained literal host list" {
	local dir="$BATS_TEST_TMPDIR/wf"
	mkdir -p "$dir"
	_write_allowlist_fixture "$dir" ">
            github.com:443
            api.github.com:443"
	WORKFLOWS_DIR="$dir" run bash "$VALIDATE"
	assert_failure
	assert_output --partial "contains a literal host:port"
}

@test "validate-harden-runner-action-ref: flags step outputs in allowed-endpoints" {
	local dir="$BATS_TEST_TMPDIR/wf"
	mkdir -p "$dir"
	_write_allowlist_fixture "$dir" ">-
            \${{ format('{0} {1}', fromJSON(env.LGTM_CI_EGRESS_PRESETS)['quality'], steps.egress.outputs.allowed-endpoints) }}"
	WORKFLOWS_DIR="$dir" run bash "$VALIDATE"
	assert_failure
	assert_output --partial "may reference only inputs.* and env.*"
}

@test "validate-harden-runner-action-ref: flags a literal host after an expression on the same line" {
	local dir="$BATS_TEST_TMPDIR/wf"
	mkdir -p "$dir"
	_write_allowlist_fixture "$dir" "\\\${{ fromJSON(env.LGTM_CI_EGRESS_PRESETS)['github-minimal'] }} evil.example:443"
	WORKFLOWS_DIR="$dir" run bash "$VALIDATE"
	assert_failure
	assert_output --partial "contains a literal host:port (evil.example:443)"
}

@test "validate-harden-runner-action-ref: flags several hosts on one continuation line" {
	local dir="$BATS_TEST_TMPDIR/wf"
	mkdir -p "$dir"
	_write_allowlist_fixture "$dir" ">
            \\\${{ fromJSON(env.LGTM_CI_EGRESS_PRESETS)['github-minimal'] }}
            evil.example:443 evil2.example:443"
	WORKFLOWS_DIR="$dir" run bash "$VALIDATE"
	assert_failure
	assert_output --partial "evil.example:443, evil2.example:443"
}

@test "validate-harden-runner-action-ref: flags github context in allowed-endpoints" {
	# github.event.* is attacker-controlled; it must never widen egress.
	local dir="$BATS_TEST_TMPDIR/wf"
	mkdir -p "$dir"
	_write_allowlist_fixture "$dir" ">-
            \\\${{ format('{0} {1}', fromJSON(env.LGTM_CI_EGRESS_PRESETS)['github-minimal'], github.head_ref) }}"
	WORKFLOWS_DIR="$dir" run bash "$VALIDATE"
	assert_failure
	assert_output --partial "may reference only inputs.* and env.*"
	assert_output --partial "found: github"
}

@test "validate-harden-runner-action-ref: ignores comments and quoted hosts inside expressions" {
	local dir="$BATS_TEST_TMPDIR/wf"
	mkdir -p "$dir"
	cat >"$dir/reusable-fixture.yml" <<EOF
name: Fixture
on:
  workflow_call:
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - name: Harden runner
        uses: ${HARDEN_PIN}
        with:
          egress-policy: block
          # harden-runner.md explains why the runner.os gate matters here
          allowed-endpoints: >
            \\\${{ fromJSON(env.LGTM_CI_EGRESS_PRESETS)[inputs.egress-preset || 'ai-review'] }}
            \\\${{ env.AI_REVIEW_PROVIDER == 'anthropic' && 'api.anthropic.com:443' || '' }}
EOF
	WORKFLOWS_DIR="$dir" run bash "$VALIDATE"
	assert_success
}

@test "validate-harden-runner-action-ref: flags a reference to the removed resolve composite" {
	local dir="$BATS_TEST_TMPDIR/wf"
	mkdir -p "$dir"
	cat >"$dir/reusable-fixture.yml" <<EOF
name: Fixture
on:
  workflow_call:
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - name: Harden runner
        uses: ${HARDEN_PIN}
        with:
          egress-policy: block
          allowed-endpoints: \${{ fromJSON(env.LGTM_CI_EGRESS_PRESETS)['github-minimal'] }}
      - name: Checkout lgtm-ci tooling
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          sparse-checkout: |
            .github/actions/resolve-egress-allowlist
      - name: Resolve egress allowlist
        uses: ./.lgtm-ci-tooling/.github/actions/resolve-egress-allowlist
EOF
	WORKFLOWS_DIR="$dir" run bash "$VALIDATE"
	assert_failure
	assert_output --partial "removed resolve-egress-allowlist"
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
                  allowed-endpoints: \${{ fromJSON(env.LGTM_CI_EGRESS_PRESETS)['github-minimal'] }}
            - name: Checkout and harden
              id: egress
              uses: ./.lgtm-ci-tooling/.github/actions/checkout-and-harden
              with:
                  tooling-ref: abc
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
                  allowed-endpoints: \${{ fromJSON(env.LGTM_CI_EGRESS_PRESETS)['github-minimal'] }}
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
                  tooling-ref: abc
EOF
	WORKFLOWS_DIR="$dir" run bash "$VALIDATE"
	assert_success
}
