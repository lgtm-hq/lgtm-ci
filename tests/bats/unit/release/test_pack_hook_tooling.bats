#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/pack-hook-tooling.sh

load "../../../helpers/common"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/pack-hook-tooling.sh"

setup() {
	setup_temp_dir
	setup_github_env
	export RUNNER_TEMP="${BATS_TEST_TMPDIR}/runner-temp"
	mkdir -p "$RUNNER_TEMP"
	TOOLING="${BATS_TEST_TMPDIR}/tooling"
	mkdir -p "${TOOLING}/scripts/ci/release" "${TOOLING}/scripts/ci/lib" \
		"${TOOLING}/.github/actions/checkout-and-harden" "${TOOLING}/docs"
	printf '#!/usr/bin/env bash\necho hook\n' >"${TOOLING}/scripts/ci/release/run.sh"
	chmod +x "${TOOLING}/scripts/ci/release/run.sh"
	printf 'log() { :; }\n' >"${TOOLING}/scripts/ci/lib/log.sh"
	printf 'guard\n' >"${TOOLING}/.github/actions/checkout-and-harden/action.yml"
	printf 'docs\n' >"${TOOLING}/docs/README.md"
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

pack() {
	run env TOOLING_DIR="$TOOLING" bash "$SCRIPT"
}

@test "pack-hook-tooling: fails without RUNNER_TEMP" {
	run env -u RUNNER_TEMP TOOLING_DIR="$TOOLING" bash "$SCRIPT"
	assert_failure
	assert_output --partial "RUNNER_TEMP is required"
}

@test "pack-hook-tooling: packs exactly scripts/ci" {
	pack
	assert_success
	local tarball
	tarball="$(get_github_output "path")"
	[[ "$tarball" == "${RUNNER_TEMP}/hook-tooling/hook-tooling.tar.gz" ]]
	run bash -c "tar -tzf '$tarball' | grep -v '/$' | LC_ALL=C sort"
	assert_success
	assert_output "$(printf '%s\n' scripts/ci/lib/log.sh scripts/ci/release/run.sh)"
}

@test "pack-hook-tooling: keeps the executable bit" {
	pack
	assert_success
	local dest="${BATS_TEST_TMPDIR}/extract"
	mkdir -p "$dest"
	tar -xzf "$(get_github_output "path")" --no-same-owner -C "$dest"
	[[ -x "${dest}/scripts/ci/release/run.sh" ]]
	[[ ! -x "${dest}/scripts/ci/lib/log.sh" ]]
}

@test "pack-hook-tooling: the digest output is the tarball's SHA-256" {
	pack
	assert_success
	local digest tarball
	digest="$(get_github_output "digest")"
	tarball="$(get_github_output "path")"
	[[ "$digest" =~ ^[0-9a-f]{64}$ ]]
	run bash -c "printf '%s  %s\n' '$digest' '$tarball' | shasum -a 256 -c -"
	assert_success
}

@test "pack-hook-tooling: fails when a packed path is missing" {
	rm -rf "${TOOLING}/scripts/ci"
	pack
	assert_failure
	assert_output --partial "tooling path missing"
	assert_output --partial "scripts/ci"
	run cat "$GITHUB_OUTPUT"
	refute_output --partial "digest="
}

@test "pack-hook-tooling: fails when the tooling directory is missing" {
	run env TOOLING_DIR="${BATS_TEST_TMPDIR}/absent" bash "$SCRIPT"
	assert_failure
	assert_output --partial "tooling directory not found"
}
