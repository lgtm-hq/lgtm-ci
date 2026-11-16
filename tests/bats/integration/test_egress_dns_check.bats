#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for scripts/ci/maintenance/egress-dns-check.sh (#1548)
#
# Offline: the DNS check replays tests/fixtures/egress-dns-check (every
# repository host resolves; dns-check-proof.invalid is NXDOMAIN), and gh is
# the stub in tests/helpers/gh_issue_stub.bash, which logs every call.

load "../../helpers/common"
load "../../helpers/gh_issue_stub"

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
	cat >"${BATS_TEST_TMPDIR}/fake-python" <<EOF
#!/usr/bin/env bash
printf '%s\\nfailing host\\n' '${MARKER}' >"\$3"
exit 1
EOF
	chmod +x "${BATS_TEST_TMPDIR}/fake-python"
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
	assert_output --partial "Cloudflare second opinion: NXDOMAIN"
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
	cat >"${BATS_TEST_TMPDIR}/fake-python" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
	echo "token leaked to the check"
	exit 2
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
	printf '#!/usr/bin/env bash\nexit 1\n' >"${BATS_TEST_TMPDIR}/fake-python"
	chmod +x "${BATS_TEST_TMPDIR}/fake-python"
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
