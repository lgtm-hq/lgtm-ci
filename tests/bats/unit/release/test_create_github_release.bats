#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/release/create-github-release.sh

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="scripts/ci/release/create-github-release.sh"

# Install a `gh` mock that answers `release view` and `release create`
# independently and records every invocation, so the exists-guard and the
# create path can be driven apart.
#
# Controlled via exported MOCK_* variables (defaults set in setup):
#   MOCK_EXISTING_TAG        - tag that already has a release ("" for none)
#   MOCK_EXISTING_RELEASE_*  - id/url reported for that pre-existing release
#   MOCK_CREATED_RELEASE_*   - id/url reported for a release created this run
#   MOCK_CREATE_ERROR        - when set, `release create` fails with this stderr
#   MOCK_UPLOAD_ERROR        - when set, `release upload` fails with this stderr
mock_gh() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	local calls_file="${BATS_TEST_TMPDIR}/mock_calls_gh"
	local created_marker="${BATS_TEST_TMPDIR}/gh_created_release"
	: >"$calls_file"
	rm -f "$created_marker"

	cat >"${mock_bin}/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >>'${calls_file}'

if [[ "\$1" == "release" && "\$2" == "view" ]]; then
	if [[ -n "\${MOCK_EXISTING_TAG:-}" && "\$3" == "\${MOCK_EXISTING_TAG}" ]]; then
		if [[ "\$*" == *"--json id"* ]]; then
			echo "\${MOCK_EXISTING_RELEASE_ID}"
		else
			echo "\${MOCK_EXISTING_RELEASE_URL}"
		fi
		exit 0
	fi
	if [[ -f '${created_marker}' && "\$3" == "\$(cat '${created_marker}')" ]]; then
		if [[ "\$*" == *"--json id"* ]]; then
			echo "\${MOCK_CREATED_RELEASE_ID}"
		else
			echo "\${MOCK_CREATED_RELEASE_URL}"
		fi
		exit 0
	fi
	echo "release not found" >&2
	exit 1
fi

if [[ "\$1" == "release" && "\$2" == "create" ]]; then
	if [[ -n "\${MOCK_CREATE_ERROR:-}" ]]; then
		echo "\${MOCK_CREATE_ERROR}" >&2
		exit 1
	fi
	# Real gh rejects a create for a tag that already has a release.
	if [[ -n "\${MOCK_EXISTING_TAG:-}" && "\$3" == "\${MOCK_EXISTING_TAG}" ]]; then
		echo "HTTP 422: Validation Failed" >&2
		echo "Release.tag_name already exists" >&2
		exit 1
	fi
	printf '%s\n' "\$3" >'${created_marker}'
	echo "\${MOCK_CREATED_RELEASE_URL}"
	exit 0
fi

if [[ "\$1" == "release" && "\$2" == "upload" ]]; then
	if [[ -n "\${MOCK_UPLOAD_ERROR:-}" ]]; then
		echo "\${MOCK_UPLOAD_ERROR}" >&2
		exit 1
	fi
	exit 0
fi

exit 0
EOF
	chmod +x "${mock_bin}/gh"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

setup() {
	setup_temp_dir
	setup_github_env

	export MOCK_EXISTING_TAG=""
	export MOCK_EXISTING_RELEASE_ID="987654"
	export MOCK_EXISTING_RELEASE_URL="https://github.com/test-org/test-repo/releases/tag/v1.0.0"
	export MOCK_CREATED_RELEASE_ID="111222"
	export MOCK_CREATED_RELEASE_URL="https://github.com/test-org/test-repo/releases/tag/v1.0.0"
	export MOCK_CREATE_ERROR=""
	export MOCK_UPLOAD_ERROR=""

	mock_gh
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
	export MOCK_CREATE_ERROR="boom"

	TAG="v1.0.0" BODY="notes" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "Failed to create release"
}

@test "create-github-release: writes GitHub Actions outputs" {
	TAG="v1.0.0" BODY="notes" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	assert_file_contains "$GITHUB_OUTPUT" "release-url=https://github.com/test-org/test-repo/releases/tag/v1.0.0"
	assert_file_contains "$GITHUB_OUTPUT" "release-id=111222"
	assert_file_contains "$GITHUB_OUTPUT" "tag=v1.0.0"
}

# =============================================================================
# Rerun safety (#698)
# =============================================================================

@test "create-github-release: skips creation when release already exists (rerun)" {
	export MOCK_EXISTING_TAG="v1.0.0"
	export MOCK_EXISTING_RELEASE_ID="987654"
	export MOCK_EXISTING_RELEASE_URL="https://github.com/test-org/test-repo/releases/tag/v1.0.0"

	TAG="v1.0.0" BODY="notes" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "Release v1.0.0 already exists"
	assert_output --partial "skipping creation"

	refute_gh_called_with "release create"
}

@test "create-github-release: rerun still populates outputs from the existing release" {
	export MOCK_EXISTING_TAG="v1.0.0"
	export MOCK_EXISTING_RELEASE_ID="987654"
	export MOCK_EXISTING_RELEASE_URL="https://github.com/test-org/test-repo/releases/tag/v1.0.0"

	TAG="v1.0.0" BODY="notes" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	assert_output --partial "release-url=https://github.com/test-org/test-repo/releases/tag/v1.0.0"
	assert_output --partial "release-id=987654"

	assert_file_contains "$GITHUB_OUTPUT" "release-url=https://github.com/test-org/test-repo/releases/tag/v1.0.0"
	assert_file_contains "$GITHUB_OUTPUT" "release-id=987654"
	assert_file_contains "$GITHUB_OUTPUT" "tag=v1.0.0"
}

@test "create-github-release: a release for a different tag does not trigger the skip" {
	export MOCK_EXISTING_TAG="v0.9.0"

	TAG="v1.0.0" BODY="notes" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	refute_output --partial "skipping creation"

	assert_gh_called_with "release create v1.0.0"
}

# The release object and its assets are created by two separate API calls, so
# an attempt can die between them. Skipping creation must not also skip the
# uploads, or the rerun reports success on a release missing its artifacts.
@test "create-github-release: rerun re-uploads assets to the existing release" {
	local asset="${BATS_TEST_TMPDIR}/artifact.tar.gz"
	echo "data" >"$asset"
	export MOCK_EXISTING_TAG="v1.0.0"

	TAG="v1.0.0" BODY="notes" FILES="$asset" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success
	assert_output --partial "skipping creation"
	assert_output --partial "Uploading 1 asset(s) to existing release v1.0.0"

	refute_gh_called_with "release create"
	# --clobber: an asset the previous attempt did land must overwrite, not fail.
	assert_gh_called_with "release upload v1.0.0 --repo test-org/test-repo --clobber ${asset}"
}

@test "create-github-release: rerun with no requested assets skips the upload" {
	export MOCK_EXISTING_TAG="v1.0.0"

	TAG="v1.0.0" BODY="notes" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_success

	refute_gh_called_with "release upload"
}

@test "create-github-release: rerun fails when the asset upload fails" {
	local asset="${BATS_TEST_TMPDIR}/artifact.tar.gz"
	echo "data" >"$asset"
	export MOCK_EXISTING_TAG="v1.0.0"
	export MOCK_UPLOAD_ERROR="HTTP 502: Bad gateway"

	TAG="v1.0.0" BODY="notes" FILES="$asset" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "Failed to upload assets to existing release v1.0.0"
}

# The empty-match guard is a hard error about the caller's own build output, so
# it must not become a silent no-op just because the release already exists.
@test "create-github-release: rerun still fails when FILE_PATTERNS matches nothing" {
	export MOCK_EXISTING_TAG="v1.0.0"

	TAG="v1.0.0" BODY="notes" FILE_PATTERNS="${BATS_TEST_TMPDIR}/nope-*.tgz" \
		run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "No release assets matched FILE_PATTERNS"
}

@test "create-github-release: unrelated gh failure still exits non-zero" {
	export MOCK_CREATE_ERROR="HTTP 403: Resource not accessible by integration"

	TAG="v1.0.0" BODY="notes" run bash "${PROJECT_ROOT}/${SCRIPT}"
	assert_failure
	assert_output --partial "Failed to create release"
	assert_output --partial "Resource not accessible by integration"
	refute_output --partial "skipping creation"
}
