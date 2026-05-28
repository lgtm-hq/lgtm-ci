#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/release/verify-release-assets.sh

load "../../../helpers/common"

setup() {
	setup_temp_dir
	cd "${BATS_TEST_TMPDIR}" || exit 1
}

teardown() {
	teardown_temp_dir
}

@test "verify-release-assets: passes when files match glob" {
	mkdir -p dist
	echo "wheel" >dist/example-1.0.0-py3-none-any.whl

	run env FILES="dist/*" ARTIFACT_PATH=dist \
		bash "${PROJECT_ROOT}/scripts/ci/release/verify-release-assets.sh"

	assert_success
	assert_output --partial "Found 1 release asset(s)"
}

@test "verify-release-assets: fails when no files match glob" {
	mkdir -p dist

	run env FILES="dist/*" ARTIFACT_PATH=dist \
		bash "${PROJECT_ROOT}/scripts/ci/release/verify-release-assets.sh"

	assert_failure
	assert_output --partial "No release assets matched FILES patterns"
}

@test "verify-release-assets: skips blank pattern lines" {
	mkdir -p release
	echo "sdist" >release/example-1.0.0.tar.gz

	run env $'FILES=release/*\n\n' ARTIFACT_PATH=release \
		bash "${PROJECT_ROOT}/scripts/ci/release/verify-release-assets.sh"

	assert_success
	assert_output --partial "Found 1 release asset(s)"
}

@test "verify-release-assets: counts filenames with spaces" {
	mkdir -p dist
	echo "wheel" >"dist/example 1.0.0-py3-none-any.whl"

	run env FILES='dist/*' ARTIFACT_PATH=dist \
		bash "${PROJECT_ROOT}/scripts/ci/release/verify-release-assets.sh"

	assert_success
	assert_output --partial "Found 1 release asset(s)"
}

@test "verify-release-assets: matches multiple non-overlapping patterns" {
	mkdir -p dist release
	echo "wheel" >dist/example-1.0.0-py3-none-any.whl
	echo "sdist" >release/example-1.0.0.tar.gz

	run env $'FILES=dist/*\nrelease/*' ARTIFACT_PATH=. \
		bash "${PROJECT_ROOT}/scripts/ci/release/verify-release-assets.sh"

	assert_success
	assert_output --partial "Found 2 release asset(s)"
}

@test "verify-release-assets: ignores directories matched by glob" {
	mkdir -p dist/subdir
	echo "wheel" >dist/example-1.0.0-py3-none-any.whl

	run env FILES='dist/*' ARTIFACT_PATH=dist \
		bash "${PROJECT_ROOT}/scripts/ci/release/verify-release-assets.sh"

	assert_success
	assert_output --partial "Found 1 release asset(s)"
}
