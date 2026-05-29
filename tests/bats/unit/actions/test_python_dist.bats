#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/python-dist.sh preflight step

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export REPO_ROOT="${BATS_TEST_TMPDIR}/repo"
	export ORIGIN="${BATS_TEST_TMPDIR}/origin.git"
	mkdir -p "$REPO_ROOT"
	cd "$REPO_ROOT" || return 1
}

teardown() {
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
