#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/node/version.sh (#1372)

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	# shellcheck source=/dev/null
	source "${PROJECT_ROOT}/scripts/ci/lib/node/version.sh"
}

teardown() {
	teardown_temp_dir
}

@test "node_range_lowest_major: reduces common ranges" {
	[ "$(node_range_lowest_major '>=20 <23')" = "20" ]
	[ "$(node_range_lowest_major '^22.1')" = "22" ]
	[ "$(node_range_lowest_major '~18.17.0')" = "18" ]
	[ "$(node_range_lowest_major '20.x || 22')" = "20" ]
	[ "$(node_range_lowest_major '20 - 22')" = "20" ]
}

@test "node_range_lowest_major: ignores upper-bound-only and non-numeric ranges" {
	[ -z "$(node_range_lowest_major '<23')" ]
	[ -z "$(node_range_lowest_major '< 23')" ]
	[ -z "$(node_range_lowest_major '<= 22')" ]
	[ "$(node_range_lowest_major '>= 20 < 23')" = "20" ]
	[ "$(node_range_lowest_major '>20')" = "21" ]
	[ "$(node_range_lowest_major '> 20')" = "21" ]
	[ "$(node_range_lowest_major '>20.5.0')" = "20" ]
	[ "$(node_range_lowest_major '>=20')" = "20" ]
	[ -z "$(node_range_lowest_major '*')" ]
	[ -z "$(node_range_lowest_major '')" ]
}

@test "node_resolve_default_version: falls back to lts/*" {
	run node_resolve_default_version "$BATS_TEST_TMPDIR"
	assert_success
	assert_output "$(printf 'lts/*\tfallback')"
}

@test "node_resolve_default_version: skips blank .nvmrc and invalid package.json" {
	printf '\n  \n' >"$BATS_TEST_TMPDIR/.nvmrc"
	echo 'not json' >"$BATS_TEST_TMPDIR/package.json"
	run node_resolve_default_version "$BATS_TEST_TMPDIR"
	assert_success
	assert_line "$(printf 'lts/*\tfallback')"
	assert_output --partial "::warning::"
	assert_output --partial "could not be parsed"
}

@test "node_resolve_default_version: prefers .nvmrc, then .node-version" {
	echo "20" >"$BATS_TEST_TMPDIR/.node-version"
	run node_resolve_default_version "$BATS_TEST_TMPDIR"
	assert_output "$(printf '20\t.node-version')"
	echo "18" >"$BATS_TEST_TMPDIR/.nvmrc"
	run node_resolve_default_version "$BATS_TEST_TMPDIR"
	assert_output "$(printf '18\t.nvmrc')"
}
