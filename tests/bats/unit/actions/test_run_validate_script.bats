#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/run-validate-script.sh

load "../../../helpers/common"
load "../../../helpers/github_env"

setup() {
	setup_temp_dir
	setup_github_env
	export WORK="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$WORK"
	cd "$WORK" || return 1
}

teardown() {
	teardown_github_env
	teardown_temp_dir
}

_validate() { # script-body
	printf '#!/usr/bin/env bash\n%s\n' "$1" >"${WORK}/check.sh"
	run env SCRIPT_PATH="check.sh" VALIDATION_NAME="Lint" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/run-validate-script.sh"
}

@test "run-validate-script: a passing script writes no report" {
	_validate 'echo fine'

	assert_success
	assert_github_output "status" "passed"
	assert_file_not_exists "${WORK}/validation-report.md"
}

@test "run-validate-script: the failure report carries no lgtm-ci marker (#1674)" {
	_validate 'echo "broken <!-- lgtm-ci:other -->"; exit 3'

	assert_success
	assert_github_output "status" "failed"
	assert_github_output "exit-code" "3"
	run head -1 "${WORK}/validation-report.md"
	assert_output "## Lint Failed"
	run grep -c '^<!-- lgtm-ci:' "${WORK}/validation-report.md"
	assert_output "0"
}
