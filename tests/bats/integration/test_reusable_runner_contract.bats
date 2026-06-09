#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for runner-image and runner-map reusable workflow policy

load "../../helpers/common"

VALIDATOR="${PROJECT_ROOT}/scripts/ci/quality/validate-runner-contract.sh"

@test "validate-runner-contract: passes on repository reusables" {
	run "${VALIDATOR}"
	assert_success
	assert_output --partial "OK:"
}

@test "validate-runner-contract: flags script-backed reusable without runner-image" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-script-backed-bad.yml" <<'YAML'
---
name: Script backed bad example
on:
  workflow_call:
    inputs:
      tooling-ref:
        type: string
        default: ""
jobs:
  check:
    name: Check
    runs-on: ubuntu-latest
    steps:
      - name: Checkout lgtm-ci tooling
        uses: actions/checkout@v4
        with:
          repository: lgtm-hq/lgtm-ci
          path: .lgtm-ci-tooling
          sparse-checkout: |
            scripts/ci/
      - run: .lgtm-ci-tooling/scripts/ci/example.sh
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "without runner-image input"
}

@test "validate-runner-contract: flags incomplete runner-image wiring" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-partial-wiring-bad.yml" <<'YAML'
---
name: Partial wiring bad example
on:
  workflow_call:
    inputs:
      runner-image:
        type: string
        default: "ubuntu-24.04"
jobs:
  work:
    runs-on: ${{ inputs.runner-image }}
    steps:
      - run: echo ok
  aggregate:
    runs-on: ubuntu-latest
    steps:
      - run: echo aggregate
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "hardcodes runs-on"
}

@test "validate-runner-contract: allows documented action-only exception" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cp "${PROJECT_ROOT}/.github/workflows/reusable-codeql.yml" "${workflows_dir}/"

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_success
}

@test "validate-runner-contract: allows docker coordinator and matrix runners" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cp "${PROJECT_ROOT}/.github/workflows/reusable-docker.yml" "${workflows_dir}/"

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_success
}

@test "validate-runner-contract: flags ubuntu-latest runner-image default (double quotes)" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-latest-default-bad.yml" <<'YAML'
---
name: Latest default bad example
on:
  workflow_call:
    inputs:
      runner-image:
        type: string
        default: "ubuntu-latest"
jobs:
  work:
    runs-on: ${{ inputs.runner-image }}
    steps:
      - run: echo ok
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "runner-image default must be ubuntu-24.04"
}

@test "validate-runner-contract: flags ubuntu-latest runner-image default (single quotes)" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-latest-default-single-quote-bad.yml" <<'YAML'
---
name: Latest default single quote bad example
on:
  workflow_call:
    inputs:
      runner-image:
        type: string
        default: 'ubuntu-latest'
jobs:
  work:
    runs-on: ${{ inputs.runner-image }}
    steps:
      - run: echo ok
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "runner-image default must be ubuntu-24.04"
}

@test "validate-runner-contract: flags ubuntu-latest runner-image default (unquoted)" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-latest-default-unquoted-bad.yml" <<'YAML'
---
name: Latest default unquoted bad example
on:
  workflow_call:
    inputs:
      runner-image:
        type: string
        default: ubuntu-latest
jobs:
  work:
    runs-on: ${{ inputs.runner-image }}
    steps:
      - run: echo ok
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "runner-image default must be ubuntu-24.04"
}

@test "reusable-release-version-pr: exposes runner-image on all jobs" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"
	run grep -F 'runner-image:' "$workflow"
	assert_success
	run awk '
		/^  version-pr:/ { in_job = 1 }
		/^  report-release-failure:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  version-pr:/ && !/^  report-release-failure:/ { in_job = 0 }
		in_job && /^    runs-on: \$\{\{ inputs\.runner-image \}\}$/ { found++ }
		END { exit found != 2 }
	' "$workflow"
	assert_success
}

@test "reusable-quality-lint: wires runner-image input" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-quality-lint.yml"
	run grep -F 'default: "ubuntu-24.04"' "$workflow"
	assert_success
	run awk '
		/^  quality:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  quality:/ { in_job = 0 }
		in_job && /^    runs-on: \$\{\{ inputs\.runner-image \}\}$/ { found = 1 }
		END { exit !found }
	' "$workflow"
	assert_success
}
