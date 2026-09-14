#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/npm/assert-live-publish-inputs.sh (#965)

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/npm/assert-live-publish-inputs.sh"

setup() {
	export PROJECT_ROOT
	export SCRIPT
	export RUNNER_ENVIRONMENT=github-hosted
	export CHECKSUMS_FILE=npm-dist/SHA256SUMS
	export SIGNER_REPO=lgtm-hq/lgtm-ci
	export SIGNER_WORKFLOW=.github/workflows/build.yml
}

@test "assert-live-publish-inputs: passes bash syntax check" {
	run bash -n "$SCRIPT"
	assert_success
}

@test "assert-live-publish-inputs: live run with every precondition passes" {
	export LIVE=1
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Live-publish preconditions satisfied"
}

@test "assert-live-publish-inputs: live run without a checksums manifest fails closed" {
	export LIVE=1
	export CHECKSUMS_FILE=""
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "checksums-file is empty"
	assert_output --partial "nothing was downloaded, packed, or published"
}

@test "assert-live-publish-inputs: live run reports every missing signer input" {
	export LIVE=1
	export SIGNER_REPO=""
	export SIGNER_WORKFLOW=""
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "signer-repo is empty"
	assert_output --partial "signer-workflow is empty"
}

@test "assert-live-publish-inputs: live run refuses a self-hosted runner" {
	export LIVE=1
	export RUNNER_ENVIRONMENT=self-hosted
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "GitHub-hosted runner"
	assert_output --partial "self-hosted"
}

@test "assert-live-publish-inputs: dry-run stays permissive and only notices missing verification" {
	export LIVE=0
	export CHECKSUMS_FILE=""
	export SIGNER_REPO=""
	export RUNNER_ENVIRONMENT=self-hosted
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "not enforced"
	assert_output --partial "::notice::checksums-file is empty"
}
