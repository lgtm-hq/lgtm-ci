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

# reusable-test-python's `aggregate` job requires a non-empty `python-versions`
# and a successful `prepare`, and `prepare` runs this validator. So rejecting
# this exact combination is what makes every `inputs.coverage`-gated step in
# `aggregate` unreachable — the reason the coverage merge step was deleted in
# #756. Relaxing it makes that dead path live again, so it is pinned here.
@test "validate-test-compat-coverage-contract: rejects python matrix with coverage (#756)" {
	run env \
		MULTI_VERSIONS="3.11,3.14" \
		COVERAGE="true" \
		PUBLISH_TEST_SUMMARY="false" \
		PLATFORM="Python" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/validate-test-compat-coverage-contract.sh"

	assert_failure
	assert_output --partial "Python: multi-runtime matrix (3.11,3.14)"
	assert_output --partial "cannot be combined with coverage: true"
	assert_output --partial "separate single-runtime job"
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
