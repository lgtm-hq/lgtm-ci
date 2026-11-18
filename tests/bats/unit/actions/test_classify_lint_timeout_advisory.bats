#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/classify-lint-timeout-advisory.sh (#1624)

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/classify-lint-timeout-advisory.sh"
	export REPORT="${BATS_TEST_TMPDIR}/results.json"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/gh_out"
	: >"${GITHUB_OUTPUT}"
}

teardown() {
	teardown_temp_dir
}

@test "classify-lint-timeout-advisory.sh: passes the classifier's verdict through" {
	cat >"$REPORT" <<'EOF'
{"summary": {"total_issues": 0, "timed_out_tools": ["mypy"]},
 "results": [{"tool": "mypy", "success": false, "issues_count": 0, "timed_out": true}]}
EOF
	run bash "$SCRIPT"
	assert_success
	run grep -c '^timeout-flake=' "$GITHUB_OUTPUT"
	assert_output "1"
}

@test "classify-lint-timeout-advisory.sh: a classifier failure is a warning, not a failure" {
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	printf '#!/usr/bin/env bash\nexit 7\n' >"${BATS_TEST_TMPDIR}/bin/python3"
	chmod +x "${BATS_TEST_TMPDIR}/bin/python3"

	run env PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" bash "$SCRIPT"
	assert_success
	assert_output "::warning::lint timeout classification failed"
}

@test "classify-lint-timeout-advisory.sh: runs the classifier next to it with the report" {
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"%s/argv"\n' "$BATS_TEST_TMPDIR" \
		>"${BATS_TEST_TMPDIR}/bin/python3"
	chmod +x "${BATS_TEST_TMPDIR}/bin/python3"

	run env PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" bash "$SCRIPT"
	assert_success
	run cat "${BATS_TEST_TMPDIR}/argv"
	assert_line --index 0 "${PROJECT_ROOT}/scripts/ci/actions/classify-lint-timeout.py"
	assert_line --index 1 "--report"
	assert_line --index 2 "$REPORT"
}
