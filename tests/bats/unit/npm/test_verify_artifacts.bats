#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/npm/verify-artifacts.sh (#965)

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/npm/verify-artifacts.sh"

# Same preference order as the script: GNU coreutils first, shasum fallback.
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

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
		h1="$(sha256_of "$PACKAGES_DIR/pkg-a/bin/tool")"
		h2="$(sha256_of "$PACKAGES_DIR/pkg-a/package.json")"
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
	h="$(sha256_of "$PACKAGES_DIR/pkg-a/extra")"
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

@test "verify-artifacts: empty file list verifies every manifest entry" {
	export FILES='[]'
	attest_mock 0

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Verifying pkg-a/bin/tool"
	assert_output --partial "Verifying pkg-a/package.json"
	assert_output --partial "All artifacts verified"

	# Tampering is still caught when the manifest drives the list.
	echo "tampered" >"$PACKAGES_DIR/pkg-a/bin/tool"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "sha256 mismatch for 'pkg-a/bin/tool'"
}

@test "verify-artifacts: empty file list with an empty manifest refuses to publish" {
	export FILES='[]'
	: >"$CHECKSUMS_FILE"
	attest_mock 0

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "lists no files"
}

@test "verify-artifacts: missing signer inputs fail closed naming the workflow input" {
	attest_mock 0
	unset SIGNER_REPO
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "signer-repo"

	export SIGNER_REPO=lgtm-hq/lgtm-ci
	unset SIGNER_WORKFLOW
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "signer-workflow"
}

@test "verify-artifacts: non-array FILES fails with a clear message" {
	attest_mock 0
	export FILES='"not-an-array"'

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "FILES must be a JSON array"
}

@test "verify-artifacts: accepts a manifest path relative to packages-dir as a fallback" {
	mv "$CHECKSUMS_FILE" "$PACKAGES_DIR/SHA256SUMS"
	export CHECKSUMS_FILE=SHA256SUMS
	attest_mock 0

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "All artifacts verified"
}

@test "verify-artifacts: manifest lookup is an exact path match, not a regex" {
	# `+` and `(` are ERE metacharacters; the path must still be found, and
	# a near-miss entry (dot as wildcard) must not satisfy it.
	mkdir -p "$PACKAGES_DIR/pkg+c/bin"
	echo "payload-c" >"$PACKAGES_DIR/pkg+c/bin/tool(1)"
	h="$(sha256_of "$PACKAGES_DIR/pkg+c/bin/tool(1)")"
	printf '%s  pkg+c/bin/tool(1)\n' "$h" >>"$CHECKSUMS_FILE"
	export FILES='["pkg+c/bin/tool(1)"]'
	attest_mock 0

	run bash "$SCRIPT"
	assert_success

	echo "near-miss" >"$PACKAGES_DIR/pkg-a/binXtool"
	export FILES='["pkg-a/binXtool"]'
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "no checksums-manifest entry for 'pkg-a/binXtool'"
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
	h="$(sha256_of "$PACKAGES_DIR/pkg-b/bin/tool")"
	printf '%s  pkg-b/bin/tool\n' "$h" >>"$CHECKSUMS_FILE"
	export FILES='["*/bin/tool"]'
	attest_mock 0

	run bash "$SCRIPT"
	assert_success
}

@test "verify-artifacts: qualifies a bare signer-workflow path with the signer repo for gh" {
	# gh wants [host/]owner/repo/path; the input is documented as a path.
	mock_command_multi "gh" '
		*attestation*verify*) echo "$*" >> "'"${BATS_TEST_TMPDIR}"'/gh-calls"; exit 0;;
		*) exit 0;;
	'

	run bash "$SCRIPT"
	assert_success
	run grep -F -- '--signer-workflow lgtm-hq/lgtm-ci/.github/workflows/build.yml' "${BATS_TEST_TMPDIR}/gh-calls"
	assert_success
	run grep -F -- '--signer-workflow .github/workflows/build.yml' "${BATS_TEST_TMPDIR}/gh-calls"
	assert_failure
}

@test "verify-artifacts: passes a fully qualified signer-workflow through unchanged" {
	export SIGNER_WORKFLOW=github.com/lgtm-hq/other/.github/workflows/build.yml
	mock_command_multi "gh" '
		*attestation*verify*) echo "$*" >> "'"${BATS_TEST_TMPDIR}"'/gh-calls"; exit 0;;
		*) exit 0;;
	'

	run bash "$SCRIPT"
	assert_success
	run grep -F -- '--signer-workflow github.com/lgtm-hq/other/.github/workflows/build.yml' "${BATS_TEST_TMPDIR}/gh-calls"
	assert_success
}
