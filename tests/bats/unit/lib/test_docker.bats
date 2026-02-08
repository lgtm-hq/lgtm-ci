#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/docker.sh (aggregator)

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export LIB_DIR
	export BATS_TEST_TMPDIR
}

teardown() {
	teardown_temp_dir
}

# =============================================================================
# Aggregator loading tests
# =============================================================================

@test "docker.sh: sources docker/core.sh" {
	run bash -c 'source "$LIB_DIR/docker.sh" && declare -f check_docker_available >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "docker.sh: sources docker/registry.sh" {
	run bash -c 'source "$LIB_DIR/docker.sh" && declare -f docker_login_ghcr >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

@test "docker.sh: sources docker/tags.sh" {
	run bash -c 'source "$LIB_DIR/docker.sh" && declare -f generate_docker_tags >/dev/null && echo "loaded"'
	assert_success
	assert_output "loaded"
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "docker.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/docker.sh"
		source "$LIB_DIR/docker.sh"
		declare -f check_docker_available >/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "docker.sh: sets _LGTM_CI_DOCKER_LOADED guard" {
	run bash -c 'source "$LIB_DIR/docker.sh" && echo "${_LGTM_CI_DOCKER_LOADED}"'
	assert_success
	assert_output "1"
}
