#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for validate-action-pinning action script

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/validate-action-pinning.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
	export SCRIPT
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

# Helper: create a workflow file in a temp scan directory
create_workflow() {
	local dir="$1"
	local filename="$2"
	local content="$3"
	mkdir -p "$dir"
	printf '%s\n' "$content" >"${dir}/${filename}"
}

# =============================================================================
# SHA-pinned actions pass
# =============================================================================

@test "validate-action-pinning: SHA-pinned actions pass validation" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29
      - uses: actions/setup-node@1a4442cacd436585916f16a2e5b1385ca3b5e13c
'

	run bash -c '
		export INPUT_ENFORCE=true
		export INPUT_ALLOW_ORG_VERSIONS=""
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "All action references are properly pinned"
	assert_github_output "offenders" "0"
}

# =============================================================================
# Version-tagged actions fail
# =============================================================================

@test "validate-action-pinning: version-tagged actions fail when not in allow list" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v3
'

	run bash -c '
		export INPUT_ENFORCE=true
		export INPUT_ALLOW_ORG_VERSIONS=""
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "unpinned action reference"
	assert_output --partial "actions/checkout@v4"
	assert_output --partial "actions/setup-node@v3"
	assert_github_output "offenders" "2"
}

@test "validate-action-pinning: version-tagged actions warn but pass when enforce is false" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
'

	run bash -c '
		export INPUT_ENFORCE=false
		export INPUT_ALLOW_ORG_VERSIONS=""
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "unpinned action reference"
	assert_github_output "offenders" "1"
}

# =============================================================================
# Local actions are ignored
# =============================================================================

@test "validate-action-pinning: local ./ actions are ignored" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: ./my-local-action
      - uses: ./.github/actions/my-action
'

	run bash -c '
		export INPUT_ENFORCE=true
		export INPUT_ALLOW_ORG_VERSIONS=""
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "All action references are properly pinned"
	assert_github_output "offenders" "0"
}

# =============================================================================
# Docker references are ignored
# =============================================================================

@test "validate-action-pinning: docker:// actions are ignored" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: docker://alpine:3.18
      - uses: docker://ghcr.io/owner/image:latest
'

	run bash -c '
		export INPUT_ENFORCE=true
		export INPUT_ALLOW_ORG_VERSIONS=""
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "All action references are properly pinned"
	assert_github_output "offenders" "0"
}

# =============================================================================
# Allowed org prefixes are respected
# =============================================================================

@test "validate-action-pinning: allowed org prefixes bypass SHA requirement" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: lgtm-hq/lgtm-ci/.github/actions/setup-env@v1
      - uses: lgtm-hq/lgtm-ci/.github/actions/run-tests@main
      - uses: actions/checkout@v4
'

	run bash -c '
		export INPUT_ENFORCE=true
		export INPUT_ALLOW_ORG_VERSIONS="lgtm-hq/lgtm-ci"
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "unpinned action reference"
	assert_output --partial "actions/checkout@v4"
	# lgtm-hq actions should not appear in offender lines
	refute_output --partial "lgtm-hq/lgtm-ci/.github/actions/setup-env@v1"
	refute_output --partial "lgtm-hq/lgtm-ci/.github/actions/run-tests@main"
	assert_github_output "offenders" "1"
}

@test "validate-action-pinning: multiple allowed org prefixes work" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: lgtm-hq/lgtm-ci/.github/actions/setup-env@v1
      - uses: my-org/my-action@v2
'

	run bash -c '
		export INPUT_ENFORCE=true
		export INPUT_ALLOW_ORG_VERSIONS="lgtm-hq/lgtm-ci, my-org/my-action"
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "All action references are properly pinned"
	assert_github_output "offenders" "0"
}

# =============================================================================
# Template expressions pass
# =============================================================================

@test "validate-action-pinning: template expressions are ignored" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: ${{ inputs.action-repo }}/.github/actions/setup@${{ inputs.ref }}
      - uses: lgtm-hq/lgtm-ci/.github/actions/setup-env@${{ inputs.tooling-ref }}
'

	run bash -c '
		export INPUT_ENFORCE=true
		export INPUT_ALLOW_ORG_VERSIONS=""
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "All action references are properly pinned"
	assert_github_output "offenders" "0"
}

# =============================================================================
# Mixed references
# =============================================================================

@test "validate-action-pinning: mixed pinned and unpinned are correctly reported" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29
      - uses: actions/setup-node@v3
      - uses: ./local-action
      - uses: docker://alpine:3.18
      - uses: some-org/some-action@main
'

	run bash -c '
		export INPUT_ENFORCE=true
		export INPUT_ALLOW_ORG_VERSIONS=""
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "actions/setup-node@v3"
	assert_output --partial "some-org/some-action@main"
	# Pinned actions, local refs, and docker refs should not appear in offender lines
	refute_output --partial "ci.yml:8: actions/checkout"
	refute_output --partial "ci.yml:10: ./local-action"
	refute_output --partial "ci.yml:11: docker://"
	assert_github_output "offenders" "2"
}

# =============================================================================
# Multiple scan paths
# =============================================================================

@test "validate-action-pinning: scans multiple paths" {
	local workflows_dir="${BATS_TEST_TMPDIR}/dot-github/workflows"
	local actions_dir="${BATS_TEST_TMPDIR}/dot-github/actions"

	create_workflow "$workflows_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
'

	create_workflow "$actions_dir" "action.yml" '
name: My Action
runs:
  using: composite
  steps:
    - uses: actions/setup-node@v3
'

	run bash -c '
		export INPUT_ENFORCE=true
		export INPUT_ALLOW_ORG_VERSIONS=""
		export INPUT_SCAN_PATHS="'"$workflows_dir"' '"$actions_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "actions/checkout@v4"
	assert_output --partial "actions/setup-node@v3"
	assert_github_output "offenders" "2"
}

# =============================================================================
# Edge cases
# =============================================================================

@test "validate-action-pinning: warns when no workflow files found" {
	local scan_dir="${BATS_TEST_TMPDIR}/empty-dir"
	mkdir -p "$scan_dir"

	run bash -c '
		export INPUT_ENFORCE=true
		export INPUT_ALLOW_ORG_VERSIONS=""
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "No workflow files found"
	assert_github_output "offenders" "0"
}

@test "validate-action-pinning: warns when scan path does not exist" {
	run bash -c '
		export INPUT_ENFORCE=true
		export INPUT_ALLOW_ORG_VERSIONS=""
		export INPUT_SCAN_PATHS="/nonexistent/path"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "Scan path does not exist"
	assert_github_output "offenders" "0"
}

@test "validate-action-pinning: actions without @ version are flagged" {
	local scan_dir="${BATS_TEST_TMPDIR}/workflows"
	create_workflow "$scan_dir" "ci.yml" '
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout
'

	run bash -c '
		export INPUT_ENFORCE=true
		export INPUT_ALLOW_ORG_VERSIONS=""
		export INPUT_SCAN_PATHS="'"$scan_dir"'"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "no version specified"
	assert_github_output "offenders" "1"
}
