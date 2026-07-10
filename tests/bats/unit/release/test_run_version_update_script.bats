#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/run-version-update-script.sh

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/run-version-update-script.sh"

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "run-version-update-script.sh: fails without SCRIPT_PATH" {
	run env -u SCRIPT_PATH NEXT_VERSION=1.0.0 bash "$SCRIPT"
	assert_failure
	assert_output --partial "SCRIPT_PATH is required"
}

@test "run-version-update-script.sh: fails without NEXT_VERSION" {
	run env -u NEXT_VERSION SCRIPT_PATH=/bin/true bash "$SCRIPT"
	assert_failure
	assert_output --partial "NEXT_VERSION is required"
}

@test "run-version-update-script.sh: executes SCRIPT_PATH" {
	local updater="${BATS_TEST_TMPDIR}/updater.sh"
	cat >"$updater" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'updated-to=%s\n' "${NEXT_VERSION}"
EOF
	chmod +x "$updater"

	run env SCRIPT_PATH="$updater" NEXT_VERSION=9.9.9 bash "$SCRIPT"
	assert_success
	assert_output --partial "updated-to=9.9.9"
}

@test "run-version-update-script.sh: propagates updater failure" {
	local updater="${BATS_TEST_TMPDIR}/fail.sh"
	cat >"$updater" <<'EOF'
#!/usr/bin/env bash
echo boom >&2
exit 7
EOF
	chmod +x "$updater"

	run env SCRIPT_PATH="$updater" NEXT_VERSION=1.0.0 bash "$SCRIPT"
	assert_failure
	assert_equal "$status" 7
	assert_output --partial "boom"
}
