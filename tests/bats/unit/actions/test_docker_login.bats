#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/docker-login.sh

load "../../../helpers/common"
load "../../../helpers/github_env"

SCRIPT="scripts/ci/actions/docker-login.sh"

setup() {
	setup_temp_dir
	setup_github_env
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

@test "docker-login: fails without STEP" {
	run env -u STEP bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "STEP is required"
}

@test "docker-login: fails on unknown step" {
	STEP="bogus" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "Unknown step"
}

@test "docker-login: validate fails without REGISTRY" {
	run env -u REGISTRY STEP="validate" bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "REGISTRY is required"
}

@test "docker-login: validate accepts ghcr.io" {
	STEP="validate" REGISTRY="ghcr.io" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "Registry validation passed: ghcr.io"
}

@test "docker-login: validate rejects unsupported registry" {
	STEP="validate" REGISTRY="quay.io" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "Unsupported registry"
}

@test "docker-login: validate requires Docker Hub credentials for docker.io" {
	STEP="validate" REGISTRY="docker.io" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "DOCKERHUB_USERNAME and DOCKERHUB_TOKEN are required"
}

@test "docker-login: validate rejects docker.io with only username" {
	STEP="validate" REGISTRY="docker.io" DOCKERHUB_USERNAME="user" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "DOCKERHUB_USERNAME and DOCKERHUB_TOKEN are required"
}

@test "docker-login: validate accepts docker.io with credentials" {
	STEP="validate" REGISTRY="docker.io" DOCKERHUB_USERNAME="user" \
		DOCKERHUB_TOKEN="token" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "Registry validation passed: docker.io"
}
