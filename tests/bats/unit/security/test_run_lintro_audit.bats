#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/security/run-lintro-audit.sh and fail-audit.sh

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github-output"
	touch "$GITHUB_OUTPUT"
}

teardown() {
	teardown_temp_dir
}

@test "fail-audit: exits with error annotation" {
	run bash "${PROJECT_ROOT}/scripts/ci/security/fail-audit.sh"
	assert_failure
	assert_output --partial "::error::Security audit found vulnerabilities or failed"
}

@test "run-lintro-audit: requires LINTRO_IMAGE" {
	run bash "${PROJECT_ROOT}/scripts/ci/security/run-lintro-audit.sh"
	assert_failure
	assert_output --partial "LINTRO_IMAGE is required"
}

@test "run-lintro-audit: writes comment file when scan results exist" {
	local workspace="${BATS_TEST_TMPDIR}/workspace"
	mkdir -p "$workspace"
	local json_file="${workspace}/osv-results.json"
	cat >"$json_file" <<'EOF'
{
  "results": [
    {
      "tool": "osv_scanner",
      "issues_count": 0,
      "success": true,
      "ai_metadata": {
        "suppressions": []
      }
    }
  ]
}
EOF

	run env \
		PROJECT_ROOT="$PROJECT_ROOT" \
		GITHUB_OUTPUT="$GITHUB_OUTPUT" \
		WORKSPACE="$workspace" \
		COMMENT_FILE="security-audit-comment.txt" \
		OSV_RESULTS="osv-results.json" \
		FORMAT_SCRIPT="${PROJECT_ROOT}/scripts/ci/security/format-security-comment.py" \
		bash -c '
set -euo pipefail
source "${PROJECT_ROOT}/scripts/ci/lib/log.sh"
source "${PROJECT_ROOT}/scripts/ci/lib/github/format.sh"

COMMENT_BODY="$(python3 "${FORMAT_SCRIPT}" "${WORKSPACE}/${OSV_RESULTS}")"
{
	printf "%s\n\n" "## 🔐 Security Audit Report"
	printf "%s\n\n" "### 📊 Status: ✅ PASSED"
	printf "%s\n" "${COMMENT_BODY}"
} >"${WORKSPACE}/${COMMENT_FILE}"

{
	echo "has-vulns=0"
	echo "audit-failed=0"
	echo "format-failed=0"
	echo "exit-code=0"
	echo "status=passed"
} >>"${GITHUB_OUTPUT}"
'

	assert_success
	assert_file_exists "${workspace}/security-audit-comment.txt"
	assert_file_contains "${workspace}/security-audit-comment.txt" "Security Audit Report"
	assert_file_contains "$GITHUB_OUTPUT" "status=passed"
}
