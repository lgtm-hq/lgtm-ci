#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/security/format-security-comment.py

load "../../../helpers/common"

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

@test "format-security-comment: formats clean scan with no vulnerabilities" {
	local json_file="${BATS_TEST_TMPDIR}/osv-results.json"
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

	run python3 "${PROJECT_ROOT}/scripts/ci/security/format-security-comment.py" "$json_file"
	assert_success
	assert_output --partial "No security vulnerabilities found in dependencies."
	assert_output --partial "No suppressions configured."
}

@test "format-security-comment: formats vulnerability table" {
	local json_file="${BATS_TEST_TMPDIR}/osv-results.json"
	cat >"$json_file" <<'EOF'
{
  "results": [
    {
      "tool": "osv_scanner",
      "issues_count": 1,
      "issues": [
        {
          "message": "GHSA-xxxx-yyyy-zzzz in example-crate",
          "file": "Cargo.lock"
        }
      ],
      "ai_metadata": {
        "suppressions": []
      }
    }
  ]
}
EOF

	run python3 "${PROJECT_ROOT}/scripts/ci/security/format-security-comment.py" "$json_file"
	assert_success
	assert_output --partial "Vulnerability Report"
	assert_output --partial "GHSA-xxxx-yyyy-zzzz in example-crate"
	assert_output --partial "Cargo.lock"
}

@test "format-security-comment: fails on missing file" {
	run python3 "${PROJECT_ROOT}/scripts/ci/security/format-security-comment.py" \
		"${BATS_TEST_TMPDIR}/missing.json"
	assert_failure
}

@test "format-security-comment: reads TOML suppressions without ignoreUntil" {
	local json_file="${BATS_TEST_TMPDIR}/osv-results.json"
	cat >"$json_file" <<'EOF'
{
  "results": [
    {
      "tool": "osv_scanner",
      "issues_count": 0,
      "success": true
    }
  ]
}
EOF

	cat >"${BATS_TEST_TMPDIR}/.osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-xxxx-yyyy-zzzz"
reason = "No fix available"
EOF

	run bash -c "cd '${BATS_TEST_TMPDIR}' && python3 '${PROJECT_ROOT}/scripts/ci/security/format-security-comment.py' osv-results.json"
	assert_success
	assert_output --partial "GHSA-xxxx-yyyy-zzzz"
	assert_output --partial "No fix available"
	refute_output --partial "No suppressions configured."
}
