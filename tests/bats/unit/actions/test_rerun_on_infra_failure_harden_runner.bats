#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: harden-runner agent failures in rerun-on-infra-failure.sh (#1616)
# Bats isolates each test environment, including exported configuration.
# shellcheck disable=SC2030,SC2031

load "../../../helpers/rerun_on_infra_failure"

FIXTURES="${PROJECT_ROOT}/tests/fixtures/security/harden-runner-agent"
STARTUP_MESSAGE='agent.service is not active; egress is not enforced'
RECHECK_MESSAGE="harden-runner agent stopped enforcing mid-job; steps after it ran unhardened (resolved.conf no longer uses the agent's DNS proxy: revert in progress or DNS changed by a step)"
EXIT_1='Process completed with exit code 1.'
EXIT_2='Process completed with exit code 2.'

# Fixture job 135649511127 (actionlint): the verify step failed right after
# harden-runner; three always() steps ran after it.
STARTUP_JOB='{"id":135649511127,"name":"actionlint / Actionlint","conclusion":"failure","steps":[
{"number":1,"name":"Set up job","conclusion":"success"},
{"number":2,"name":"Pre Harden runner","conclusion":"success"},
{"number":3,"name":"Harden runner","conclusion":"success"},
{"number":4,"name":"Verify harden-runner agent","conclusion":"failure"},
{"number":5,"name":"Checkout repository","conclusion":"skipped"},
{"number":13,"name":"Classify lint timeout","conclusion":"success"},
{"number":14,"name":"Upload linting report","conclusion":"success"},
{"number":15,"name":"Upload lint JSON report","conclusion":"success"},
{"number":18,"name":"Recheck harden-runner agent","conclusion":"skipped"},
{"number":36,"name":"Post Harden runner","conclusion":"success"},
{"number":37,"name":"Complete job","conclusion":"success"}]}'

# Fixture job 135707070821 (Aggregate Python Results): only the end-of-job
# recheck failed.
RECHECK_JOB='{"id":135707070821,"name":"python-compat / Aggregate Python Results","conclusion":"failure","steps":[
{"number":1,"name":"Set up job","conclusion":"success"},
{"number":3,"name":"Harden runner","conclusion":"success"},
{"number":4,"name":"Verify harden-runner agent","conclusion":"success"},
{"number":13,"name":"Aggregate matrix results","conclusion":"success"},
{"number":15,"name":"Recheck harden-runner agent","conclusion":"failure"},
{"number":31,"name":"Complete job","conclusion":"success"}]}'

_compact() {
	jq -c . <<<"$1"
}

# The startup failure as the safety net sees it: `--log-failed` holds only the
# verify step (no signature), and the job's annotations and raw log are real.
_startup_case() {
	_mock_gh "actionlint	Verify harden-runner agent	##[error]${STARTUP_MESSAGE}"
	_agent_jobs 0 "$(_compact "$STARTUP_JOB")"
	_job_annotations 135649511127 0 "$(printf '%s\n' "$EXIT_2" "$EXIT_1" "$STARTUP_MESSAGE")"
	_probe_job_log 135649511127 0 "$(cat "${FIXTURES}/job-startup-dns.log")"
}

_recheck_case() {
	_mock_gh "aggregate	Recheck harden-runner agent	##[error]${RECHECK_MESSAGE}"
	_agent_jobs 0 "$(_compact "$RECHECK_JOB")"
	_job_annotations 135707070821 0 "$(printf '%s\n' "$EXIT_1" "$RECHECK_MESSAGE")"
	_probe_job_log 135707070821 0 "$(cat "${FIXTURES}/job-recheck-tls-fallback.log")"
}

@test "rerun-on-infra-failure: a harden-runner agent DNS start-up failure re-runs once" {
	_startup_case
	run bash "$SCRIPT"
	assert_success
	assert_equal "1" "$(_call_count "$RERUN_CALLS")"
	assert_output --partial "harden-runner agent start-up DNS failure on job 135649511127"
	# The summary names the job, the step and the rule.
	run grep -c 'start-up DNS failure on job 135649511127 (actionlint / Actionlint): step "Verify harden-runner agent"' "$GITHUB_STEP_SUMMARY"
	assert_output 1
}

@test "rerun-on-infra-failure: the start-up failure also re-runs when the failed-job log stays empty" {
	_mock_sleep
	_mock_gh_attempts "0:"
	_agent_jobs 0 "$(_compact "$STARTUP_JOB")"
	_job_annotations 135649511127 0 "$(printf '%s\n' "$EXIT_2" "$EXIT_1" "$STARTUP_MESSAGE")"
	_probe_job_log 135649511127 0 "$(cat "${FIXTURES}/job-startup-dns.log")"
	run bash "$SCRIPT"
	assert_success
	assert_equal "1" "$(_call_count "$RERUN_CALLS")"
}

@test "rerun-on-infra-failure: an aggregate job whose matrix gate failed after the agent did is re-run" {
	# Fixture run 44141287243 (Aggregate Python Results): the always() gate
	# fails because nothing was aggregated; no matrix leg failed.
	local job matrix='A matrix test leg failed or its results could not be aggregated; failing the check.'
	job="$(jq -c '.steps |= map(if .name == "Classify lint timeout" then .name = "Fail if any matrix leg failed" | .conclusion = "failure"
		elif .name == "Upload linting report" or .name == "Upload lint JSON report" then .conclusion = "skipped" else . end)' <<<"$STARTUP_JOB")"
	_startup_case
	_agent_jobs 0 "$job"
	_job_annotations 135649511127 0 "$(printf '%s\n' "$EXIT_1" "$matrix" "$EXIT_1" "$STARTUP_MESSAGE")"
	run bash "$SCRIPT"
	assert_success
	assert_equal "1" "$(_call_count "$RERUN_CALLS")"
}

@test "rerun-on-infra-failure: the matrix gate's message without that step failing is not re-run" {
	local matrix='A matrix test leg failed or its results could not be aggregated; failing the check.'
	_startup_case
	_job_annotations 135649511127 0 "$(printf '%s\n' "$EXIT_1" "$matrix" "$STARTUP_MESSAGE")"
	run bash "$SCRIPT"
	assert_success
	[ ! -s "$RERUN_CALLS" ]
}

@test "rerun-on-infra-failure: a DNS REFUSED (status 5) at agent start-up is re-run" {
	_startup_case
	_probe_job_log 135649511127 0 "$(sed 's/, status 2$/, status 5/' "${FIXTURES}/job-startup-dns.log")"
	run bash "$SCRIPT"
	assert_success
	assert_equal "1" "$(_call_count "$RERUN_CALLS")"
}

@test "rerun-on-infra-failure: a different agent failure with the same shape is not re-run" {
	_mock_gh "actionlint	Verify harden-runner agent	##[error]agent.status is not Initialized after 60s"
	_agent_jobs 0 "$(_compact "$STARTUP_JOB")"
	_job_annotations 135649511127 0 "$(printf '%s\n' "$EXIT_1" 'agent.status is not Initialized after 60s')"
	_probe_job_log 135649511127 0 "$(cat "${FIXTURES}/job-startup-dns.log")"
	run bash "$SCRIPT"
	assert_success
	[ ! -s "$RERUN_CALLS" ]
	assert_output --partial "No infra signature matched"
	# The annotations ruled it out, so the raw log was never read.
	run grep -c '/actions/jobs/135649511127/logs' "$API_CALLS"
	assert_output 0
}

@test "rerun-on-infra-failure: the start-up message without DNS SERVFAIL evidence is not re-run" {
	_startup_case
	# NXDOMAIN (a host that does not exist) fails the same way every time.
	_probe_job_log 135649511127 0 "$(sed 's/, status 2$/, status 3/' "${FIXTURES}/job-startup-dns.log")"
	run bash "$SCRIPT"
	assert_success
	[ ! -s "$RERUN_CALLS" ]
	assert_output --partial "No infra signature matched"
}

@test "rerun-on-infra-failure: a job step printing the start-up message is not re-run" {
	# A test step printed the annotation; the verify step passed.
	local job
	job="$(jq -c '.steps |= map(if .name == "Verify harden-runner agent" then .conclusion = "success"
		elif .name == "Classify lint timeout" then .conclusion = "failure" else . end)' <<<"$STARTUP_JOB")"
	_startup_case
	_agent_jobs 0 "$job"
	run bash "$SCRIPT"
	assert_success
	[ ! -s "$RERUN_CALLS" ]
	run grep -c 'check-runs/135649511127/annotations' "$JOBS_CALLS"
	assert_output 0
}

@test "rerun-on-infra-failure: an unreadable job log keeps the start-up failure un-run" {
	_startup_case
	_probe_job_log 135649511127 1 ""
	run bash "$SCRIPT"
	assert_success
	[ ! -s "$RERUN_CALLS" ]
	assert_output --partial "Reading the log of job 135649511127"
}

@test "rerun-on-infra-failure: a failed listing for the agent check is not a match" {
	_startup_case
	_agent_jobs 1 ""
	run bash "$SCRIPT"
	assert_success
	[ ! -s "$RERUN_CALLS" ]
	assert_output --partial "for the harden-runner agent check exited 1"
}

@test "rerun-on-infra-failure: AGENT_CHECK_MAX_JOBS=0 disables the agent check" {
	_startup_case
	export AGENT_CHECK_MAX_JOBS=0
	run bash "$SCRIPT"
	assert_success
	[ ! -s "$RERUN_CALLS" ]
	[ ! -s "$AGENT_CALLS" ]
}

@test "rerun-on-infra-failure: AGENT_CHECK_MAX_JOBS must be a non-negative integer" {
	_startup_case
	export AGENT_CHECK_MAX_JOBS=many
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "AGENT_CHECK_MAX_JOBS must be a non-negative integer"
}

@test "rerun-on-infra-failure: a protected job is never re-run on an agent failure either" {
	_startup_case
	_failed_jobs 0 $'135649511127\tPublish package\t4'
	run bash "$SCRIPT"
	assert_success
	[ ! -s "$RERUN_CALLS" ]
	[ ! -s "$AGENT_CALLS" ]
}

# --- attempt 1 only, whatever MAX_RERUNS allows (#1616 review) -------------

@test "rerun-on-infra-failure: the start-up rule re-runs attempt 1 under MAX_RERUNS=3" {
	_startup_case
	export MAX_RERUNS=3 RUN_ATTEMPT=1
	run bash "$SCRIPT"
	assert_success
	assert_equal "1" "$(_call_count "$RERUN_CALLS")"
}

@test "rerun-on-infra-failure: the start-up rule never re-runs attempt 2 or 3, even under MAX_RERUNS=3" {
	local attempt
	for attempt in 2 3; do
		_startup_case
		export MAX_RERUNS=3 RUN_ATTEMPT="$attempt"
		run bash "$SCRIPT"
		assert_success
		[ ! -s "$RERUN_CALLS" ]
		assert_output --partial "is on attempt ${attempt}; the harden-runner agent start-up rule re-runs attempt 1 only"
		# Decided before any job, annotation or log was read.
		[ ! -s "$AGENT_CALLS" ]
		run grep -c '/actions/jobs/135649511127/logs' "$API_CALLS"
		assert_output 0
	done
}

@test "rerun-on-infra-failure: attempt 2 with an empty failed-job log is not re-run on the start-up rule" {
	_mock_sleep
	_mock_gh_attempts "0:"
	_agent_jobs 0 "$(_compact "$STARTUP_JOB")"
	_job_annotations 135649511127 0 "$(printf '%s\n' "$EXIT_2" "$EXIT_1" "$STARTUP_MESSAGE")"
	_probe_job_log 135649511127 0 "$(cat "${FIXTURES}/job-startup-dns.log")"
	export MAX_RERUNS=3 RUN_ATTEMPT=2
	run bash "$SCRIPT"
	assert_success
	[ ! -s "$RERUN_CALLS" ]
}

# --- the agent stopped enforcing mid-job: always a real failure ------------

@test "rerun-on-infra-failure: a mid-job recheck failure after the TLS-status fallback is not re-run" {
	# Fixture run 44565576621: a genuine fallback cannot rule out a later step
	# that changed DNS or enforcement state, so it stays real until #1668.
	_recheck_case
	run bash "$SCRIPT"
	assert_success
	[ ! -s "$RERUN_CALLS" ]
	assert_output --partial "No infra signature matched"
	# No agent shape: neither annotations nor the job log were read.
	run grep -c 'check-runs/135707070821/annotations' "$JOBS_CALLS"
	assert_output 0
	run grep -c '/actions/jobs/135707070821/logs' "$API_CALLS"
	assert_output 0
}
