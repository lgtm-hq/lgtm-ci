#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/npm/verify-artifacts.sh (#965)

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/npm/verify-artifacts.sh"

setup() {
	setup_temp_dir
	save_path
	export PROJECT_ROOT
	export SCRIPT
	export PACKAGES_DIR="${BATS_TEST_TMPDIR}/npm-dist"
	mkdir -p "$PACKAGES_DIR/pkg-a/bin"
	echo "payload-a" >"$PACKAGES_DIR/pkg-a/bin/tool"
	echo "meta-json" >"$PACKAGES_DIR/pkg-a/package.json"
	# Manifest over the real bytes, like the build job would ship it.
	{
		h1="$(shasum -a 256 "$PACKAGES_DIR/pkg-a/bin/tool" | awk '{print $1}')"
		h2="$(shasum -a 256 "$PACKAGES_DIR/pkg-a/package.json" | awk '{print $1}')"
		printf '%s  pkg-a/bin/tool\n' "$h1"
		printf '%s  pkg-a/package.json\n' "$h2"
	} >"${BATS_TEST_TMPDIR}/SHA256SUMS"
	export CHECKSUMS_FILE="${BATS_TEST_TMPDIR}/SHA256SUMS"
	export SIGNER_REPO=lgtm-hq/lgtm-ci
	export SIGNER_WORKFLOW=.github/workflows/build.yml
	export FILES='["pkg-a/bin/tool", "pkg-a/package.json"]'
}

teardown() {
	restore_path
	teardown_temp_dir
}

attest_mock() {
	# $1: exit code for `gh attestation verify`
	mock_command_multi "gh" "
		*attestation*verify*) exit $1;;
		*) exit 0;;
	"
}

@test "verify-artifacts: passes bash syntax check" {
	run bash -n "$SCRIPT"
	assert_success
}

@test "verify-artifacts: passes when checksums and attestations match" {
	attest_mock 0

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "All artifacts verified"
}

@test "verify-artifacts: fails on a tampered artifact before anything is packed" {
	echo "tampered" >"$PACKAGES_DIR/pkg-a/bin/tool"
	attest_mock 0

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "sha256 mismatch for 'pkg-a/bin/tool'"
	assert_output --partial "nothing was published"
}

@test "verify-artifacts: fails on a missing attestation" {
	attest_mock 1

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "attestation verification failed for 'pkg-a/bin/tool'"
}

@test "verify-artifacts: fails when a manifest entry does not exist" {
	echo "gone" >"$PACKAGES_DIR/pkg-a/extra"
	h="$(shasum -a 256 "$PACKAGES_DIR/pkg-a/extra" | awk '{print $1}')"
	printf '%s  pkg-a/extra\n' "$h" >>"$CHECKSUMS_FILE"
	rm "$PACKAGES_DIR/pkg-a/extra"
	attest_mock 0

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "manifest lists 'pkg-a/extra' but it does not exist"
}

@test "verify-artifacts: fails when a target file has no manifest entry" {
	echo "unlisted" >"$PACKAGES_DIR/pkg-a/bin/unlisted"
	export FILES='["pkg-a/bin/unlisted"]'
	attest_mock 0

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "no checksums-manifest entry for 'pkg-a/bin/unlisted'"
}

@test "verify-artifacts: fails when the file list matches nothing" {
	export FILES='["pkg-a/does-not-exist/*"]'
	attest_mock 0

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "no files matched"
}

@test "verify-artifacts: fails on a missing checksums manifest" {
	export CHECKSUMS_FILE="${BATS_TEST_TMPDIR}/does-not-exist"
	attest_mock 0

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "checksums manifest"
}

@test "verify-artifacts: globs expand across packages" {
	mkdir -p "$PACKAGES_DIR/pkg-b/bin"
	echo "payload-b" >"$PACKAGES_DIR/pkg-b/bin/tool"
	h="$(shasum -a 256 "$PACKAGES_DIR/pkg-b/bin/tool" | awk '{print $1}')"
	printf '%s  pkg-b/bin/tool\n' "$h" >>"$CHECKSUMS_FILE"
	export FILES='["*/bin/tool"]'
	attest_mock 0

	run bash "$SCRIPT"
	assert_success
}
