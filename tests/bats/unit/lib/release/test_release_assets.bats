#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/release/assets.sh

load "../../../../helpers/common"

setup() {
	setup_temp_dir
	cd "${BATS_TEST_TMPDIR}" || exit 1
	# shellcheck source=../../../../../scripts/ci/lib/release/assets.sh
	source "${PROJECT_ROOT}/scripts/ci/lib/release/assets.sh"
}

teardown() {
	teardown_temp_dir
}

@test "release_collect_asset_files: preserves caller nullglob when already enabled" {
	mkdir -p dist
	shopt -s nullglob

	run bash -c '
		shopt -s nullglob
		source "'"${PROJECT_ROOT}"'/scripts/ci/lib/release/assets.sh"
		release_collect_asset_files "missing/*" >/dev/null
		if shopt -q nullglob; then
			echo still-on
		else
			echo turned-off
		fi
	'

	assert_success
	assert_output "still-on"
}

@test "release_collect_asset_files: leaves nullglob disabled when caller had it off" {
	run bash -c '
		shopt -u nullglob 2>/dev/null || true
		source "'"${PROJECT_ROOT}"'/scripts/ci/lib/release/assets.sh"
		release_collect_asset_files "missing/*" >/dev/null
		if shopt -q nullglob; then
			echo turned-on
		else
			echo still-off
		fi
	'

	assert_success
	assert_output "still-off"
}
