#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/resolve-multi-ecosystem-version.sh

load "../../../helpers/common"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/resolve-multi-ecosystem-version.sh"

setup() {
	setup_temp_dir
	setup_github_env
	cd "$BATS_TEST_TMPDIR" || return 1
	git init -q
	git config user.email "test@example.com"
	git config user.name "Test"
	printf 'init\n' >README.md
	git add README.md
	git commit -qm "chore: init"
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

@test "resolve-multi-ecosystem-version: explicit bump sets next-version" {
	run env BUMP_MODE=explicit EXPLICIT_VERSION=2.0.0 bash "$SCRIPT"
	assert_success
	assert_output --partial "next-version=2.0.0"
	assert_output --partial "bump-type=explicit"
	assert_output --partial "release-needed=true"
}

@test "resolve-multi-ecosystem-version: strips v prefix on explicit" {
	run env BUMP_MODE=explicit EXPLICIT_VERSION=v1.2.3 bash "$SCRIPT"
	assert_success
	assert_output --partial "next-version=1.2.3"
}

@test "resolve-multi-ecosystem-version: applies prerelease-tag on explicit" {
	run env BUMP_MODE=explicit EXPLICIT_VERSION=1.2.3 PRERELEASE_TAG=rc.1 bash "$SCRIPT"
	assert_success
	assert_output --partial "next-version=1.2.3-rc.1"
}

@test "resolve-multi-ecosystem-version: rejects missing explicit version" {
	run env BUMP_MODE=explicit EXPLICIT_VERSION= bash "$SCRIPT"
	assert_failure
	assert_output --partial "EXPLICIT_VERSION is required"
}

@test "resolve-multi-ecosystem-version: rejects invalid bump mode" {
	run env BUMP_MODE=maybe bash "$SCRIPT"
	assert_failure
	assert_output --partial "BUMP_MODE must be"
}

@test "resolve-multi-ecosystem-version: rejects prerelease on already-prerelease" {
	run env BUMP_MODE=explicit EXPLICIT_VERSION=1.0.0-alpha PRERELEASE_TAG=rc.1 bash "$SCRIPT"
	assert_failure
	assert_output --partial "already has a prerelease"
}

@test "resolve-multi-ecosystem-version: auto-from-commits with no releasable history" {
	run env BUMP_MODE=auto-from-commits MAX_BUMP=minor bash "$SCRIPT"
	assert_success
	assert_output --partial "release-needed=false"
}
