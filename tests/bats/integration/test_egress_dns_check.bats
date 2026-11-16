#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for scripts/ci/maintenance/egress-dns-check.sh (#1548)
#
# Offline: the DNS check replays tests/fixtures/egress-dns-check (every
# repository host resolves; dns-check-proof.invalid is NXDOMAIN), and gh is
# the stub in tests/helpers/gh_issue_stub.bash, which logs every call.

load "../../helpers/common"
load "../../helpers/gh_issue_stub"
load "../../helpers/fake_python"

SCRIPT="${PROJECT_ROOT}/scripts/ci/maintenance/egress-dns-check.sh"
CHECK="${PROJECT_ROOT}/scripts/ci/maintenance/check-egress-dns.py"
FIXTURES="${PROJECT_ROOT}/tests/fixtures/egress-dns-check"
MARKER="<!-- lgtm-ci:egress-dns-check -->"
BOT="github-actions[bot]"
PROOF="dns-check-proof.invalid:443"

setup() {
	export GH_TOKEN=test-token
	export GITHUB_REPOSITORY=lgtm-hq/lgtm-ci
	export GITHUB_RUN_ID=12345
	export DNS_RESPONSES_FILE="${FIXTURES}/responses.json"
	unset EXTRA_HOSTS
	install_gh_issue_stub
}

# A fake interpreter that stands in for the DNS check: it writes a failure
# body to the --issue-body path ($2) and exits 1, so tests can simulate a
# failing preset host without editing presets.sh.
fake_failing_check() {
	write_fake_python "${BATS_TEST_TMPDIR}/fake-python" \
		"printf '%s\\nfailing host\\n' '${MARKER}' >\"\$3\"
exit 1"
	export PYTHON="${BATS_TEST_TMPDIR}/fake-python"
}

@test "egress-dns-check.sh: every host resolves, no open issue, nothing written" {
	add_issue 7 "$BOT" Bot null
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "no tracking issue to close"
	run grep -E '^issue (create|edit|comment|close)' "$GH_CALLS"
	assert_failure
}

@test "egress-dns-check.sh: a clean run closes the lowest-numbered tracking issue" {
	add_issue 50 "$BOT" Bot "$MARKER newer"
	add_issue 42 "$BOT" Bot "$MARKER older"
	add_issue 30 "$BOT" Bot "<!-- lgtm-ci:results-hosts-drift --> other tracker"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Closed tracking issue #42"
	run grep -E '^issue close 42 .*--reason completed' "$GH_CALLS"
	assert_success
	run grep -E '^issue close 30' "$GH_CALLS"
	assert_failure
}

@test "egress-dns-check.sh: a failing host opens one issue and fails the run" {
	fake_failing_check
	add_issue 42 mallory User "$MARKER planted"
	run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "see the tracking issue"
	assert_new_issue_only
	run grep -F 'fix(egress): allow-listed hosts do not resolve' "$GH_CALLS"
	assert_success
}

@test "egress-dns-check.sh: a changed failure updates the existing issue" {
	fake_failing_check
	add_issue 42 "$BOT" Bot "$MARKER older failure"
	run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "Updated tracking issue #42"
	run grep -E '^issue edit 42 ' "$GH_CALLS"
	assert_success
	run grep -F 'The set of failing hosts changed' "$GH_CALLS"
	assert_success
}

@test "egress-dns-check.sh: an unchanged failure leaves the issue alone" {
	fake_failing_check
	add_issue 42 "$BOT" Bot "$(printf '%s\nfailing host' "$MARKER")"
	run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "already lists this set of failing hosts"
	run grep -E '^issue (create|edit|comment|close)' "$GH_CALLS"
	assert_failure
}

@test "egress-dns-check.sh: an unreachable resolver fails closed without issue calls" {
	export DNS_RESPONSES_FILE="${FIXTURES}/unreachable.json"
	add_issue 42 "$BOT" Bot "$MARKER"
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "failed closed"
	assert_output --partial "got no DNS answer"
	run grep -E '^(issue|api)' "$GH_CALLS"
	assert_failure
}

@test "egress-dns-check.sh: a deliberately unresolvable extra host fails and reports" {
	export EXTRA_HOSTS="$PROOF"
	add_issue 42 "$BOT" Bot "$MARKER"
	run bash "$SCRIPT"
	assert_failure 1
	assert_output --partial "FAIL dns-check-proof.invalid: Google NXDOMAIN (6 attempts)"
	assert_output --partial "report only"
	# Report only: the real tracker is never read, opened, edited or closed.
	run grep -E '^(issue|api)' "$GH_CALLS"
	assert_failure
}

@test "egress-dns-check.sh: a clean extra-hosts run never closes the tracker" {
	export EXTRA_HOSTS="example.org:443  github.com:443"
	add_issue 42 "$BOT" Bot "$MARKER"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "report only"
	run grep -E '^(issue|api)' "$GH_CALLS"
	assert_failure
}

@test "egress-dns-check.sh: blank extra hosts are refused and never touch the tracker" {
	export EXTRA_HOSTS="   "
	add_issue 42 "$BOT" Bot "$MARKER"
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "extra-hosts is blank"
	run grep -E '^(issue|api)' "$GH_CALLS"
	assert_failure
}

@test "egress-dns-check.sh: the DNS check runs without the token" {
	# The fake answers the version probe only without a token too, so a
	# probe that saw the token fails the run as well.
	cat >"${BATS_TEST_TMPDIR}/fake-python" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
	echo "token leaked to the check"
	exit 2
fi
if [[ "${1:-}" == -I && "${2:-}" == -c ]]; then
	printf 3.12.0
	exit 0
fi
exit 0
EOF
	chmod +x "${BATS_TEST_TMPDIR}/fake-python"
	export PYTHON="${BATS_TEST_TMPDIR}/fake-python"
	export GITHUB_TOKEN=other-token
	run bash "$SCRIPT"
	assert_success
	refute_output --partial "token leaked"
}

@test "egress-dns-check.sh: reports clean, hosts-fail or error to the workflow" {
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
	: >"$GITHUB_OUTPUT"
	run bash "$SCRIPT"
	assert_success
	export EXTRA_HOSTS="$PROOF"
	run bash "$SCRIPT"
	assert_failure 1
	unset EXTRA_HOSTS
	export DNS_RESPONSES_FILE="${FIXTURES}/unreachable.json"
	run bash "$SCRIPT"
	assert_failure 2
	run cat "$GITHUB_OUTPUT"
	assert_output "result=clean
result=hosts-fail
result=error"
}

@test "egress-dns-check.sh: malformed extra hosts are refused before any check" {
	local bad
	for bad in '*.example.org:443' 'Example.org:443' 'example.org' 'example.org:0' \
		'example.org:99999' '$(id):443' 'a.b:443;id' "$(printf 'a.b:443\nc.d:443')" \
		'-x.org:443'; do
		export EXTRA_HOSTS="$bad"
		export PYTHON=/nonexistent/python
		run bash "$SCRIPT"
		assert_failure 2
		assert_output --partial "extra-hosts"
	done
	run grep -E '^(issue|api)' "$GH_CALLS"
	assert_failure
}

@test "egress-dns-check.sh: more than twenty extra hosts are refused" {
	EXTRA_HOSTS="$(printf 'h%d.example.org:443 ' {1..21})"
	export EXTRA_HOSTS
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "at most 20"
}

@test "egress-dns-check.sh: a failure exit without an issue body writes nothing" {
	write_fake_python "${BATS_TEST_TMPDIR}/fake-python" 'exit 1'
	export PYTHON="${BATS_TEST_TMPDIR}/fake-python"
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "DNS check wrote no issue body"
	run grep -E '^(issue|api)' "$GH_CALLS"
	assert_failure
}

@test "egress-dns-check.sh: a failed issue listing never opens a duplicate" {
	fake_failing_check
	export STUB_LIST_FAIL=1
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "Could not list every open issue"
	run grep -E '^issue create' "$GH_CALLS"
	assert_failure
}

@test "egress-dns-check.sh: a failed listing with failing hosts reports error, not hosts-fail" {
	fake_failing_check
	export STUB_LIST_FAIL=1
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
	: >"$GITHUB_OUTPUT"
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "Could not reconcile the tracking issue"
	run cat "$GITHUB_OUTPUT"
	assert_output "result=error"
}

@test "egress-dns-check.sh: a failed issue creation is an error, exit 2" {
	fake_failing_check
	export STUB_CREATE_FAIL=1
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
	: >"$GITHUB_OUTPUT"
	run bash "$SCRIPT"
	assert_failure 2
	refute_output --partial "Opened the egress DNS tracking issue"
	run cat "$GITHUB_OUTPUT"
	assert_output "result=error"
}

@test "egress-dns-check.sh: a failed listing on a clean run reports error" {
	export STUB_LIST_FAIL=1
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
	: >"$GITHUB_OUTPUT"
	run bash "$SCRIPT"
	assert_failure 2
	run cat "$GITHUB_OUTPUT"
	assert_output "result=error"
}

@test "egress-dns-check.sh: hosts-fail is reported only after the issue is written" {
	fake_failing_check
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
	: >"$GITHUB_OUTPUT"
	run bash "$SCRIPT"
	assert_failure 1
	assert_new_issue_only
	run cat "$GITHUB_OUTPUT"
	assert_output "result=hosts-fail"
}

@test "egress-dns-check.sh: requires GH_TOKEN and GITHUB_REPOSITORY" {
	unset GH_TOKEN
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "GH_TOKEN is required"
	export GH_TOKEN=test-token
	unset GITHUB_REPOSITORY
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "GITHUB_REPOSITORY is required"
}

# #1428: a too-old interpreter is refused by run_python with exit 69, which
# the script reports as an error (exit 2), never as failing hosts. The fake
# would report failing hosts (exit 1 with a body) if it were ever run.
@test "egress-dns-check.sh: Python older than 3.11 is an error, never hosts-fail" {
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
	: >"$GITHUB_OUTPUT"
	write_fake_python "${BATS_TEST_TMPDIR}/fake-python" \
		"printf '%s\\nfailing host\\n' '${MARKER}' >\"\$3\"
exit 1" 3.10.12
	export PYTHON="${BATS_TEST_TMPDIR}/fake-python"
	add_issue 42 "$BOT" Bot "$MARKER"
	run bash "$SCRIPT"
	assert_failure 2
	assert_line --regexp '^::error::Python 3\.10\.12 at .* is too old; lgtm-ci scripts need Python 3\.11 or newer'
	assert_output --partial "failed closed (exit 69)"
	run grep -E '^(issue|api)' "$GH_CALLS"
	assert_failure
	export EXTRA_HOSTS="$PROOF"
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "failed closed (exit 69)"
	run cat "$GITHUB_OUTPUT"
	assert_output "result=error
result=error"
}

@test "egress-dns-check.sh: no python3 at all is an error, never hosts-fail" {
	export PYTHON=/nonexistent/python3
	add_issue 42 "$BOT" Bot "$MARKER"
	run bash "$SCRIPT"
	assert_failure 2
	assert_line --regexp '^::error::PYTHON=/nonexistent/python3 is not an executable file'
	assert_output --partial "failed closed (exit 69)"
	run grep -E '^(issue|api)' "$GH_CALLS"
	assert_failure
}

@test "egress-dns-check.sh: a checker status other than 0 or 1 is reported as 2" {
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
	: >"$GITHUB_OUTPUT"
	write_fake_python "${BATS_TEST_TMPDIR}/fake-python" 'exit 3'
	export PYTHON="${BATS_TEST_TMPDIR}/fake-python"
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "failed closed (exit 3)"
	export EXTRA_HOSTS="$PROOF"
	run bash "$SCRIPT"
	assert_failure 2
	assert_output --partial "failed closed (exit 3)"
	run cat "$GITHUB_OUTPUT"
	assert_output "result=error
result=error"
}

# A fake interpreter that records, for the version probe and for the real
# call, whether it saw a non-empty token, then answers like a clean check.
token_recording_python() {
	cat >"${BATS_TEST_TMPDIR}/fake-python" <<EOF
#!/usr/bin/env bash
kind=call
[[ "\${1:-}" == -I && "\${2:-}" == -c ]] && kind=probe
echo "\$kind GH_TOKEN=[\${GH_TOKEN:-}] GITHUB_TOKEN=[\${GITHUB_TOKEN:-}]" >>'${BATS_TEST_TMPDIR}/seen'
if [[ "\$kind" == probe ]]; then
	printf 3.12.0
fi
exit 0
EOF
	chmod +x "${BATS_TEST_TMPDIR}/fake-python"
	export PYTHON="${BATS_TEST_TMPDIR}/fake-python"
	export GITHUB_TOKEN=other-token
}

# Both the probe and the real call ran, and neither saw a token value.
assert_no_token_seen() {
	run cat "${BATS_TEST_TMPDIR}/seen"
	assert_success
	assert_line --index 0 "probe GH_TOKEN=[] GITHUB_TOKEN=[]"
	assert_line --index 1 "call GH_TOKEN=[] GITHUB_TOKEN=[]"
	assert_equal "${#lines[@]}" 2
}

@test "egress-dns-check.sh: an exported unset function does not leak the token" {
	token_recording_python
	run env 'BASH_FUNC_unset%%=() { :; }' bash "$SCRIPT"
	assert_success
	assert_no_token_seen
}

@test "egress-dns-check.sh: an exported builtin or env function does not leak the token" {
	token_recording_python
	run env 'BASH_FUNC_builtin%%=() { :; }' 'BASH_FUNC_env%%=() { "$@"; }' \
		'BASH_FUNC_unset%%=() { :; }' bash "$SCRIPT"
	assert_success
	assert_no_token_seen
}
