#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/classify-lint-timeout.py
#
# The classifier decides whether a failing lint run failed ONLY because a tool
# timed out. It must fail closed: every case that does not positively prove a
# timeout-with-zero-findings has to report timeout-flake=false, because a
# false 'true' silently turns a genuine finding green.

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/classify-lint-timeout.py"
	export REPORT="${BATS_TEST_TMPDIR}/results.json"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/gh_out"
	: >"${GITHUB_OUTPUT}"
}

teardown() {
	teardown_temp_dir
}

# Writes a report body to $REPORT.
write_report() {
	cat >"${REPORT}"
}

# --------------------------------------------------------------------------
# The one case that may report true
# --------------------------------------------------------------------------

@test "classify-lint-timeout.py: timeout with zero issues is a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 0, "total_fixed": 0, "timed_out_tools": ["mypy"]},
  "results": [
    {"tool": "mypy", "success": false, "issues_count": 0, "skipped": false,
     "timed_out": true,
     "output": "mypy execution timed out (120.0s limit exceeded)."},
    {"tool": "ruff", "success": true, "issues_count": 0, "skipped": false,
     "timed_out": false, "output": ""}
  ]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=true"
	assert_output --partial "timed-out-tools=mypy"
	assert_file_contains "${GITHUB_OUTPUT}" "timeout-flake=true"
	assert_file_contains "${GITHUB_OUTPUT}" "timed-out-tools=mypy"
}

@test "classify-lint-timeout.py: multiple timed-out tools are listed" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 0, "timed_out_tools": ["mypy", "prettier"]},
  "results": [
    {"tool": "mypy", "success": false, "issues_count": 0, "timed_out": true},
    {"tool": "prettier", "success": false, "issues_count": 0,
     "timed_out": true}
  ]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=true"
	assert_output --partial "timed-out-tools=mypy,prettier"
}

@test "classify-lint-timeout.py: a skipped tool does not block the verdict" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 0, "timed_out_tools": ["mypy"]},
  "results": [
    {"tool": "mypy", "success": false, "issues_count": 0, "timed_out": true},
    {"tool": "hadolint", "success": false, "issues_count": 0,
     "skipped": true, "skip_reason": "no Dockerfile", "timed_out": false}
  ]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=true"
}

# --------------------------------------------------------------------------
# Fail-closed: genuine findings
# --------------------------------------------------------------------------

@test "classify-lint-timeout.py: timeout alongside issues is not a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 3, "timed_out_tools": ["mypy"]},
  "results": [
    {"tool": "mypy", "success": false, "issues_count": 0, "timed_out": true},
    {"tool": "ruff", "success": false, "issues_count": 3, "timed_out": false}
  ]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
	assert_output --partial "timed-out-tools="
	refute_output --partial "timeout-flake=true"
}

# The summary can disagree with the per-tool objects. Trusting summary alone
# would green a run in which the timed-out tool did report findings.
@test "classify-lint-timeout.py: timed-out tool reporting issues is not a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 0, "timed_out_tools": ["prettier"]},
  "results": [
    {"tool": "prettier", "success": false, "issues_count": 2,
     "timed_out": true}
  ]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

@test "classify-lint-timeout.py: per-tool issues outside the summary are not a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 0, "timed_out_tools": ["mypy"]},
  "results": [
    {"tool": "mypy", "success": false, "issues_count": 0, "timed_out": true},
    {"tool": "ruff", "success": true, "issues_count": 0, "timed_out": false,
     "issues": [{"file": "a.py", "line": 1, "code": "E501",
                 "message": "too long"}]}
  ]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

# --------------------------------------------------------------------------
# Fail-closed: non-timeout failures
# --------------------------------------------------------------------------

@test "classify-lint-timeout.py: non-timeout tool failure is not a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 0, "timed_out_tools": ["mypy"]},
  "results": [
    {"tool": "mypy", "success": false, "issues_count": 0, "timed_out": true},
    {"tool": "ruff", "success": false, "issues_count": 0, "timed_out": false,
     "output": "ruff: command not found"}
  ]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
	assert_output --partial "timed-out-tools="
}

@test "classify-lint-timeout.py: a crashed tool alone is not a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 0, "timed_out_tools": []},
  "results": [
    {"tool": "ruff", "success": false, "issues_count": 0, "timed_out": false}
  ]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

# --------------------------------------------------------------------------
# Fail-closed: clean runs
# --------------------------------------------------------------------------

@test "classify-lint-timeout.py: a clean run is not a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 0, "timed_out_tools": []},
  "results": [
    {"tool": "ruff", "success": true, "issues_count": 0, "timed_out": false},
    {"tool": "mypy", "success": true, "issues_count": 0, "timed_out": false}
  ]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
	assert_output --partial "timed-out-tools="
}

@test "classify-lint-timeout.py: an empty results array is not a flake" {
	write_report <<'EOF'
{"summary": {"total_issues": 0, "timed_out_tools": []}, "results": []}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

# --------------------------------------------------------------------------
# Fail-closed: missing / malformed evidence
# --------------------------------------------------------------------------

@test "classify-lint-timeout.py: a missing report is not a flake" {
	run python3 "${SCRIPT}" --report "${BATS_TEST_TMPDIR}/absent.json"
	assert_success
	assert_output --partial "timeout-flake=false"
	assert_file_contains "${GITHUB_OUTPUT}" "timeout-flake=false"
}

@test "classify-lint-timeout.py: a malformed report is not a flake" {
	write_report <<'EOF'
{"summary": {"total_issues": 0,, "results":
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

@test "classify-lint-timeout.py: a non-object report is not a flake" {
	write_report <<'EOF'
["not", "an", "object"]
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

@test "classify-lint-timeout.py: a missing summary is not a flake" {
	write_report <<'EOF'
{"results": [{"tool": "mypy", "success": false, "issues_count": 0,
              "timed_out": true}]}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

@test "classify-lint-timeout.py: a missing results array is not a flake" {
	write_report <<'EOF'
{"summary": {"total_issues": 0, "timed_out_tools": ["mypy"]}}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

@test "classify-lint-timeout.py: a non-integer total_issues is not a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": "0", "timed_out_tools": ["mypy"]},
  "results": [{"tool": "mypy", "success": false, "issues_count": 0,
               "timed_out": true}]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

@test "classify-lint-timeout.py: a boolean total_issues is not a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": true, "timed_out_tools": ["mypy"]},
  "results": [{"tool": "mypy", "success": false, "issues_count": 0,
               "timed_out": true}]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

# bool is a subclass of int in Python, so `false` would pass an
# isinstance(..., int) check and read as a zero count.
@test "classify-lint-timeout.py: a false total_issues is not a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": false, "timed_out_tools": ["mypy"]},
  "results": [{"tool": "mypy", "success": false, "issues_count": 0,
               "timed_out": true}]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

@test "classify-lint-timeout.py: a false issues_count is not a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 0, "timed_out_tools": ["mypy"]},
  "results": [{"tool": "mypy", "success": false, "issues_count": false,
               "timed_out": true}]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

# A present-but-malformed count must not be coerced to zero — zero is exactly
# the value that lets a timed-out tool qualify as a flake.
@test "classify-lint-timeout.py: a non-integer issues_count is not a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 0, "timed_out_tools": ["mypy"]},
  "results": [{"tool": "mypy", "success": false, "issues_count": "0",
               "timed_out": true}]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

@test "classify-lint-timeout.py: a non-list issues field is not a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 0, "timed_out_tools": ["mypy"]},
  "results": [{"tool": "mypy", "success": false, "issues_count": 0,
               "timed_out": true, "issues": "none"}]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

# An explicit null is a malformed value, not an absent key.
@test "classify-lint-timeout.py: a null timed_out_tools is not a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 0, "timed_out_tools": null},
  "results": [{"tool": "mypy", "success": false, "issues_count": 0,
               "timed_out": true}]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

@test "classify-lint-timeout.py: a non-object results entry is not a flake" {
	write_report <<'EOF'
{"summary": {"total_issues": 0}, "results": ["mypy"]}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

# --------------------------------------------------------------------------
# Fail-closed: the timed_out flag is read strictly
# --------------------------------------------------------------------------

# Only a literal `true` counts. A truthy-but-not-true value must not excuse a
# failing tool, and prose in `output` is no longer evidence on its own —
# lintro >= 0.93.0 always serializes the flag.
@test "classify-lint-timeout.py: a non-boolean timed_out does not excuse a failure" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 0},
  "results": [{"tool": "mypy", "success": false, "issues_count": 0,
               "timed_out": "true"}]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

@test "classify-lint-timeout.py: timeout prose without the flag is not a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 0},
  "results": [{"tool": "mypy", "success": false, "issues_count": 0,
               "timed_out": false,
               "output": "mypy execution timed out (120.0s limit exceeded)."}]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

# --------------------------------------------------------------------------
# Fail-closed: internally inconsistent or hostile reports
# --------------------------------------------------------------------------

@test "classify-lint-timeout.py: summary disagreeing with results is not a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 0, "timed_out_tools": ["mypy", "ruff"]},
  "results": [{"tool": "mypy", "success": false, "issues_count": 0,
               "timed_out": true}]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

# An explicit empty list alongside a timed-out result is a report contradicting
# itself. Treating "empty" the same as "absent" would skip the cross-check and
# report true here — a fail-open gap.
@test "classify-lint-timeout.py: an empty timed_out_tools contradicting results is not a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 0, "timed_out_tools": []},
  "results": [{"tool": "mypy", "success": false, "issues_count": 0,
               "timed_out": true}]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
	refute_output --partial "timeout-flake=true"
}

# An absent key means the report predates summary.timed_out_tools; there is
# nothing to cross-check, so the results array alone decides.
@test "classify-lint-timeout.py: an absent timed_out_tools still allows a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 0},
  "results": [{"tool": "mypy", "success": false, "issues_count": 0,
               "timed_out": true}]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=true"
	assert_output --partial "timed-out-tools=mypy"
}

@test "classify-lint-timeout.py: an unreadable non-UTF8 report is not a flake" {
	printf '\xff\xfe\x00\x80binary' >"${REPORT}"
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

@test "classify-lint-timeout.py: a malformed timed_out_tools list is not a flake" {
	write_report <<'EOF'
{
  "summary": {"total_issues": 0, "timed_out_tools": "mypy"},
  "results": [{"tool": "mypy", "success": false, "issues_count": 0,
               "timed_out": true}]
}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
}

# A report is untrusted input. A tool name carrying a newline could otherwise
# forge an extra record in GITHUB_OUTPUT.
@test "classify-lint-timeout.py: an unsafe tool name is rejected" {
	python3 - "$REPORT" <<'EOF'
import json
import sys

payload = {
    "summary": {"total_issues": 0},
    "results": [
        {
            "tool": "mypy\ntimeout-flake=true",
            "success": False,
            "issues_count": 0,
            "timed_out": True,
        },
    ],
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
	run cat "${GITHUB_OUTPUT}"
	refute_output --partial "timeout-flake=true"
}

# --------------------------------------------------------------------------
# Interface
# --------------------------------------------------------------------------

@test "classify-lint-timeout.py: reads a report from stdin" {
	run bash -c 'printf "%s" "{\"summary\": {\"total_issues\": 0, \"timed_out_tools\": [\"mypy\"]}, \"results\": [{\"tool\": \"mypy\", \"success\": false, \"issues_count\": 0, \"timed_out\": true}]}" | python3 "${SCRIPT:?}" --report -'
	assert_success
	assert_output --partial "timeout-flake=true"
}

@test "classify-lint-timeout.py: requires --report" {
	run python3 "${SCRIPT}"
	assert_failure
	assert_equal "2" "$status"
}

@test "classify-lint-timeout.py: emits both keys even without GITHUB_OUTPUT" {
	unset GITHUB_OUTPUT
	write_report <<'EOF'
{"summary": {"total_issues": 0}, "results": []}
EOF
	run python3 "${SCRIPT}" --report "${REPORT}"
	assert_success
	assert_output --partial "timeout-flake=false"
	assert_output --partial "timed-out-tools="
}
