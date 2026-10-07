#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/merge-node-coverage.sh (#1091)
#
# reusable-test-node-publish.yml downloads <artifact-prefix>-coverage-* and
# hands the prefix to this script; the glob must follow it or a non-default
# prefix merges nothing and the publish fails.

load "../../../helpers/common"

setup() {
	setup_temp_dir
	cd "$BATS_TEST_TMPDIR" || return 1
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/merge-node-coverage.sh"
}

teardown() {
	teardown_temp_dir
}

_artifact() {
	mkdir -p "artifacts/$1"
	echo '{}' >"artifacts/$1/coverage-summary.json"
}

@test "merge-node-coverage: merges the default node-coverage-* artifacts" {
	_artifact node-coverage-20
	_artifact node-coverage-22

	ARTIFACTS_DIR=artifacts OUTPUT_DIR=out run bash "$SCRIPT"
	assert_success
	assert_file_exists out/node-coverage-20/coverage-summary.json
	assert_file_exists out/node-coverage-22/coverage-summary.json
}

@test "merge-node-coverage: follows ARTIFACT_PREFIX and ignores other prefixes" {
	_artifact backend-coverage-22
	_artifact node-coverage-22

	ARTIFACTS_DIR=artifacts OUTPUT_DIR=out ARTIFACT_PREFIX=backend run bash "$SCRIPT"
	assert_success
	assert_file_exists out/backend-coverage-22/coverage-summary.json
	run test -e out/node-coverage-22
	assert_failure
}

@test "merge-node-coverage: fails naming the prefixed glob when nothing matches" {
	_artifact node-coverage-22

	ARTIFACTS_DIR=artifacts OUTPUT_DIR=out ARTIFACT_PREFIX=backend run bash "$SCRIPT"
	assert_failure
	assert_output --partial "No backend-coverage-* artifacts found"
}

@test "merge-node-coverage: nests under working-directory" {
	mkdir -p artifacts/node-coverage-22/apps/web
	echo '{}' >artifacts/node-coverage-22/apps/web/coverage-summary.json

	ARTIFACTS_DIR=artifacts OUTPUT_DIR=out WORKING_DIRECTORY=apps/web run bash "$SCRIPT"
	assert_success
	assert_file_exists out/apps/web/node-coverage-22/coverage-summary.json
}
