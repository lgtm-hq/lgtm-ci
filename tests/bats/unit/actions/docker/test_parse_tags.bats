#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/parse-tags.sh

load "../../../../helpers/common"
load "../../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/parse-tags.sh"

setup() {
	setup_temp_dir
	setup_github_env
	export SCRIPT
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

@test "parse-tags: converts comma-separated tags to metadata-action format" {
	export INPUT_TAGS="latest,stable"

	run bash "$SCRIPT"
	assert_success

	local tags
	tags=$(get_github_output "tags")
	[[ "$tags" == *"type=raw,value=latest"* ]]
	[[ "$tags" == *"type=raw,value=stable"* ]]
}

@test "parse-tags: handles single tag" {
	export INPUT_TAGS="nightly"

	run bash "$SCRIPT"
	assert_success

	local tags
	tags=$(get_github_output "tags")
	[[ "$tags" == *"type=raw,value=nightly"* ]]
}

@test "parse-tags: trims whitespace and skips empty entries" {
	export INPUT_TAGS=" latest , ,stable "

	run bash "$SCRIPT"
	assert_success

	local tags
	tags=$(get_github_output "tags")
	[[ "$tags" == *"type=raw,value=latest"* ]]
	[[ "$tags" == *"type=raw,value=stable"* ]]
	[[ "$tags" != *"value= "* ]]
}

@test "parse-tags: outputs empty when INPUT_TAGS is empty" {
	export INPUT_TAGS=""

	run bash "$SCRIPT"
	assert_success

	# set_github_output writes "tags=" (empty value); verify the key exists
	run grep "^tags=" "$GITHUB_OUTPUT"
	assert_success
}

@test "parse-tags: outputs empty when INPUT_TAGS is unset" {
	unset INPUT_TAGS

	run bash "$SCRIPT"
	assert_success

	run grep "^tags=" "$GITHUB_OUTPUT"
	assert_success
}
