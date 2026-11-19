#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Single source of the transient-infrastructure failure signatures
#          and the fixed-string matcher used to classify a failed run as a
#          likely transient (infrastructure) failure.
#
# Consumers:
#   - scripts/ci/actions/rerun-on-infra-failure.sh (the auto re-run safety net)
#   - scripts/ci/release/report-release-failure.sh (release-mode notifier:
#     while an automatic re-run may still fire, a failure must not file a
#     "retries exhausted" issue yet)
#   - scripts/ci/canary/runs.sh (external consumer canary: infra_canary_signatures,
#     matched against check-run annotations, decides whether a failed
#     fixture gate is re-dispatched once, #1475)
#
# This is a sourced library, not an entrypoint (see the script-test coverage
# ratchet). It sources cosign.sh for COSIGN_OIDC_TRANSIENT_MARKERS, which is
# side-effect-free (a load guard, function definitions, and two numeric
# defaults).

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=cosign.sh
source "$LIB_DIR/cosign.sh"

# Known transient infra failure signatures (fixed strings, one per line).
#
# The trailing cosign markers are the ambient-OIDC flake class that
# scripts/ci/lib/cosign.sh already retries in-step. The in-step retry is the
# fast path; this matcher is the slow path for when that retry is exhausted
# and the publish fails outright. Without them a persistent OIDC flake burned
# its retries and then matched nothing here, leaving a human to press re-run
# (#719).
#
# Egress refusals are deliberately NOT signatures. Under harden-runner's block
# policy a host missing from the allowlist fails the same way on every attempt
# ("Error resolving allowed domain", "connection refused", ECONNREFUSED, …), so
# re-running never helps and, on a publish workflow, re-runs jobs that already
# published (#967: the v0.160.3rc1 publish run was re-run into the npm
# approval gate on exactly that line). A caller that knows a refusal is
# transient in its own environment can still add it through INFRA_SIGNATURES.
# The harden-runner agent rule below (#1616) is not an exception: it reads
# the agent's own start-up DNS failure (SERVFAIL, status 2, or REFUSED,
# status 5) from harden-runner's own output before any job step, never a
# step's refusal.
infra_default_signatures() {
	printf '%s\n' "Failed to resolve action download info"
	printf '%s\n' "The runner has received a shutdown signal"
	printf '%s\n' "lost communication with the server"
	printf '%s\n' "$COSIGN_OIDC_TRANSIENT_MARKERS"
}

# Infrastructure signatures of the external consumer canary (#1475), one per
# line as "<label><TAB><failed step name><TAB><annotation message ERE>".
# scripts/ci/canary/runs.sh reads a failed fixture job's check-run annotations
# (a job's id is its check-run id; the endpoint is served by api.github.com,
# so the canary needs no log storage host). An entry matches only when the
# job's only failed step has exactly that name and the job's failure
# annotations are one message matching the ERE plus at most GitHub's generic
# `Process completed with exit code N.`. Annotations carry no step reference,
# so that rule is what ties the message to the failed step. Each entry is an
# exact `::error::` message confirmed in a real fixture run; never add a
# generic "failed", an exit code or a test-runner message, because a product
# regression must fail the canary on its first attempt.
#
# Deliberately separate from infra_default_signatures: the auto re-run safety
# net re-runs lgtm-ci's own (publishing) workflows, and this list must not
# widen it. Egress refusals stay excluded here too: the Setup Bun
# `connect ECONNREFUSED 54.185.253.63:443` in fixture run 43037817354
# (egress.yml, dispatched by lgtm-ci run 43037263118) was harden-runner
# refusing release-assets.githubusercontent.com, which is not on that job's
# allowlist ("domain not allowed" in the same log), not an outage.
infra_canary_signatures() {
	# scripts/ci/docker/wait-for-harden-runner.sh: `docker info` exceeded its
	# deadline after harden-runner initialized (an `::error::` line; keep the
	# message in sync with that script). Fixture run 43070043408
	# (docker-publish.yml), job 130695209599, dispatched by lgtm-ci run
	# 43069706743 attempt 1.
	printf '%s\t%s\t%s\n' docker-readiness 'Wait for hardener Docker readiness' \
		'^Docker info timed out after harden-runner initialized \(10s deadline \+ 2s kill grace\)$'
	# apt-mirror: scripts/ci/lib/apt_helper.py (#1432) prints exactly one
	# `::error::` with NETWORK_ERROR_MESSAGE when apt still cannot reach a
	# mirror after its bounded retries (keep the pattern in sync with that
	# constant). Raw apt DNS failures were seen in fixture runs 43037513862
	# (run-playwright (direct)), 43038650658 (Install Playwright browsers) and
	# 43039395926 (Install musl toolchain), before the helper existed. One entry
	# per step that runs the helper: kcov in reusable-test-shell*, and the
	# e2e-matrix shard's `Run Playwright` (the run-playwright composite).
	local apt_mirror='^apt could not reach a package mirror \(DNS or network failure\) after all retries$'
	local step
	for step in 'Install musl toolchain' 'Install Playwright browsers' \
		'Install kcov for coverage' 'run-playwright (direct)' 'Run Playwright'; do
		printf '%s\t%s\t%s\n' apt-mirror "$step" "$apt_mirror"
	done
	# playwright-download: playwright_install_with_retry
	# (scripts/ci/lib/testing/playwright_runner.sh, #1563) prints this
	# `::error::` only when both bounded download attempts hit their timeout
	# (keep the pattern in sync with that function). A hung browser download
	# was seen in fixture run 43557274435 (`Install Playwright browsers`, 25
	# minutes until the canary budget cancelled it), before the bound existed.
	# An install that exits with an error prints a different message and is
	# never retried; only the step where the hang was seen is listed.
	# Exact message confirmed in fixture run 43572970694 (ubuntu-latest, GNU
	# timeout; macos-latest, fallback watchdog): "Playwright browser install
	# timed out twice (1s per attempt)" as the failure annotation of the
	# "Install Playwright browsers" step (#1563).
	printf '%s\t%s\t%s\n' playwright-download 'Install Playwright browsers' \
		'^Playwright browser install timed out twice \([0-9]+s per attempt\)$'
}

# harden-runner agent did not start (#1616). Fail-closed guards stay: a job
# whose agent is not verified never continues. This rule only decides whether
# such a failure is transient infrastructure, so the job may be re-run once
# (auto re-run, attempt 1 only) or the fixture retried once (canary). It needs
# three things to agree:
#
#   1. Job shape (INFRA_HR_SHAPE_JQ, a jq def over one job of the jobs API):
#      the first failed step is `Verify harden-runner agent` and every step
#      before it is `Set up job`, `Pre Harden runner` or `Harden runner`, all
#      `success`. No job step ran before the failure. Later `always()` steps
#      may run, and may fail, because nothing was checked out (fixture run
#      44546927992: `Summarize blocked egress` exited 127).
#   2. Failure annotations: exactly one message besides GitHub's
#      `Process completed with exit code N.` lines, and it is the exact
#      start-up message below, with one exit line per step that ran from the
#      verify step on: a continue-on-error step leaves its own exit line
#      (fixture run 44549619441: `Classify lint timeout` exited 2). The matrix
#      gate's own message is allowed once, only when the step `Fail if any
#      matrix leg failed` (an always() step of the reusable test workflows)
#      failed after the verify step: it fires whenever the aggregate did not
#      pass, so after a verify failure it fails whether or not a leg did
#      (fixture runs 44141287243 and 43995921467, where no leg failed). A leg
#      that did fail is its own failed job.
#   3. Job log evidence (auto re-run only; the canary has no log storage host
#      in its egress allowlist and does not read logs, see
#      scripts/ci/canary/runs.sh for how it treats a repeat): the agent's own
#      timestamped `Error resolving allowed domain error in response from
#      <resolver> unable to resolve domain <host>., status 2` (or `status 5`),
#      printed by harden-runner itself (infra_harden_runner_log_evidence for
#      the provenance rules). The pinned agent (v0.18.0) resolves every
#      allowed host at start and exits on one DNS failure. Status 2 (SERVFAIL)
#      and 5 (REFUSED, seen for files.pythonhosted.org and auth.docker.io in
#      fixture runs 43983818529 and 43924199865) are transient answers from
#      the resolver; status 3 (NXDOMAIN, a host that does not exist) and every
#      other agent failure do not match. Seen in lgtm-ci run 44070832319 and
#      fixture runs 44546927992 (job 135640146414) and 44549619441 (job
#      135649511127). harden-runner waits only 9 seconds for the agent: when
#      the agent fails later, its error is printed only in the post step, after
#      job steps ran, and does not count (fixture run 43858549864).
#
# A failed end-of-job `Recheck harden-runner agent` (the agent stopped
# enforcing mid-job) is never infrastructure here. Its known benign cause,
# harden-runner's TLS-status fallback to the eBPF agent (fixture run
# 44565576621), cannot be told apart from a later step that changed DNS or
# enforcement state, so it stays a real failure until #1668 refuses that
# agent at job start.
INFRA_HR_VERIFY_STEP='Verify harden-runner agent'
# Keep in sync with scripts/ci/bootstrap/verify-harden-runner-agent.sh.
INFRA_HR_STARTUP_MESSAGE='agent.service is not active; egress is not enforced'
# Keep in sync with the `Fail if any matrix leg failed` step of the reusable
# test workflows (reusable-test-python.yml and its siblings).
INFRA_HR_MATRIX_STEP='Fail if any matrix leg failed'
INFRA_HR_MATRIX_MESSAGE='A matrix test leg failed or its results could not be aggregated; failing the check.'
# The canary's label for this rule (scripts/ci/canary/runs.sh).
INFRA_HR_CANARY_LABEL='harden-runner-agent-startup'
# jq def: `hr_agent_shape` on one job object yields ["agent-startup", N, M]
# (N: non-post steps that ran after the verify step; M: 1 when the matrix
# gate step failed after it, else 0), and nothing for any other job.
# shellcheck disable=SC2016 # $s and $f are jq variables, not shell ones.
INFRA_HR_SHAPE_JQ='def hr_agent_shape:
	([(.steps // [])[]] | sort_by(.number)) as $s
	| [range(0; $s | length) | select($s[.].conclusion == "failure")] as $f
	| if ($f | length) == 0 then empty
	elif $s[$f[0]].name == "Verify harden-runner agent" and $f[0] > 0
		and all($s[:$f[0]][]; (.name | IN("Set up job", "Pre Harden runner", "Harden runner"))
			and .conclusion == "success")
		and any($s[:$f[0]][]; .name == "Harden runner") then
		["agent-startup", ([$s[($f[0] + 1):][]
			| select(.conclusion != null and .conclusion != "skipped"
				and (.name | type) == "string" and (.name | startswith("Post ") | not)
				and .name != "Complete job")] | length),
			(if any($s[($f[0] + 1):][]; .name == "Fail if any matrix leg failed"
				and .conclusion == "failure") then 1 else 0 end)]
	else empty end;'

# Print "agent-startup\t<steps after>\t<matrix gate failed>" for the job JSON
# object on stdin when its shape is a harden-runner agent start-up failure;
# return 1 otherwise.
infra_harden_runner_shape() {
	local shape
	shape="$(jq -r "${INFRA_HR_SHAPE_JQ} hr_agent_shape | map(tostring) | join(\"\t\")" 2>/dev/null)" || return 1
	[[ "$shape" == agent-startup$'\t'* ]] || return 1
	printf '%s\n' "$shape"
}

# Return 0 when the failure annotation messages on stdin (one per line) are
# exactly the start-up message plus at most the allowed number of exit-code
# lines. $1 is the kind (agent-startup is the only one), $2 the number of
# steps that ran after the verify step and $3 1 when the matrix gate step
# failed after it (the shape's second and third fields). A message spanning
# lines splits into extra messages and fails closed.
infra_harden_runner_annotations() {
	local kind="${1:-}" after="${2:-0}" matrix="${3:-0}" max line
	local own=0 own_ok=0 gate=0 exits=0
	[[ "$kind" == agent-startup && "$after" =~ ^[0-9]+$ && "$matrix" =~ ^[01]$ ]] || return 1
	max=$((after + 1))
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line%$'\r'}"
		[[ -n "$line" ]] || continue
		if [[ "$line" =~ ^Process\ completed\ with\ exit\ code\ [0-9]+\.$ ]]; then
			exits=$((exits + 1))
		elif ((matrix == 1)) && [[ "$line" == "$INFRA_HR_MATRIX_MESSAGE" ]]; then
			gate=$((gate + 1))
		else
			own=$((own + 1))
			[[ "$line" == "$INFRA_HR_STARTUP_MESSAGE" ]] && own_ok=1
		fi
	done
	((own == 1 && own_ok == 1 && gate <= 1 && exits <= max))
}

# Return 0 when the raw job log on stdin carries start-up evidence ($1:
# agent-startup) inside harden-runner's own output; fail closed whenever that
# provenance cannot be established.
#
# Every line of a job log is text, and the runner prints caller-controlled
# text verbatim: a `run:` step's caption is its script's first line, and an
# action's details group (`with:` inputs, `env:`) prints multi-line values as
# raw lines (actions/runner v2.338.2 ScriptHandler.cs, Handler.cs). So a line
# counts only in harden-runner's own output, established structurally:
#   - an action group is `##[group]Run step-security/harden-runner@<40 hex>`
#     immediately followed by `with:` (a `run:` step's group continues with
#     its echoed script, so its caption cannot pass); a local composite or
#     any other action opens a `##[group]Run <other>` group, which ends the
#     search;
#   - the details group up to `##[endgroup]` never counts;
#   - the output region opens only on the line right after that
#     `##[endgroup]`, which must be `[harden-runner] pre-step` (first group)
#     or `[harden-runner] main-step` (second group), and closes at the next
#     `##[group]` line. `Set up job`, the runner configuration dumps and
#     `Initialize containers` lie outside it;
#   - an `##[endgroup]` or a repeated marker inside an output region, any
#     other group between the two harden-runner steps, or a log that ends
#     before the first other step, fails closed;
#   - the whole log must hold exactly two harden-runner captions, one
#     pre-step marker and one main-step marker. A value in the details that
#     forges `##[endgroup]`, a marker or a caption cannot remove the runner's
#     own copies, which still follow it, so a forgery always fails closed.
infra_harden_runner_log_evidence() {
	[[ "${1:-}" == agent-startup ]] || return 1
	# POSIX classes and repeated brackets only: mawk (Ubuntu's awk) has no
	# interval expressions. The first line may carry a byte-order mark.
	LC_ALL=C awk '
		function fail() { bad = 1; done = 1 }
		BEGIN { prefix = "##[group]Run step-security/harden-runner@" }
		{
			line = $0
			sub(/\r$/, "", line)
			sub(/^[^0-9]*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z /, "", line)
			caption = index(line, prefix) == 1 && length(line) == length(prefix) + 40 &&
				substr(line, length(prefix) + 1) ~ /^[0-9a-f]+$/
			if (caption) captions++
			if (line == "[harden-runner] pre-step") pres++
			if (line == "[harden-runner] main-step") mains++
		}
		done { next }
		state == "output" && index(line, "##[group]") == 1 { state = "" }
		state == "" {
			if (caption) {
				if (seen >= 2) fail(); else { seen++; state = "caption" }
			} else if (index(line, "##[group]Run ") == 1) {
				reached = 1
				done = 1
			} else if (seen > 0 && index(line, "##[group]") == 1) {
				fail()
			} else if (line == "[harden-runner] pre-step" || line == "[harden-runner] main-step") {
				fail()
			}
			next
		}
		state == "caption" { if (line == "with:") state = "details"; else fail(); next }
		state == "details" {
			if (line == "##[endgroup]") state = "marker"
			else if (index(line, "##[group]") == 1) fail()
			next
		}
		state == "marker" {
			if (seen == 1 && line == "[harden-runner] pre-step") state = "output"
			else if (seen == 2 && line == "[harden-runner] main-step") state = "output"
			else fail()
			next
		}
		state == "output" {
			if (line == "##[endgroup]" || line == "[harden-runner] pre-step" ||
				line == "[harden-runner] main-step") fail()
			else if (line ~ /^[A-Z][a-z][a-z], [0-9][0-9] [A-Z][a-z][a-z] [0-9][0-9][0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] [A-Z]+:Error resolving allowed domain error in response from [^ ]+ unable to resolve domain [^ ]+, status [25]$/) found = 1
			next
		}
		END {
			exit !(found && reached && !bad && seen == 2 && captions == 2 && pres == 1 && mains == 1)
		}
	'
}

# Runner-acquisition failures ("The job repeatedly failed to be acquired
# (5 attempts)") never start the job, so they leave no step log for the
# fixed-string matcher above to read; GitHub reports them as a check-run
# annotation on the job instead. These markers are matched against those
# annotation messages, case-insensitively because the wording is GitHub's UI
# copy rather than a program's output.
INFRA_RUNNER_ACQUISITION_MARKERS="failed to be acquired
failed to acquire
was not acquired"
export INFRA_RUNNER_ACQUISITION_MARKERS
readonly INFRA_RUNNER_ACQUISITION_MARKERS

# Build the effective signature list: defaults plus optional INFRA_SIGNATURES
# extensions (newline-separated fixed strings), blank lines dropped.
#
# The environment variable is named INFRA_SIGNATURES rather than reusing the
# auto-rerun script's SIGNATURES so each consumer keeps its own extension
# input without the two clobbering each other when both are set.
infra_build_signatures() {
	local extra="${INFRA_SIGNATURES:-}"
	infra_default_signatures
	if [[ -n "$extra" ]]; then
		printf '%s\n' "$extra"
	fi
}

# Print the first signature found in the logs given as $1; return 1 when none
# match.
#
# Matching stays case-sensitive (#719). Every signature is stored in the exact
# case its source emits — including the cosign markers — so case-insensitive
# matching would buy no extra true positives, while widening what auto-rerun
# fires on across ALL signatures, not just the OIDC ones. The cost of a false
# positive here is re-running a workflow that may have failed for real; the
# cost of a miss is the pre-#719 status quo of a human pressing re-run. Strict
# is the safe default for the safety net.
infra_match_signature() {
	local logs="$1" signature
	while IFS= read -r signature; do
		[[ -z "$signature" ]] && continue
		if grep -qF -- "$signature" <<<"$logs"; then
			printf '%s\n' "$signature"
			return 0
		fi
	done < <(infra_build_signatures)
	return 1
}

# Print the first runner-acquisition marker present in the annotation text
# given as $1; return 1 when none match.
infra_match_acquisition_annotation() {
	local text="$1" marker
	while IFS= read -r marker; do
		[[ -z "$marker" ]] && continue
		if grep -qiF -- "$marker" <<<"$text"; then
			printf '%s\n' "$marker"
			return 0
		fi
	done <<<"$INFRA_RUNNER_ACQUISITION_MARKERS"
	return 1
}
