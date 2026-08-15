#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/docker/free-disk-space.sh

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/docker/free-disk-space.sh"

setup() {
	setup_temp_dir
	save_path
	export SCRIPT
	export AGENT_TOOLSDIRECTORY="${BATS_TEST_TMPDIR}/toolcache-missing"
	export FREE_DISK_FIXED_PATHS=""
	export FREE_DISK_TOOLCACHE_NAMES=""
}

teardown() {
	restore_path
	teardown_temp_dir
}

_mock_df() {
	local before="${1:-Filesystem Size Used Avail Use% Mounted on
/dev/disk1 100G 80G 20G 80% /}"
	local after="${2:-$before}"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	local before_file="${mock_bin}/.df_before"
	local after_file="${mock_bin}/.df_after"
	local state_file="${mock_bin}/.df_state"
	printf '%s\n' "$before" >"$before_file"
	printf '%s\n' "$after" >"$after_file"
	echo 0 >"$state_file"

	cat >"${mock_bin}/df" <<EOF
#!/usr/bin/env bash
state_file='${state_file}'
count="\$(cat "\$state_file")"
count=\$((count + 1))
echo "\$count" >"\$state_file"
if [[ "\$count" -le 2 ]]; then
	cat '${before_file}'
else
	cat '${after_file}'
fi
exit 0
EOF
	chmod +x "${mock_bin}/df"
	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

_mock_rm_record() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	local calls_file="${BATS_TEST_TMPDIR}/mock_calls_rm"
	: >"$calls_file"
	cat >"${mock_bin}/rm" <<EOF
#!/usr/bin/env bash
echo "\$@" >> '${calls_file}'
exit 0
EOF
	chmod +x "${mock_bin}/rm"
	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

@test "free-disk-space.sh: script is executable" {
	[[ -x "$SCRIPT" ]]
}

@test "free-disk-space.sh: no-op when fixed paths and toolcache are missing" {
	_mock_df
	_mock_rm_record
	export FREE_DISK_FIXED_PATHS="/definitely/missing/dotnet /definitely/missing/android"
	export AGENT_TOOLSDIRECTORY="${BATS_TEST_TMPDIR}/no-such-toolcache"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "=== Disk usage (before) ==="
	assert_output --partial "=== Disk usage (after) ==="
	assert_output --partial "Skipping missing path: /definitely/missing/dotnet"
	assert_output --partial "Skipping missing path: /definitely/missing/android"
	assert_output --partial "Skipping toolcache (not present)"
	# Mocked rm must not be invoked for missing paths.
	[[ ! -s "${BATS_TEST_TMPDIR}/mock_calls_rm" ]]
}

@test "free-disk-space.sh: removes existing unused toolchains and logs reclaimed space" {
	_mock_df \
		"Filesystem     1K-blocks    Used Available Use% Mounted on
/dev/root        100000000 80000000  20000000  80% /" \
		"Filesystem     1K-blocks    Used Available Use% Mounted on
/dev/root        100000000 70000000  30000000  70% /"
	_mock_rm_record

	local dotnet android
	dotnet="${BATS_TEST_TMPDIR}/dotnet"
	android="${BATS_TEST_TMPDIR}/android"
	mkdir -p "$dotnet" "$android"
	echo payload >"${dotnet}/file"
	echo payload >"${android}/file"
	export FREE_DISK_FIXED_PATHS="${dotnet} ${android}"
	export AGENT_TOOLSDIRECTORY="${BATS_TEST_TMPDIR}/no-such-toolcache"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Removing ${dotnet}"
	assert_output --partial "Removed ${dotnet}"
	assert_output --partial "Removing ${android}"
	assert_output --partial "Removed ${android}"
	assert_output --partial "Available space change:"
	assert_file_contains_literal "${BATS_TEST_TMPDIR}/mock_calls_rm" "-rf -- ${dotnet}"
	assert_file_contains_literal "${BATS_TEST_TMPDIR}/mock_calls_rm" "-rf -- ${android}"
}

@test "free-disk-space.sh: removes unused toolcache entries and skips missing ones" {
	_mock_df
	_mock_rm_record

	local toolcache
	toolcache="${BATS_TEST_TMPDIR}/toolcache"
	mkdir -p "${toolcache}/CodeQL" "${toolcache}/go"
	echo unused >"${toolcache}/CodeQL/x"
	echo unused >"${toolcache}/go/x"
	export FREE_DISK_FIXED_PATHS=""
	export AGENT_TOOLSDIRECTORY="$toolcache"
	export FREE_DISK_TOOLCACHE_NAMES="CodeQL go Python"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Removing ${toolcache}/CodeQL"
	assert_output --partial "Removing ${toolcache}/go"
	assert_output --partial "Skipping missing path: ${toolcache}/Python"
	assert_file_contains_literal "${BATS_TEST_TMPDIR}/mock_calls_rm" "-rf -- ${toolcache}/CodeQL"
	assert_file_contains_literal "${BATS_TEST_TMPDIR}/mock_calls_rm" "-rf -- ${toolcache}/go"
	if grep -qF "Python" "${BATS_TEST_TMPDIR}/mock_calls_rm"; then
		echo "rm was called for missing Python toolcache entry" >&2
		return 1
	fi
}

@test "free-disk-space.sh: prints df before and after" {
	_mock_df "BEFORE-DF" "AFTER-DF"
	_mock_rm_record
	export FREE_DISK_FIXED_PATHS=""
	export AGENT_TOOLSDIRECTORY="${BATS_TEST_TMPDIR}/no-such-toolcache"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "BEFORE-DF"
	assert_output --partial "AFTER-DF"
}
