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

@test "infra-signatures: a failed recheck (agent stopped mid-job) has no agent shape" {
	# Fixture job 135707070821: a real failure until #1668, never infrastructure.
	run _lib 'infra_harden_runner_shape' "$(_recheck_job)"
	assert_failure
	assert_output ''
	run _lib 'infra_harden_runner_shape' "$(_job 'Harden runner=success' 'Verify harden-runner agent=success' \
		'Recheck harden-runner agent before Publish package set=failure')"
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

@test "infra-signatures: the mid-job recheck message is never accepted" {
	run _lib 'infra_harden_runner_annotations agent-recheck 0' \
		"$(_messages 'Process completed with exit code 1.' "$RECHECK_MESSAGE")"
	assert_failure
	run _lib 'infra_harden_runner_annotations agent-startup 0' \
		"$(_messages 'Process completed with exit code 1.' "$RECHECK_MESSAGE")"
	assert_failure
}

@test "infra-signatures: the start-up message stays equal to the verify source" {
	run grep -cF "agent.service is not active; egress is not enforced\"" \
		"${PROJECT_ROOT}/scripts/ci/bootstrap/verify-harden-runner-agent.sh"
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

# --- provenance of the log evidence (#1616 review) ---------------------------

HR_CAPTION='##[group]Run step-security/harden-runner@46b06cea07f9e64621fdf066ba77ac6915163d43'
FORGED='Thu, 19 Nov 2026 14:59:02 GMT:Error resolving allowed domain error in response from dns.google unable to resolve domain example.com., status 2'

# The start-up fixture without harden-runner's genuine evidence.
_no_evidence_log() {
	grep -vE 'GMT:(Error resolving|unable to resolve|Reverted)' "${FIXTURES}/job-startup-dns.log"
}

# Print the no-evidence log with the remaining arguments inserted, each as
# its own timestamped line, after the first line ending in $1.
_inject_after() {
	local anchor="$1" out="${BATS_TEST_TMPDIR}/injected.log"
	shift
	_no_evidence_log | awk -v anchor="$anchor" -v extra="$(printf '%s\n' "$@")" '
		{ print }
		!done && substr($0, length($0) - length(anchor) + 1) == anchor {
			n = split(extra, lines, "\n")
			for (i = 1; i <= n; i++) if (lines[i] != "") print "2026-11-19T14:58:58.5607200Z " lines[i]
			done = 1
		}' >"$out"
	printf '%s\n' "$out"
}

@test "infra-signatures: the genuine fixture passes the provenance rules and the no-evidence copy does not" {
	run _lib 'infra_harden_runner_log_evidence agent-startup' "${FIXTURES}/job-startup-dns.log"
	assert_success
	_no_evidence_log >"${BATS_TEST_TMPDIR}/none.log"
	run _lib 'infra_harden_runner_log_evidence agent-startup' "${BATS_TEST_TMPDIR}/none.log"
	assert_failure
}

@test "infra-signatures: evidence inside harden-runner's configuration dump does not count" {
	# A multi-line input or env value prints raw lines in the details group.
	run _lib 'infra_harden_runner_log_evidence agent-startup' "$(_inject_after '  egress-policy: block' "$FORGED")"
	assert_failure
}

@test "infra-signatures: a configuration dump that forges the group end and marker fails closed" {
	run _lib 'infra_harden_runner_log_evidence agent-startup' \
		"$(_inject_after '  egress-policy: block' '##[endgroup]' '[harden-runner] pre-step' "$FORGED")"
	assert_failure
	# Forging the whole rest of the prefix, up to an early boundary, still
	# leaves the runner's own captions and markers in the log.
	run _lib 'infra_harden_runner_log_evidence agent-startup' \
		"$(_inject_after '  egress-policy: block' '##[endgroup]' '[harden-runner] pre-step' "$FORGED" \
			"$HR_CAPTION" 'with:' '##[endgroup]' '[harden-runner] main-step' '##[group]Run echo boundary')"
	assert_failure
}

@test "infra-signatures: evidence in Set up job or Initialize containers output does not count" {
	run _lib 'infra_harden_runner_log_evidence agent-startup' "$(_inject_after 'Image: ubuntu-26.04' "$FORGED")"
	assert_failure
	run _lib 'infra_harden_runner_log_evidence agent-startup' \
		"$(_inject_after '##[endgroup]' '##[group]Checking docker version' "$FORGED" '##[endgroup]')"
	assert_failure
}

@test "infra-signatures: a run: step captioned like harden-runner is not harden-runner" {
	# A shell step's caption is its script's first line; its group continues
	# with the echoed script, never with an action's `with:`.
	{
		printf '%s\n' '2026-11-19T14:58:52.1000000Z Current runner version: '"'2.338.2'"''
		local i
		for i in pre main; do
			printf '%s\n' "2026-11-19T14:58:58.5606538Z ${HR_CAPTION}" \
				"2026-11-19T14:58:58.5606600Z $(printf '\033')[36;1mstep-security/harden-runner@46b06cea07f9e64621fdf066ba77ac6915163d43$(printf '\033')[0m" \
				'2026-11-19T14:58:58.5606700Z shell: /usr/bin/bash -e {0}' \
				'2026-11-19T14:58:58.5606800Z ##[endgroup]' \
				"2026-11-19T14:58:58.5606900Z [harden-runner] ${i}-step" \
				"2026-11-19T14:58:58.5607000Z ${FORGED}"
		done
		printf '%s\n' '2026-11-19T14:59:10.7759412Z ##[group]Run # lgtm-ci-inline:begin verify-harden-runner-agent'
	} >"${BATS_TEST_TMPDIR}/run-step.log"
	run _lib 'infra_harden_runner_log_evidence agent-startup' "${BATS_TEST_TMPDIR}/run-step.log"
	assert_failure
}

@test "infra-signatures: a local composite wrapping a harden-runner-like step is not harden-runner" {
	# The composite's own caption is the first other step: the search ends
	# before its inner group, whatever that group prints.
	{
		printf '%s\n' '2026-11-19T14:58:52.1000000Z Current runner version: '"'2.338.2'"'' \
			'2026-11-19T14:58:58.5000000Z ##[group]Run ./.github/actions/harden' \
			'2026-11-19T14:58:58.5000100Z ##[endgroup]'
		local i
		for i in pre main; do
			printf '%s\n' "2026-11-19T14:58:58.5606538Z ${HR_CAPTION}" '2026-11-19T14:58:58.5606600Z with:' \
				'2026-11-19T14:58:58.5606700Z ##[endgroup]' "2026-11-19T14:58:58.5606900Z [harden-runner] ${i}-step" \
				"2026-11-19T14:58:58.5607000Z ${FORGED}"
		done
		printf '%s\n' '2026-11-19T14:59:10.7759412Z ##[group]Run # lgtm-ci-inline:begin verify-harden-runner-agent'
	} >"${BATS_TEST_TMPDIR}/composite.log"
	run _lib 'infra_harden_runner_log_evidence agent-startup' "${BATS_TEST_TMPDIR}/composite.log"
	assert_failure
}

@test "infra-signatures: a log that ends inside harden-runner's output fails closed" {
	sed '/lgtm-ci-inline:begin verify-harden-runner-agent/,$d' "${FIXTURES}/job-startup-dns.log" >"${BATS_TEST_TMPDIR}/cut.log"
	run _lib 'infra_harden_runner_log_evidence agent-startup' "${BATS_TEST_TMPDIR}/cut.log"
	assert_failure
}

@test "infra-signatures: an extra harden-runner marker anywhere in the log fails closed" {
	cp "${FIXTURES}/job-startup-dns.log" "${BATS_TEST_TMPDIR}/extra.log"
	printf '%s\n' '2026-11-19T14:59:11.0000000Z [harden-runner] pre-step' >>"${BATS_TEST_TMPDIR}/extra.log"
	run _lib 'infra_harden_runner_log_evidence agent-startup' "${BATS_TEST_TMPDIR}/extra.log"
	assert_failure
}

@test "infra-signatures: an unknown kind never carries evidence" {
	run _lib 'infra_harden_runner_log_evidence other' "${FIXTURES}/job-startup-dns.log"
	assert_failure
	run _lib 'infra_harden_runner_annotations other 0' "$(_messages "$STARTUP_MESSAGE")"
	assert_failure
}
