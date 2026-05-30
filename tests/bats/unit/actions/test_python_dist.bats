#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/python-dist.sh preflight step

load "../../../helpers/common"
load "../../../helpers/github_env"

setup() {
	setup_temp_dir
	setup_github_env
	export REPO_ROOT="${BATS_TEST_TMPDIR}/repo"
	export ORIGIN="${BATS_TEST_TMPDIR}/origin.git"
	mkdir -p "$REPO_ROOT"
	cd "$REPO_ROOT" || return 1
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

_write_pyproject() {
	local version="$1"
	cat >pyproject.toml <<EOF
[project]
name = "example"
version = "${version}"
EOF
}

_init_repo_on_main() {
	git init -b main
	git config user.email "test@example.com"
	git config user.name "Test User"
	git config tag.gpgSign false
	git config commit.gpgsign false
	_write_pyproject "$1"
	git add pyproject.toml
	git commit -m "init"
	git tag -m "test release" "v$1"
	git init --bare "$ORIGIN"
	git remote add origin "$ORIGIN"
	git push -u origin main
	git push origin "v$1"
}

_run_preflight() {
	local verify="${1:-true}"
	local ensure="${2:-true}"
	run env \
		STEP=preflight \
		WORKING_DIRECTORY=. \
		VERIFY_TAG_VERSION="$verify" \
		ENSURE_TAG_ON_DEFAULT_BRANCH="$ensure" \
		DEFAULT_BRANCH=main \
		GITHUB_REF_NAME="$GITHUB_REF_NAME" \
		GITHUB_REF="$GITHUB_REF" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"
}

_run_build() {
	local working_directory="${1:-.}"
	run env \
		STEP=build \
		WORKING_DIRECTORY="$working_directory" \
		GITHUB_WORKSPACE="$REPO_ROOT" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"
}

@test "python-dist preflight: passes when tag matches pyproject version on main" {
	_init_repo_on_main "1.2.3"
	export GITHUB_REF_NAME="v1.2.3"
	export GITHUB_REF="refs/tags/v1.2.3"

	_run_preflight true true

	assert_success
	assert_output --partial "Tag version matches pyproject.toml"
	assert_output --partial "Tag commit is on main"
}

@test "python-dist preflight: fails when tag version mismatches pyproject" {
	_init_repo_on_main "1.2.3"
	export GITHUB_REF_NAME="v9.9.9"
	export GITHUB_REF="refs/tags/v9.9.9"
	git tag -m "mismatch release" v9.9.9
	git push origin v9.9.9

	_run_preflight true false

	assert_failure
	assert_output --partial "Version mismatch: pyproject=1.2.3 tag=v9.9.9"
}

@test "python-dist preflight: fails when tag is not on default branch" {
	git init -b main
	git config user.email "test@example.com"
	git config user.name "Test User"
	git config tag.gpgSign false
	git config commit.gpgsign false
	_write_pyproject "2.0.0"
	git add pyproject.toml
	git commit -m "main init"

	git checkout -b feature
	echo "# feature" >>README.md
	git add README.md
	git commit -m "feature work"
	git tag -m "feature release" v2.0.0

	git init --bare "$ORIGIN"
	git remote add origin "$ORIGIN"
	git push origin main
	git push origin feature
	git push origin v2.0.0

	export GITHUB_REF_NAME="v2.0.0"
	export GITHUB_REF="refs/tags/v2.0.0"

	_run_preflight false true

	assert_failure
	assert_output --partial "Tag commit is not on main"
}

@test "python-dist build: refuses filesystem root WORKING_DIRECTORY" {
	_init_repo_on_main "1.0.0"

	_run_build /

	assert_failure
	assert_output --partial "unsafe WORKING_DIRECTORY"
}

@test "python-dist build: refuses home WORKING_DIRECTORY" {
	_init_repo_on_main "1.0.0"

	_run_build '~'

	assert_failure
	assert_output --partial "unsafe WORKING_DIRECTORY"
}

@test "python-dist build: refuses parent directory outside repository root" {
	_init_repo_on_main "1.0.0"

	_run_build ..

	assert_failure
	assert_output --partial "outside repository root"
}

@test "python-dist extract-dist-metadata: reads name and version from wheel" {
	mkdir -p dist
	touch dist/example-1.2.3-py3-none-any.whl

	run env \
		STEP=extract-dist-metadata \
		WORKING_DIRECTORY=. \
		bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"

	assert_success
	assert_equal "example" "$(get_github_output name)"
	assert_equal "1.2.3" "$(get_github_output version)"
}

@test "python-dist extract-dist-metadata: reads name and version from sdist" {
	mkdir -p dist
	touch dist/example-4.5.6.tar.gz

	run env \
		STEP=extract-dist-metadata \
		WORKING_DIRECTORY=. \
		bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"

	assert_success
	assert_equal "example" "$(get_github_output name)"
	assert_equal "4.5.6" "$(get_github_output version)"
}

@test "python-dist extract-dist-metadata: reads hyphenated name from sdist" {
	mkdir -p dist
	touch dist/my-package-1.2.3.tar.gz

	run env \
		STEP=extract-dist-metadata \
		WORKING_DIRECTORY=. \
		bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"

	assert_success
	assert_equal "my-package" "$(get_github_output name)"
	assert_equal "1.2.3" "$(get_github_output version)"
}

@test "python-dist extract-dist-metadata: prefers pyproject over wheel" {
	_write_pyproject "9.9.9"
	mkdir -p dist
	touch dist/example-1.2.3-py3-none-any.whl

	run env \
		STEP=extract-dist-metadata \
		WORKING_DIRECTORY=. \
		bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"

	assert_success
	assert_equal "example" "$(get_github_output name)"
	assert_equal "9.9.9" "$(get_github_output version)"
}

@test "python-dist summary: uses PACKAGE_NAME and PACKAGE_VERSION env" {
	mkdir -p dist
	touch dist/example-1.2.3-py3-none-any.whl

	run env \
		STEP=summary \
		WORKING_DIRECTORY=. \
		PACKAGE_NAME=example \
		PACKAGE_VERSION=1.2.3 \
		PUBLISHED=true \
		TEST_PYPI=false \
		bash "${PROJECT_ROOT}/scripts/ci/actions/python-dist.sh"

	assert_success
	local summary
	summary=$(get_github_step_summary)
	[[ "$summary" == *"| Package | example |"* ]]
	[[ "$summary" == *"| Version | 1.2.3 |"* ]]
	[[ "$summary" == *"https://pypi.org/project/example/1.2.3/"* ]]
}
