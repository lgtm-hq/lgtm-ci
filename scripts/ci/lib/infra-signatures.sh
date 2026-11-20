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

# Known transient infra failure signatures (fixed strings, one per line),
# matched anywhere in the failed-job logs. These are runner messages.
#
# The cosign ambient-OIDC markers (COSIGN_OIDC_TRANSIENT_MARKERS) are not in
# this list: see infra_match_cosign_exhausted. They are the flake class that
# scripts/ci/lib/cosign.sh already retries in-step; the in-step retry is the
# fast path, and the slow path here covers a publish that failed because that
# retry was exhausted (#719). As fixed strings matched anywhere they also
# matched any job that printed them, and the passing cosign tests of this
# repository's own shell-test job print all three: run 44749053360 failed on
# one ordinary failing test, matched `fetching ambient OIDC credentials` in a
# passing test's output, and was re-run (#1706).
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
# status 5) from harden-runner's own output or the verify step's, both before
# any job step, never a step's refusal.
infra_default_signatures() {
	printf '%s\n' "Failed to resolve action download info"
	printf '%s\n' "The runner has received a shutdown signal"
	printf '%s\n' "lost communication with the server"
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
	# apt-install-timeout: scripts/ci/lib/apt_helper.py prints TIMEOUT_ERROR_MESSAGE
	# for `apt-get install` when every attempt hit its deadline (#1571; keep the
	# pattern in sync with that constant). Exact message confirmed in the
	# consumer fixture's actions-direct.yml, job playwright, step
	# `run-playwright (direct)`: fixture runs 44502323850, 44522476762 and
	# 44524211464 (2026-11-19), 44714808270, 44725802818 and 44743903836
	# (2026-11-20), each "apt-get install timed out (100s per attempt, 300s per
	# helper run)" with exit code 124. In every one the archive mirror sent
	# the 21.9 MB of Playwright's nine font packages at about 30 to 120 kB/s;
	# the same job downloads them in 0 to 17 s from a healthy mirror (#1697).
	# A slow mirror and a candidate that breaks the install read the same
	# without a log, so a second occurrence in one canary is a gate failure
	# (apt_install_timeout_repeated in scripts/ci/canary/runs.sh). The
	# `did not start` variant (the budget spent before the install) and
	# `apt-get update timed out` are not listed: neither has been seen.
	printf '%s\t%s\t%s\n' apt-install-timeout 'run-playwright (direct)' \
		'^apt-get install timed out \([0-9]+s per attempt, [0-9]+s per helper run\)$'
}

# harden-runner agent did not start (#1616), or harden-runner installed its
# eBPF fallback agent (#1668). Fail-closed guards stay: a job whose agent is
# not verified never continues, and the eBPF agent is never trusted. This rule
# only decides whether such a failure is transient infrastructure, so the job
# may be re-run once (auto re-run, attempt 1 only) or the fixture retried
# once (canary). It has two causes and needs three things to agree:
#
#   1. Job shape (INFRA_HR_SHAPE_JQ, a jq def over one job of the jobs API),
#      the same for both causes: the first failed step is `Verify
#      harden-runner agent` and every step before it is `Set up job`, `Pre
#      Harden runner` or `Harden runner`, all `success`. No job step ran
#      before the failure. Later `always()` steps may run, and may fail,
#      because nothing was checked out (fixture run 44546927992: `Summarize
#      blocked egress` exited 127).
#   2. Failure annotations: exactly one message besides GitHub's
#      `Process completed with exit code N.` lines, and it is the exact
#      message of one cause below (infra_harden_runner_cause), with one exit
#      line per step that ran from the verify step on: a continue-on-error
#      step leaves its own exit line (fixture run 44549619441: `Classify lint
#      timeout` exited 2). The matrix gate's own message is allowed once, only
#      when the step `Fail if any matrix leg failed` (an always() step of the
#      reusable test workflows) failed after the verify step: it fires
#      whenever the aggregate did not pass, so after a verify failure it fails
#      whether or not a leg did (fixture runs 44141287243 and 43995921467,
#      where no leg failed). A leg that did fail is its own failed job.
#   3. Job log evidence of that cause (auto re-run only; the canary has no
#      log storage host in its egress allowlist and does not read logs, see
#      scripts/ci/canary/runs.sh for how it treats a repeat), in output no job
#      step can have printed (infra_harden_runner_log_evidence for the
#      provenance rules).
#
# Cause agent-startup, annotation INFRA_HR_STARTUP_MESSAGE: the agent's own
# timestamped `Error resolving allowed domain error in response from
# <resolver> unable to resolve domain <host>., status 2` (or `status 5`). The
# pinned agent (v0.18.0) resolves every allowed host at start and exits on
# one DNS failure. Status 2 (SERVFAIL) and 5 (REFUSED, seen for
# files.pythonhosted.org and auth.docker.io in fixture runs 43983818529 and
# 43924199865) are transient answers from the resolver; status 3 (NXDOMAIN, a
# host that does not exist) and every other agent failure do not match. The
# line counts in harden-runner's own output (lgtm-ci run 44070832319, fixture
# runs 44546927992 and 44549619441) or, prefixed with
# INFRA_HR_AGENT_LOG_PREFIX, in the verify step's own output (#1669).
# harden-runner waits only 9 seconds for the agent: an agent that fails later
# (fixture runs 43858549864, 43924199865 and 43983818529) is reported by the
# verify step, which prints the agent's own start-up errors when it finds the
# agent inactive, before any job step ran. A copy of the line printed by any
# later step, including harden-runner's post step, never counts.
#
# Cause agent-ebpf, annotation INFRA_HR_EBPF_MESSAGE (#1668): when its
# TLS-status call fails, harden-runner v2.22.3 prints INFRA_HR_TLS_FALLBACK_LINE
# (src/tls-inspect.ts) in its pre-step and installs the eBPF agent v1.9.5 in
# place of v0.18.0 (src/install-agent.ts). Before #1668 that agent reached
# the end-of-job recheck and failed it there (fixture runs 44565576621 and
# 44396392356, lgtm-ci run 44249154883); the verify step now refuses it at
# job start. The evidence is that line in harden-runner's own pre-step
# output. The re-run usually gets the standard agent.
#
# A failed end-of-job `Recheck harden-runner agent` (the agent stopped
# enforcing mid-job) is never infrastructure here: no benign cause is known
# once the verify step has refused the eBPF agent, and a later step that
# changed DNS or enforcement state fails it the same way.
INFRA_HR_VERIFY_STEP='Verify harden-runner agent'
# Keep these four in sync with scripts/ci/bootstrap/verify-harden-runner-agent.sh:
# its two annotation messages, the prefix of the agent.log lines it prints,
# and the step's caption in a job log (its script's first line).
INFRA_HR_STARTUP_MESSAGE='agent.service is not active; egress is not enforced'
INFRA_HR_EBPF_MESSAGE='harden-runner installed its eBPF fallback agent; only the standard agent is trusted'
INFRA_HR_AGENT_LOG_PREFIX='verify-harden-runner-agent: agent.log: '
INFRA_HR_VERIFY_CAPTION='##[group]Run # lgtm-ci-inline:begin verify-harden-runner-agent'
# harden-runner v2.22.3 src/tls-inspect.ts, printed when its TLS-status call
# fails.
INFRA_HR_TLS_FALLBACK_LINE='[!] Unable to check TLS_STATUS. Defaulting to TLS enabled.'
# Keep in sync with the `Fail if any matrix leg failed` step of the reusable
# test workflows (reusable-test-python.yml and its siblings).
INFRA_HR_MATRIX_STEP='Fail if any matrix leg failed'
INFRA_HR_MATRIX_MESSAGE='A matrix test leg failed or its results could not be aggregated; failing the check.'
# The canary's labels for this rule (scripts/ci/canary/runs.sh), one per cause.
INFRA_HR_CANARY_LABEL='harden-runner-agent-startup'
INFRA_HR_EBPF_CANARY_LABEL='harden-runner-agent-ebpf'
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
# exactly the cause's own message plus at most the allowed number of
# exit-code lines. $1 is the cause: agent-startup (INFRA_HR_STARTUP_MESSAGE)
# or agent-ebpf (INFRA_HR_EBPF_MESSAGE); $2 the number of steps that ran
# after the verify step and $3 1 when the matrix gate step failed after it
# (the shape's second and third fields). A message spanning lines splits into
# extra messages and fails closed.
infra_harden_runner_annotations() {
	local cause="${1:-}" after="${2:-0}" matrix="${3:-0}" max line expected
	local own=0 own_ok=0 gate=0 exits=0
	case "$cause" in
	agent-startup) expected="$INFRA_HR_STARTUP_MESSAGE" ;;
	agent-ebpf) expected="$INFRA_HR_EBPF_MESSAGE" ;;
	*) return 1 ;;
	esac
	[[ "$after" =~ ^[0-9]+$ && "$matrix" =~ ^[01]$ ]] || return 1
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
			[[ "$line" == "$expected" ]] && own_ok=1
		fi
	done
	((own == 1 && own_ok == 1 && gate <= 1 && exits <= max))
}

# Print the cause (agent-startup or agent-ebpf) whose annotations the
# messages on stdin are, for the shape fields $1 (steps after the verify
# step) and $2 (matrix gate failed); return 1 when they are neither.
infra_harden_runner_cause() {
	local messages cause
	messages="$(cat)"
	for cause in agent-startup agent-ebpf; do
		if infra_harden_runner_annotations "$cause" "${1:-}" "${2:-}" <<<"$messages"; then
			printf '%s\n' "$cause"
			return 0
		fi
	done
	return 1
}

# Return 0 when the raw job log on stdin carries the evidence of cause $1
# (agent-startup or agent-ebpf) where no job step can have printed it; fail
# closed whenever that provenance cannot be established.
#
# Every line of a job log is text, and the runner prints caller-controlled
# text verbatim: a `run:` step's caption is its script's first line, and an
# action's details group (`with:` inputs, `env:`) prints multi-line values as
# raw lines (actions/runner v2.338.2 ScriptHandler.cs, Handler.cs). So a line
# counts only in output whose provenance is structural.
#
# harden-runner's own output:
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
#
# agent-startup: the agent's own timestamped `Error resolving allowed domain
# error in response from <resolver> unable to resolve domain <host>., status
# 2` (or `status 5`) line, either
#   - in either harden-runner output region (harden-runner prints agent.log
#     when the agent fails within its 9-second wait), or
#   - (#1669) prefixed with INFRA_HR_AGENT_LOG_PREFIX in the output of the
#     `Verify harden-runner agent` step itself, which prints the agent's own
#     start-up errors when it finds the agent inactive, before any job step
#     ran. That output is located the same strict way: the first other group
#     after harden-runner's main-step output must be the verify step's
#     caption (INFRA_HR_VERIFY_CAPTION, its script's fixed first line); its
#     details group (the echoed script, `shell:`, `env:`) never counts and
#     must hold no other group; its output opens right after that
#     `##[endgroup]` and closes at the next `##[group]` line or at the
#     runner's `Post job cleanup.` line, which opens every post step
#     (actions/runner Handler.cs PrintActionDetails); it must close before
#     the log ends. Inside it an `##[endgroup]` fails closed, and the
#     prefixed line must come before the step's own `##[error]` line for the
#     start-up message, which must be inside it. The whole log must hold
#     exactly one verify caption and one such `##[error]` line. A value in
#     the verify step's details that forges `##[endgroup]` either leaves the
#     runner's own `##[endgroup]` inside the output or moves the step's own
#     `##[error]` line out of it, and a later step that prints the caption or
#     the `##[error]` line adds a second copy, so a forgery always fails
#     closed. A prefixed line printed by any later step lies outside the
#     region and never counts.
# agent-ebpf (#1668): harden-runner's own `[!] Unable to check TLS_STATUS.
# Defaulting to TLS enabled.` (v2.22.3 src/tls-inspect.ts) in its pre-step
# output region, where it decides which agent to install.
infra_harden_runner_log_evidence() {
	local cause="${1:-}"
	[[ "$cause" == agent-startup || "$cause" == agent-ebpf ]] || return 1
	# POSIX classes and repeated brackets only: mawk (Ubuntu's awk) has no
	# interval expressions. The first line may carry a byte-order mark.
	LC_ALL=C awk -v cause="$cause" -v vcap="$INFRA_HR_VERIFY_CAPTION" \
		-v vprefix="$INFRA_HR_AGENT_LOG_PREFIX" \
		-v verr="##[error]${INFRA_HR_STARTUP_MESSAGE}" \
		-v tls="$INFRA_HR_TLS_FALLBACK_LINE" '
		function fail() { bad = 1; done = 1 }
		BEGIN {
			prefix = "##[group]Run step-security/harden-runner@"
			dns = "^[A-Z][a-z][a-z], [0-9][0-9] [A-Z][a-z][a-z] [0-9][0-9][0-9][0-9] "
			dns = dns "[0-9][0-9]:[0-9][0-9]:[0-9][0-9] [A-Z]+:Error resolving allowed domain "
			dns = dns "error in response from [^ ]+ unable to resolve domain [^ ]+, status [25]$"
			phase = "hr"
		}
		{
			line = $0
			sub(/\r$/, "", line)
			sub(/^[^0-9]*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z /, "", line)
			caption = index(line, prefix) == 1 && length(line) == length(prefix) + 40 &&
				substr(line, length(prefix) + 1) ~ /^[0-9a-f]+$/
			if (caption) captions++
			if (line == "[harden-runner] pre-step") pres++
			if (line == "[harden-runner] main-step") mains++
			if (line == vcap) vcaps++
			if (line == verr) verrs++
		}
		done { next }
		phase == "hr" && state == "output" && index(line, "##[group]") == 1 { state = "" }
		phase == "hr" && state == "" {
			if (caption) {
				if (seen >= 2) fail(); else { seen++; state = "caption" }
			} else if (index(line, "##[group]Run ") == 1) {
				reached = 1
				phase = (seen == 2 && line == vcap) ? "vdetails" : "after"
			} else if (seen > 0 && index(line, "##[group]") == 1) {
				fail()
			} else if (line == "[harden-runner] pre-step" || line == "[harden-runner] main-step") {
				fail()
			}
			next
		}
		phase == "hr" && state == "caption" { if (line == "with:") state = "details"; else fail(); next }
		phase == "hr" && state == "details" {
			if (line == "##[endgroup]") state = "marker"
			else if (index(line, "##[group]") == 1) fail()
			next
		}
		phase == "hr" && state == "marker" {
			if (seen == 1 && line == "[harden-runner] pre-step") state = "output"
			else if (seen == 2 && line == "[harden-runner] main-step") state = "output"
			else fail()
			next
		}
		phase == "hr" && state == "output" {
			if (line == "##[endgroup]" || line == "[harden-runner] pre-step" ||
				line == "[harden-runner] main-step") fail()
			else if (cause == "agent-startup" && line ~ dns) found = 1
			else if (cause == "agent-ebpf" && seen == 1 && line == tls) found = 1
			next
		}
		phase == "vdetails" {
			if (line == "##[endgroup]") phase = "voutput"
			else if (index(line, "##[group]") == 1) { vbad = 1; phase = "after" }
			next
		}
		phase == "voutput" {
			if (index(line, "##[group]") == 1 || line == "Post job cleanup.") {
				vclosed = 1
				phase = "after"
			} else if (line == "##[endgroup]") {
				vbad = 1
				phase = "after"
			} else if (index(line, vprefix) == 1 && substr(line, length(vprefix) + 1) ~ dns) {
				vfound = 1
			} else if (line == verr) {
				vown++
				if (vfound) vproven = 1
			}
			next
		}
		END {
			hr = reached && !bad && seen == 2 && captions == 2 && pres == 1 && mains == 1
			verify = vclosed && !vbad && vproven && vown == 1 && verrs == 1 && vcaps == 1
			if (cause == "agent-ebpf") exit !(hr && found)
			exit !(hr && (found || verify))
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
	infra_match_cosign_exhausted "$logs"
}

# Print the cosign OIDC marker of an exhausted in-step retry in the logs given
# as $1; return 1 when there is none (#1706).
#
# A marker counts only in the line cosign_sign_with_retry (cosign.sh) prints
# when it gives up, `[ERROR] <operation> failed for <target> after <N>
# attempt(s): transient OIDC failure persisted (matched '<marker>')`, with the
# marker one of COSIGN_OIDC_TRANSIENT_MARKERS (case-sensitive, like the rest),
# and only when the next non-blank line of the same job is GitHub's
# `##[error]Process completed with exit code <N>.`: the helper's `die` ended
# the step. The same line inside a test runner's output is followed by more
# output, so it never counts. Every signing script (sign-artifact.sh,
# sign-sbom-release-assets.sh, docker/sign-image.sh) signs through the helper.
#
# Reads `gh run view --log-failed` lines (`<job>\t<step>\t<timestamp> <text>`)
# and raw job log lines (`<timestamp> <text>`); colour codes are ignored.
infra_match_cosign_exhausted() {
	local logs="$1"
	INFRA_COSIGN_MARKERS="$COSIGN_OIDC_TRANSIENT_MARKERS" awk -v esc=$'\033' -v q="'" '
		BEGIN {
			n = split(ENVIRON["INFRA_COSIGN_MARKERS"], list, "\n")
			for (i = 1; i <= n; i++) if (list[i] != "") want[list[i]] = 1
			head = "transient OIDC failure persisted (matched " q
			tail = q ")"
			stamp = "^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9](\\.[0-9]+)?Z "
			color = esc "\\[[0-9;]*m"
			found = 0
		}
		{
			line = $0
			key = ""
			sub(/\r$/, "", line)
			if ((t = index(line, "\t")) > 0) {
				key = substr(line, 1, t - 1)
				line = substr(line, t + 1)
				if ((t = index(line, "\t")) > 0) line = substr(line, t + 1)
			}
			sub(stamp, "", line)
			gsub(color, "", line)
			if (line ~ /^##\[error\]Process completed with exit code [0-9]+\.$/ && key == pkey && pmarker != "") {
				print pmarker
				found = 1
				exit
			}
			if (line ~ /^[ \t]*$/) next
			pkey = key
			pmarker = ""
			if (line ~ /^\[ERROR\] .+ failed for .+ after [0-9]+ attempt\(s\): / && (p = index(line, head)) > 0) {
				m = substr(line, p + length(head))
				if (length(m) > length(tail) && substr(m, length(m) - length(tail) + 1) == tail) {
					m = substr(m, 1, length(m) - length(tail))
					if (m in want) pmarker = m
				}
			}
		}
		END { exit(found ? 0 : 1) }
	' <<<"$logs"
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
