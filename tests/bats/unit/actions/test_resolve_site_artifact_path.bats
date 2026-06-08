#!/usr/bin/env bats
# SPDX-License-Identifier: MIT

load "../../../helpers/common"

setup() {
	export SCRIPT="$PROJECT_ROOT/scripts/ci/actions/resolve-site-artifact-path.sh"
	setup_temp_dir
	export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
	: >"$GITHUB_OUTPUT"
}

teardown() {
	teardown_temp_dir
}

@test "resolve-site-artifact-path prefers explicit site-artifact-path" {
	export SITE_ARTIFACT_PATH="apps/site/dist"
	export LYCHEE_PATHS="other/dist,ignored"
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	grep -q '^path=apps/site/dist$' "$GITHUB_OUTPUT"
}

@test "resolve-site-artifact-path uses first comma-separated lychee path" {
	unset SITE_ARTIFACT_PATH
	export LYCHEE_PATHS=" apps/site/dist , apps/other/dist "
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	grep -q '^path=apps/site/dist$' "$GITHUB_OUTPUT"
}

@test "resolve-site-artifact-path ignores whitespace-only site-artifact-path" {
	export SITE_ARTIFACT_PATH="   "
	export LYCHEE_PATHS="apps/site/dist"
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	grep -q '^path=apps/site/dist$' "$GITHUB_OUTPUT"
}

@test "resolve-site-artifact-path defaults to dot when lychee-paths unset" {
	unset SITE_ARTIFACT_PATH
	unset LYCHEE_PATHS
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	grep -q '^path=\.$' "$GITHUB_OUTPUT"
}

@test "resolve-site-artifact-path defaults to dot for empty lychee-paths" {
	unset SITE_ARTIFACT_PATH
	export LYCHEE_PATHS=""
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	grep -q '^path=\.$' "$GITHUB_OUTPUT"
}

@test "resolve-site-artifact-path defaults to dot for whitespace-only lychee-paths" {
	unset SITE_ARTIFACT_PATH
	export LYCHEE_PATHS="   "
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	grep -q '^path=\.$' "$GITHUB_OUTPUT"
}

@test "resolve-site-artifact-path uses single lychee path without comma" {
	unset SITE_ARTIFACT_PATH
	export LYCHEE_PATHS="apps/site/dist"
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	grep -q '^path=apps/site/dist$' "$GITHUB_OUTPUT"
}
