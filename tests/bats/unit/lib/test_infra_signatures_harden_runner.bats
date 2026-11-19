#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for the harden-runner agent failure rules in scripts/ci/lib/infra-signatures.sh (#1616)

load "../../../helpers/common"

FIXTURES="${PROJECT_ROOT}/tests/fixtures/security/harden-runner-agent"
STARTUP_MESSAGE='agent.service is not active; egress is not enforced'
RECHECK_MESSAGE="harden-runner agent stopped enforcing mid-job; steps after it ran unhardened (resolved.conf no longer uses the agent's DNS proxy: revert in progress or DNS changed by a step)"

setup() {
	setup_temp_dir
	export FIXTURES
}

teardown() {
	teardown_temp_dir
}

# Run a library function from a script file, not `bash -c`: under kcov the
# library's `set -u` needs BASH_SOURCE bound. Usage: _lib '<cmd>' [stdin file]
_lib() {
	local runner="${BATS_TEST_TMPDIR}/lib.sh"
	printf '%s\n' '# shellcheck disable=SC1090' \
		"source '${LIB_DIR}/infra-signatures.sh'" 'eval "$1"' >"$runner"
	if [[ -n "${2:-}" ]]; then
		bash "$runner" "$1" <"$2"
	else
		bash "$runner" "$1" </dev/null
	fi
}

# Job JSON from "name=conclusion" arguments, numbered in order. A conclusion
# of "null" is a step that never ran.
_job() {
	local file="${BATS_TEST_TMPDIR}/job.json"
	printf '%s\n' "$@" | jq -R -s '
		split("\n") | map(select(length > 0)) | to_entries
		| {id: 135649511127, name: "actionlint / Actionlint", conclusion: "failure",
			steps: map((.value | split("=")) as [$n, $c]
				| {number: (.key + 1), name: $n,
					conclusion: (if $c == "null" then null else $c end)})}' >"$file"
	printf '%s\n' "$file"
}

# The real shape of fixture job 135649511127 (actionlint).
_startup_job() {
	_job 'Set up job=success' 'Pre Harden runner=success' 'Harden runner=success' \
		'Verify harden-runner agent=failure' 'Checkout repository=skipped' \
		'Classify lint timeout=success' 'Upload linting report=success' \
		'Upload lint JSON report=success' 'Recheck harden-runner agent=skipped' \
		'Post Harden runner=success' 'Complete job=success'
}

# The real shape of fixture job 135707070821 (Aggregate Python Results).
_recheck_job() {
	_job 'Set up job=success' 'Pre Harden runner=success' 'Harden runner=success' \
		'Verify harden-runner agent=success' 'Checkout repository=success' \
		'Aggregate matrix results=success' 'Fail if any matrix leg failed=skipped' \
		'Recheck harden-runner agent=failure' 'Post Harden runner=success' 'Complete job=success'
}

_messages() {
	local file="${BATS_TEST_TMPDIR}/messages.txt"
	printf '%s\n' "$@" >"$file"
	printf '%s\n' "$file"
}

# --- job shape -------------------------------------------------------------

@test "infra-signatures: a verify failure right after harden-runner is the agent-startup shape" {
	run _lib 'infra_harden_runner_shape' "$(_startup_job)"
	assert_success
	# Classify lint timeout and both uploads ran after the verify step.
	assert_output "$(printf 'agent-startup\t3\t0')"
}

@test "infra-signatures: a later failed always() step keeps the agent-startup shape" {
	# Fixture job 135640146414: Summarize blocked egress exited 127.
	run _lib 'infra_harden_runner_shape' "$(_job 'Set up job=success' 'Pre Harden runner=success' \
		'Harden runner=success' 'Verify harden-runner agent=failure' 'Build and push=skipped' \
		'Summarize blocked egress=failure' 'Post Harden runner=success' 'Complete job=success')"
	assert_success
	assert_output "$(printf 'agent-startup\t1\t0')"
}

@test "infra-signatures: a verify failure after a job step is not the agent-startup shape" {
	run _lib 'infra_harden_runner_shape' "$(_job 'Set up job=success' 'Harden runner=success' \
		'Checkout repository=success' 'Verify harden-runner agent=failure')"
	assert_failure
	assert_output ''
}

@test "infra-signatures: a verify failure without a harden-runner step is not the agent-startup shape" {
	run _lib 'infra_harden_runner_shape' "$(_job 'Set up job=success' 'Verify harden-runner agent=failure')"
	assert_failure
}

@test "infra-signatures: a failed end-of-job recheck after a verified start is the agent-recheck shape" {
	run _lib 'infra_harden_runner_shape' "$(_recheck_job)"
	assert_success
	assert_output "$(printf 'agent-recheck\t0\t0')"
}

@test "infra-signatures: a pre-publish recheck or a second failed step is not the agent-recheck shape" {
	run _lib 'infra_harden_runner_shape' "$(_job 'Harden runner=success' 'Verify harden-runner agent=success' \
		'Recheck harden-runner agent before Publish package set=failure')"
	assert_failure
	run _lib 'infra_harden_runner_shape' "$(_job 'Harden runner=success' 'Verify harden-runner agent=success' \
		'Run tests=failure' 'Recheck harden-runner agent=failure')"
	assert_failure
}

@test "infra-signatures: a job with no failed step has no agent shape" {
	run _lib 'infra_harden_runner_shape' "$(_job 'Harden runner=success' 'Run tests=success')"
	assert_failure
}

@test "infra-signatures: the matrix gate failing after the verify step is flagged in the shape" {
	# Fixture job 134245239947 (run 44141287243, Aggregate Python Results).
	run _lib 'infra_harden_runner_shape' "$(_job 'Set up job=success' 'Pre Harden runner=success' \
		'Harden runner=success' 'Verify harden-runner agent=failure' 'Aggregate matrix results=skipped' \
		'Fail if any matrix leg failed=failure' 'Recheck harden-runner agent=skipped' 'Complete job=success')"
	assert_success
	assert_output "$(printf 'agent-startup\t1\t1')"
}

# --- annotations -----------------------------------------------------------

@test "infra-signatures: the start-up message with one exit line per step that ran is accepted" {
	# Fixture job 135649511127: exit 2 (continue-on-error), exit 1, the message.
	run _lib 'infra_harden_runner_annotations agent-startup 3' \
		"$(_messages 'Process completed with exit code 2.' 'Process completed with exit code 1.' "$STARTUP_MESSAGE")"
	assert_success
}

@test "infra-signatures: the matrix gate's message counts only when that step failed" {
	local matrix='A matrix test leg failed or its results could not be aggregated; failing the check.'
	# Fixture job 134245239947: exit 1 (gate), the gate message, exit 1, the message.
	run _lib 'infra_harden_runner_annotations agent-startup 1 1' \
		"$(_messages 'Process completed with exit code 1.' "$matrix" 'Process completed with exit code 1.' "$STARTUP_MESSAGE")"
	assert_success
	# The same message without the gate step failing is a second own annotation.
	run _lib 'infra_harden_runner_annotations agent-startup 1 0' \
		"$(_messages 'Process completed with exit code 1.' "$matrix" "$STARTUP_MESSAGE")"
	assert_failure
	# Twice is not the one gate step.
	run _lib 'infra_harden_runner_annotations agent-startup 1 1' \
		"$(_messages "$matrix" "$matrix" "$STARTUP_MESSAGE")"
	assert_failure
	# The gate message never replaces the start-up message.
	run _lib 'infra_harden_runner_annotations agent-startup 1 1' "$(_messages "$matrix")"
	assert_failure
	# A malformed flag fails closed.
	run _lib 'infra_harden_runner_annotations agent-startup 1 yes' "$(_messages "$STARTUP_MESSAGE")"
	assert_failure
}

@test "infra-signatures: more exit lines than steps that ran are rejected" {
	run _lib 'infra_harden_runner_annotations agent-startup 0' \
		"$(_messages 'Process completed with exit code 2.' 'Process completed with exit code 1.' "$STARTUP_MESSAGE")"
	assert_failure
}

@test "infra-signatures: a different agent failure is not the start-up signature" {
	local message
	for message in 'agent.status is not Initialized after 60s' \
		'agent.service stopped just after Initialized; egress is not enforced' \
		'agent.log reports a reverted initialization; egress is not enforced' \
		'harden-runner agent unavailable on this runner (container job): use a supported GitHub-hosted Linux runner'; do
		run _lib 'infra_harden_runner_annotations agent-startup 3' \
			"$(_messages 'Process completed with exit code 1.' "$message")"
		assert_failure
	done
}

@test "infra-signatures: a second own annotation rejects the start-up signature" {
	run _lib 'infra_harden_runner_annotations agent-startup 3' \
		"$(_messages 'Process completed with exit code 1.' "$STARTUP_MESSAGE" 'assert 3 == 4')"
	assert_failure
	run _lib 'infra_harden_runner_annotations agent-startup 3' \
		"$(_messages "$STARTUP_MESSAGE" "$STARTUP_MESSAGE")"
	assert_failure
}

@test "infra-signatures: the recheck resolved.conf message with one exit line is accepted" {
	run _lib 'infra_harden_runner_annotations agent-recheck 0' \
		"$(_messages 'Process completed with exit code 1.' "$RECHECK_MESSAGE")"
	assert_success
}

@test "infra-signatures: the recheck systemd message is not the resolved.conf signature" {
	run _lib 'infra_harden_runner_annotations agent-recheck 0' \
		"$(_messages 'Process completed with exit code 1.' \
			'harden-runner agent stopped enforcing mid-job; steps after it ran unhardened (agent.service is not active: ActiveState=failed SubState=failed Result=exit-code ExecMainStatus=1)')"
	assert_failure
}

@test "infra-signatures: the messages stay equal to the verify and recheck sources" {
	run grep -cF "agent.service is not active; egress is not enforced\"" \
		"${PROJECT_ROOT}/scripts/ci/bootstrap/verify-harden-runner-agent.sh"
	assert_output 1
	run grep -cF "(resolved.conf no longer uses the agent's DNS proxy: revert\" \\" \
		"${PROJECT_ROOT}/scripts/ci/bootstrap/recheck-harden-runner-agent.sh"
	assert_output 1
	run grep -cF '"in progress or DNS changed by a step)"' \
		"${PROJECT_ROOT}/scripts/ci/bootstrap/recheck-harden-runner-agent.sh"
	assert_output 1
	run grep -cF 'stopped+=" enforcing mid-job; steps after it ran unhardened"' \
		"${PROJECT_ROOT}/scripts/ci/bootstrap/recheck-harden-runner-agent.sh"
	assert_output 1
}

# --- job log evidence --------------------------------------------------------

@test "infra-signatures: the real start-up job log carries DNS SERVFAIL evidence" {
	run _lib 'infra_harden_runner_log_evidence agent-startup' "${FIXTURES}/job-startup-dns.log"
	assert_success
	# The log of another cause is not evidence for this one.
	run _lib 'infra_harden_runner_log_evidence agent-startup' "${FIXTURES}/job-recheck-tls-fallback.log"
	assert_failure
}

@test "infra-signatures: REFUSED (status 5) is start-up evidence" {
	# Fixture runs 43983818529 and 43924199865: REFUSED for hosts that exist.
	sed 's/, status 2$/, status 5/' "${FIXTURES}/job-startup-dns.log" >"${BATS_TEST_TMPDIR}/refused.log"
	run _lib 'infra_harden_runner_log_evidence agent-startup' "${BATS_TEST_TMPDIR}/refused.log"
	assert_success
}

@test "infra-signatures: NXDOMAIN (status 3) and other codes are not start-up evidence" {
	local code
	for code in 3 1 4 25; do
		sed "s/, status 2\$/, status ${code}/" "${FIXTURES}/job-startup-dns.log" >"${BATS_TEST_TMPDIR}/nx.log"
		run _lib 'infra_harden_runner_log_evidence agent-startup' "${BATS_TEST_TMPDIR}/nx.log"
		assert_failure
	done
}

@test "infra-signatures: an agent error printed only in the post step does not count" {
	# Fixture run 43858549864: harden-runner stopped waiting after 9 seconds,
	# so the agent's DNS failure appears only after the job steps.
	local late='2026-11-19T14:59:21.2000000Z Thu, 19 Nov 2026 14:59:02 GMT:Error resolving allowed domain error in response from dns.google unable to resolve domain auth.docker.io., status 2'
	grep -vE 'GMT:(Error resolving|unable to resolve|Reverted)' "${FIXTURES}/job-startup-dns.log" |
		awk -v late="$late" '{ print } /Post job cleanup\.$/ { print late }' >"${BATS_TEST_TMPDIR}/post.log"
	run grep -c 'status 2$' "${BATS_TEST_TMPDIR}/post.log"
	assert_output 2
	run _lib 'infra_harden_runner_log_evidence agent-startup' "${BATS_TEST_TMPDIR}/post.log"
	assert_failure
}

@test "infra-signatures: start-up evidence printed only after the first job step does not count" {
	# Drop the harden-runner copy; the post-step journal and a step-printed
	# copy remain.
	grep -v 'GMT:Error resolving allowed domain' "${FIXTURES}/job-startup-dns.log" >"${BATS_TEST_TMPDIR}/late.log"
	printf '%s\n' '2026-11-19T14:59:10.8200000Z Thu, 19 Nov 2026 14:59:02 GMT:Error resolving allowed domain error in response from dns.google unable to resolve domain example.com., status 2' \
		>>"${BATS_TEST_TMPDIR}/late.log"
	run _lib 'infra_harden_runner_log_evidence agent-startup' "${BATS_TEST_TMPDIR}/late.log"
	assert_failure
}

@test "infra-signatures: a CRLF log with a byte-order mark still carries the evidence" {
	{
		printf '\xef\xbb\xbf'
		sed 's/$/\r/' "${FIXTURES}/job-startup-dns.log"
	} >"${BATS_TEST_TMPDIR}/crlf.log"
	run _lib 'infra_harden_runner_log_evidence agent-startup' "${BATS_TEST_TMPDIR}/crlf.log"
	assert_success
}

@test "infra-signatures: the real recheck job log carries TLS-status fallback evidence" {
	run _lib 'infra_harden_runner_log_evidence agent-recheck' "${FIXTURES}/job-recheck-tls-fallback.log"
	assert_success
	run _lib 'infra_harden_runner_log_evidence agent-recheck' "${FIXTURES}/job-startup-dns.log"
	assert_failure
}

@test "infra-signatures: a TLS fallback line printed by a job step is not recheck evidence" {
	grep -v 'Unable to check TLS_STATUS' "${FIXTURES}/job-recheck-tls-fallback.log" >"${BATS_TEST_TMPDIR}/step.log"
	printf '%s\n' '2026-11-19T16:25:33.0790000Z [!] Unable to check TLS_STATUS. Defaulting to TLS enabled.' \
		>>"${BATS_TEST_TMPDIR}/step.log"
	run _lib 'infra_harden_runner_log_evidence agent-recheck' "${BATS_TEST_TMPDIR}/step.log"
	assert_failure
}

@test "infra-signatures: an unknown kind never carries evidence" {
	run _lib 'infra_harden_runner_log_evidence other' "${FIXTURES}/job-startup-dns.log"
	assert_failure
	run _lib 'infra_harden_runner_annotations other 0' "$(_messages "$STARTUP_MESSAGE")"
	assert_failure
}
