#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for generate-node-matrix.sh pages coverage output

load "../../../helpers/common"
load "../../../helpers/github_env"

setup() {
	setup_github_env
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/generate-node-matrix.sh"
}

@test "generate-node-matrix: emits pages-coverage-node-version for first matrix leg" {
	NODE_VERSIONS=20,22 NODE_VERSION=20 run bash "$SCRIPT"
	assert_success
	grep -q '^pages-coverage-node-version=20$' "$GITHUB_OUTPUT"
	assert_output --partial "Pages coverage node version: 20"
}

@test "generate-node-matrix: uses sole node-version when matrix is disabled" {
	NODE_VERSION=22 NODE_VERSIONS= run bash "$SCRIPT"
	assert_success
	grep -q '^pages-coverage-node-version=22$' "$GITHUB_OUTPUT"
}
