#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/ghcr.sh aggregator

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
}

teardown() {
	teardown_temp_dir
}

@test "ghcr.sh: loads registry helpers" {
	run bash -c 'source "$LIB_DIR/ghcr.sh" && declare -F ghcr_collect_referenced_digests >/dev/null && echo loaded'
	assert_success
	assert_output "loaded"
}

@test "ghcr.sh: loads tag helpers" {
	run bash -c 'source "$LIB_DIR/ghcr.sh" && declare -F ghcr_is_ephemeral_only_tagged >/dev/null && echo loaded'
	assert_success
	assert_output "loaded"
}

@test "ghcr.sh: second source is a no-op when already loaded" {
	run bash -c '
		source "$LIB_DIR/ghcr.sh"
		source "$LIB_DIR/ghcr.sh"
		ghcr_is_ephemeral_only_tagged "[\"pr-1\"]"
	'
	assert_success
}
