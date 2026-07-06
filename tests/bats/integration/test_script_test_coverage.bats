#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the script-to-BATS-test coverage ratchet

load "../../helpers/common"

VALIDATOR="${PROJECT_ROOT}/scripts/ci/quality/validate-script-test-coverage.sh"

setup() {
	setup_temp_dir

	FIXTURE_SCRIPTS="${BATS_TEST_TMPDIR}/scripts/ci"
	FIXTURE_TESTS="${BATS_TEST_TMPDIR}/tests"
	FIXTURE_ALLOWLIST="${BATS_TEST_TMPDIR}/allowlist.txt"
	mkdir -p "${FIXTURE_SCRIPTS}" "${FIXTURE_TESTS}"
	: >"${FIXTURE_ALLOWLIST}"
}

teardown() {
	teardown_temp_dir
}

run_fixture_validator() {
	SCRIPTS_DIR="${FIXTURE_SCRIPTS}" \
		TESTS_DIR="${FIXTURE_TESTS}" \
		ALLOWLIST_FILE="${FIXTURE_ALLOWLIST}" \
		run "${VALIDATOR}"
}

@test "script-test-coverage: passes on repository state" {
	run "${VALIDATOR}"
	assert_success
	assert_output --partial "OK:"
}

@test "script-test-coverage: repository allowlist has no duplicates" {
	local allowlist="${PROJECT_ROOT}/scripts/ci/quality/script-test-coverage-allowlist.txt"
	assert_file_exists "$allowlist"
	run bash -c "grep -vE '^\s*(#|\$)' '$allowlist' | sort | uniq -d"
	refute_output
}

@test "script-test-coverage: flags new untested script" {
	mkdir -p "${FIXTURE_SCRIPTS}/actions"
	printf '#!/usr/bin/env bash\n' >"${FIXTURE_SCRIPTS}/actions/example-untested.sh"

	run_fixture_validator
	assert_failure
	assert_output --partial "new untested script"
	assert_output --partial "actions/example-untested.sh"
}

@test "script-test-coverage: passes when untested script is allowlisted" {
	mkdir -p "${FIXTURE_SCRIPTS}/actions"
	printf '#!/usr/bin/env bash\n' >"${FIXTURE_SCRIPTS}/actions/example-untested.sh"
	echo "actions/example-untested.sh" >"${FIXTURE_ALLOWLIST}"

	run_fixture_validator
	assert_success
	assert_output --partial "1 allowlisted"
}

@test "script-test-coverage: passes when script basename appears in a bats test" {
	mkdir -p "${FIXTURE_SCRIPTS}/actions" "${FIXTURE_TESTS}/bats/unit"
	printf '#!/usr/bin/env bash\n' >"${FIXTURE_SCRIPTS}/actions/example-tested.sh"
	echo '# exercises example-tested.sh' >"${FIXTURE_TESTS}/bats/unit/test_example.bats"

	run_fixture_validator
	assert_success
	assert_output --partial "1/1 entrypoints tested"
}

@test "script-test-coverage: ignores basename mentions outside .bats files" {
	mkdir -p "${FIXTURE_SCRIPTS}/actions" "${FIXTURE_TESTS}/bats/unit"
	printf '#!/usr/bin/env bash\n' >"${FIXTURE_SCRIPTS}/actions/example-untested.sh"
	echo '# mentions example-untested.sh' >"${FIXTURE_TESTS}/bats/unit/notes.txt"

	run_fixture_validator
	assert_failure
	assert_output --partial "new untested script"
}

@test "script-test-coverage: flags stale allowlist entry for tested script" {
	mkdir -p "${FIXTURE_SCRIPTS}/actions" "${FIXTURE_TESTS}/bats/unit"
	printf '#!/usr/bin/env bash\n' >"${FIXTURE_SCRIPTS}/actions/example-tested.sh"
	echo '# exercises example-tested.sh' >"${FIXTURE_TESTS}/bats/unit/test_example.bats"
	echo "actions/example-tested.sh" >"${FIXTURE_ALLOWLIST}"

	run_fixture_validator
	assert_failure
	assert_output --partial "stale allowlist entry (script now has a BATS test"
}

@test "script-test-coverage: flags stale allowlist entry for removed script" {
	echo "actions/removed-script.sh" >"${FIXTURE_ALLOWLIST}"

	run_fixture_validator
	assert_failure
	assert_output --partial "stale allowlist entry (script does not exist"
}

@test "script-test-coverage: excludes lib/ sourced files" {
	mkdir -p "${FIXTURE_SCRIPTS}/lib/release"
	printf '#!/usr/bin/env bash\n' >"${FIXTURE_SCRIPTS}/lib/sourced.sh"
	printf '#!/usr/bin/env bash\n' >"${FIXTURE_SCRIPTS}/lib/release/sourced-nested.sh"

	run_fixture_validator
	assert_success
	assert_output --partial "0 allowlisted"
}

@test "script-test-coverage: tolerates trailing slash in SCRIPTS_DIR override" {
	mkdir -p "${FIXTURE_SCRIPTS}/actions"
	printf '#!/usr/bin/env bash\n' >"${FIXTURE_SCRIPTS}/actions/example-untested.sh"
	echo "actions/example-untested.sh" >"${FIXTURE_ALLOWLIST}"

	SCRIPTS_DIR="${FIXTURE_SCRIPTS}/" \
		TESTS_DIR="${FIXTURE_TESTS}" \
		ALLOWLIST_FILE="${FIXTURE_ALLOWLIST}" \
		run "${VALIDATOR}"
	assert_success
	assert_output --partial "1 allowlisted"
}

@test "script-test-coverage: ignores comments and blank lines in allowlist" {
	mkdir -p "${FIXTURE_SCRIPTS}/actions"
	printf '#!/usr/bin/env bash\n' >"${FIXTURE_SCRIPTS}/actions/example-untested.sh"
	cat >"${FIXTURE_ALLOWLIST}" <<'EOF'
# comment line

actions/example-untested.sh  # trailing comment
EOF

	run_fixture_validator
	assert_success
}
