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
#   - scripts/ci/canary/runs.sh (external consumer canary: infra_canary_signatures
#     decides whether a failed fixture gate is re-dispatched once, #1475)
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
infra_default_signatures() {
	printf '%s\n' "Failed to resolve action download info"
	printf '%s\n' "The runner has received a shutdown signal"
	printf '%s\n' "lost communication with the server"
	printf '%s\n' "$COSIGN_OIDC_TRANSIENT_MARKERS"
}

# Infrastructure signatures of the external consumer canary (#1475), one per
# line as "<label><TAB><extended regular expression>". scripts/ci/canary/runs.sh
# matches them against the log messages (timestamps stripped) of a fixture
# job's only failed step: on that step's first `##[error]` line or the few
# lines just before it, so a signature counts only when it is what ended the
# step. Each entry is an exact line confirmed in a real fixture log; never add
# a generic "failed", an exit code or a test-runner message, because a
# product regression must fail the canary on its first attempt.
#
# Deliberately separate from infra_default_signatures: the auto re-run safety
# net re-runs lgtm-ci's own (publishing) workflows, and this list must not
# widen it. Egress refusals stay excluded here too: the Setup Bun
# `connect ECONNREFUSED 54.185.253.63:443` in fixture run 43037817354
# (egress.yml, dispatched by lgtm-ci run 43037263118) was harden-runner
# refusing release-assets.githubusercontent.com, which is not on that job's
# allowlist ("domain not allowed" in the same log), not an outage.
infra_canary_signatures() {
	# apt aborting a package download because DNS failed for an Ubuntu mirror.
	# Fixture runs 43037513862 (actions-direct.yml, run-playwright),
	# 43038650658 (playwright.yml, Install Playwright browsers) and 43039395926
	# (rust-release-build.yml, Install musl toolchain), all dispatched by
	# lgtm-ci run 43037263118. Only apt's fatal `E:` line matches; the
	# `W: Failed to fetch` warnings of a degraded `apt-get update` do not.
	printf '%s\t%s\n' apt-dns "^E: Failed to fetch [^ ]+ +Temporary failure resolving '[^']+'\$"
	# scripts/ci/docker/wait-for-harden-runner.sh: `docker info` exceeded its
	# deadline after harden-runner initialized. Fixture run 43070043408
	# (docker-publish.yml, Wait for hardener Docker readiness), dispatched by
	# lgtm-ci run 43069706743 attempt 1.
	printf '%s\t%s\n' docker-readiness '^##\[error\]Docker info timed out after harden-runner initialized \('
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
