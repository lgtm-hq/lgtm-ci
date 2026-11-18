#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/pause.sh (#1624)

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/pause.sh"

setup() {
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	# Record the argument instead of waiting.
	printf '#!/usr/bin/env bash\necho "sleep $*"\n' >"${BATS_TEST_TMPDIR}/bin/sleep"
	chmod +x "${BATS_TEST_TMPDIR}/bin/sleep"
	export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
}

@test "pause.sh: waits the given number of seconds" {
	run env PAUSE_SECONDS=30 bash "$SCRIPT"
	assert_success
	assert_output "sleep 30"
}

@test "pause.sh: reads a leading zero as decimal" {
	run env PAUSE_SECONDS=010 bash "$SCRIPT"
	assert_success
	assert_output "sleep 10"
}

@test "pause.sh: accepts zero" {
	run env PAUSE_SECONDS=0 bash "$SCRIPT"
	assert_success
	assert_output "sleep 0"
}

@test "pause.sh: refuses a value that is not whole seconds" {
	for value in 1.5 -1 abc '1; true' ''; do
		run env PAUSE_SECONDS="$value" bash "$SCRIPT"
		assert_failure
		refute_output --partial "sleep "
	done
}

@test "pause.sh: refuses more than ten minutes" {
	run env PAUSE_SECONDS=601 bash "$SCRIPT"
	assert_failure
	assert_output --partial "from 0 to 600"
}

@test "pause.sh: fails without PAUSE_SECONDS" {
	run env -u PAUSE_SECONDS bash "$SCRIPT"
	assert_failure
	assert_output --partial "PAUSE_SECONDS is required"
}
