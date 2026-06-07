#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-publish-rust-release orchestrator

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-publish-rust-release.yml"
BUILD_WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-build-rust-binaries.yml"

@test "reusable-publish-rust-release: orchestrates verify, build, and release jobs" {
	run grep -F 'verify-tag:' "$WORKFLOW"
	assert_success
	run grep -F 'build-binaries:' "$WORKFLOW"
	assert_success
	run grep -F 'github-release:' "$WORKFLOW"
	assert_success
}

@test "reusable-publish-rust-release: calls reusable-build-rust-binaries" {
	run grep -F 'reusable-build-rust-binaries.yml' "$WORKFLOW"
	assert_success
}

@test "reusable-publish-rust-release: verifies tag against Cargo.toml" {
	run grep -F 'verify-rust-release-tag.sh' "$WORKFLOW"
	assert_success
}

@test "reusable-publish-rust-release: downloads artifacts by prefix pattern" {
	run grep -F 'merge-multiple: true' "$WORKFLOW"
	assert_success
	run grep -F 'needs.verify-tag.outputs.artifact_prefix' "$WORKFLOW"
	assert_success
}

@test "reusable-publish-rust-release: verify-tag exposes artifact_prefix output" {
	run grep -F 'artifact_prefix:' "$WORKFLOW"
	assert_success
}

@test "reusable-publish-rust-release: release concurrency group" {
	run grep -F 'release-${{ github.ref_name }}' "$WORKFLOW"
	assert_success
}

@test "reusable-publish-rust-release: aggregates per-target checksum manifests" {
	run grep -F 'Aggregate checksum manifests' "$WORKFLOW"
	assert_success
	run grep -F 'aggregate-rust-release-checksums.sh' "$WORKFLOW"
	assert_success
}

@test "reusable-build-rust-binaries workflow file exists for nested call" {
	[[ -f "$BUILD_WORKFLOW" ]]
}

@test "reusable-publish-rust-release: build-binaries grants attestation permissions" {
	run grep -F 'attestations: write' "$WORKFLOW"
	assert_success
}
