#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/release/create-github-release.sh

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="scripts/ci/release/create-github-release.sh"

setup() {
	setup_temp_dir
	setup_github_env
	mock_command_record "gh" "https://github.com/test-org/test-repo/releases/tag/v1.0.0"
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

# Assert gh was invoked with a literal substring (safe for leading dashes)
assert_gh_called_with() {
	if ! grep -qF -- "$1" "${BATS_TEST_TMPDIR}/mock_calls_gh"; then
		echo "# expected gh call containing: $1" >&2
		cat "${BATS_TEST_TMPDIR}/mock_calls_gh" >&2
		return 1
	fi
}

refute_gh_called_with() {
	if grep -qF -- "$1" "${BATS_TEST_TMPDIR}/mock_calls_gh"; then
		echo "# expected no gh call containing: $1" >&2
		return 1
	fi
}

@test "create-github-release: fails without TAG" {
	run env -u TAG bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "TAG is required"
}

@test "create-github-release: creates release with repo from GITHUB_REPOSITORY" {
	TAG="v1.0.0" BODY="notes" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "release-url=https://github.com/test-org/test-repo/releases/tag/v1.0.0"

	assert_gh_called_with "release create v1.0.0 --repo test-org/test-repo --title v1.0.0"
}

@test "create-github-release: honors explicit REPO and TITLE" {
	TAG="v1.0.0" BODY="notes" REPO="other/repo" TITLE="My Release" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	assert_gh_called_with "--repo other/repo"
	assert_gh_called_with "--title My Release"
}

@test "create-github-release: passes --draft when DRAFT=true" {
	TAG="v1.0.0" BODY="notes" DRAFT="true" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	assert_gh_called_with "--draft"
}

@test "create-github-release: passes --prerelease when PRERELEASE=true" {
	TAG="v1.0.0" BODY="notes" PRERELEASE="true" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	assert_gh_called_with "--prerelease"
}

@test "create-github-release: uses --generate-notes when GENERATE_NOTES=true" {
	TAG="v1.0.0" GENERATE_NOTES="true" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	assert_gh_called_with "--generate-notes"
	refute_gh_called_with "--notes "
}

@test "create-github-release: uses BODY as release notes" {
	TAG="v1.0.0" BODY="release body text" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	assert_gh_called_with "--notes release body text"
}

@test "create-github-release: attaches existing FILES and skips missing ones" {
	local asset="${BATS_TEST_TMPDIR}/artifact.tar.gz"
	echo "data" >"$asset"

	TAG="v1.0.0" BODY="notes" FILES="$asset ${BATS_TEST_TMPDIR}/missing.zip" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "File not found, skipping"

	assert_gh_called_with "$asset"
	refute_gh_called_with "missing.zip"
}

@test "create-github-release: fails when FILE_PATTERNS matches nothing" {
	TAG="v1.0.0" BODY="notes" FILE_PATTERNS="${BATS_TEST_TMPDIR}/nope-*.tgz" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "No release assets matched FILE_PATTERNS"
}

@test "create-github-release: fails when gh release create fails" {
	mock_command_record "gh" "boom" 1

	TAG="v1.0.0" BODY="notes" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "Failed to create release"
}

@test "create-github-release: writes GitHub Actions outputs" {
	TAG="v1.0.0" BODY="notes" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	assert_file_contains "$GITHUB_OUTPUT" "release-url=https://github.com/test-org/test-repo/releases/tag/v1.0.0"
	assert_file_contains "$GITHUB_OUTPUT" "tag=v1.0.0"
}
