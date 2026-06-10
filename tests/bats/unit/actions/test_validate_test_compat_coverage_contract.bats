#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/validate-test-compat-coverage-contract.sh

load "../../../helpers/common"

@test "validate-test-compat-coverage-contract: allows single-version coverage" {
	run env \
		MULTI_VERSIONS="" \
		COVERAGE="true" \
		PUBLISH_TEST_SUMMARY="true" \
		PLATFORM="Python" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/validate-test-compat-coverage-contract.sh"

	assert_success
}

@test "validate-test-compat-coverage-contract: allows compat matrix without coverage or publish" {
	run env \
		MULTI_VERSIONS="3.12,3.14" \
		COVERAGE="false" \
		PUBLISH_TEST_SUMMARY="false" \
		PLATFORM="Python" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/validate-test-compat-coverage-contract.sh"

	assert_success
}

@test "validate-test-compat-coverage-contract: rejects matrix with coverage" {
	run env \
		MULTI_VERSIONS="20,22" \
		COVERAGE="true" \
		PUBLISH_TEST_SUMMARY="false" \
		PLATFORM="Node.js" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/validate-test-compat-coverage-contract.sh"

	assert_failure
	assert_output --partial "multi-runtime matrix"
	assert_output --partial "coverage: true"
}

@test "validate-test-compat-coverage-contract: rejects matrix with publish-test-summary" {
	run env \
		MULTI_VERSIONS="stable,beta" \
		COVERAGE="false" \
		PUBLISH_TEST_SUMMARY="true" \
		PLATFORM="Rust" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/validate-test-compat-coverage-contract.sh"

	assert_failure
	assert_output --partial "publish-test-summary: true"
}

@test "validate-test-compat-coverage-contract: rejects matrix with both coverage and publish" {
	run env \
		MULTI_VERSIONS="20,22" \
		COVERAGE="true" \
		PUBLISH_TEST_SUMMARY="true" \
		PLATFORM="Node.js" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/validate-test-compat-coverage-contract.sh"

	assert_failure
	assert_output --partial "coverage: true, publish-test-summary: true"
}
