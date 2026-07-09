#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for static reusable workflow job display names

load "../../helpers/common"

VALIDATOR="${PROJECT_ROOT}/scripts/ci/quality/validate-static-job-names.sh"

@test "validate-static-job-names: passes on repository reusables" {
	run "${VALIDATOR}"
	assert_success
	assert_output --partial "OK:"
}

@test "validate-static-job-names: flags block-scalar job.name with dynamic continuation" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-block-scalar-bad.yml" <<'YAML'
---
name: Block scalar bad example
on:
  workflow_call:
    inputs:
      flag:
        type: boolean
        default: false
jobs:
  matrix-job:
    name: >-
      ${{ matrix.platform }}
    if: ${{ inputs.flag }}
    strategy:
      matrix:
        platform: [linux]
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "dynamic job.name"
}

@test "validate-static-job-names: flags multi-line block-scalar with dynamic first line" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-block-scalar-multiline-bad.yml" <<'YAML'
---
name: Block scalar multiline bad example
on:
  workflow_call:
    inputs:
      flag:
        type: boolean
        default: false
jobs:
  matrix-job:
    name: >-
      ${{ matrix.platform }}
      suffix label
    if: ${{ inputs.flag }}
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "dynamic job.name"
}

@test "validate-static-job-names: flags dynamic matrix job.name on skippable jobs" {
	local workflows_dir="${BATS_TEST_TMPDIR}/.github/workflows"
	mkdir -p "${workflows_dir}"
	cat >"${workflows_dir}/reusable-bad-example.yml" <<'YAML'
---
name: Bad example
on:
  workflow_call:
    inputs:
      flag:
        type: boolean
        default: false
jobs:
  matrix-job:
    name: Build ${{ matrix.platform }}
    if: ${{ inputs.flag }}
    strategy:
      matrix:
        platform: [linux]
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
YAML

	WORKFLOWS_DIR="${workflows_dir}" run "${VALIDATOR}"
	assert_failure
	assert_output --partial "dynamic job.name"
}

@test "reusable-test-python: test job uses static name" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-python.yml"
	run awk '
		/^  test:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test:/ { in_job = 0 }
		in_job && /^    name: \$\{\{ inputs\.job-name \}\}$/ { found = 1 }
		END { exit !found }
	' "$workflow"
	assert_success
}

@test "reusable-docker: per-platform jobs use static names" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-docker-multiplatform.yml"
	run grep -F 'name: Docker build per platform' "$workflow"
	assert_success
	run grep -F 'name: Docker verify per platform' "$workflow"
	assert_success
	run grep -F 'name: Docker health check per platform' "$workflow"
	assert_success
}

@test "reusable-test-e2e-matrix: test job uses static name" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-e2e-matrix.yml"
	run awk '
		/^  test:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test:/ { in_job = 0 }
		in_job && /^    name: E2E tests$/ { found = 1 }
		END { exit !found }
	' "$workflow"
	assert_success
}
