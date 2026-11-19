#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run the external consumer fixture against one lgtm-ci candidate SHA (#1074)
#
# Usage:
#   GH_TOKEN=<fixture App installation token> bash scripts/ci/actions/external-canary.sh <ref>
#
# The fixture (TurboCoder13/lgtm-ci-consumer-fixture) calls lgtm-ci only
# through `uses: lgtm-hq/lgtm-ci/.github/workflows/<file>.yml@<sha>` (and the
# direct composite-action form), pinned to one exact SHA in every workflow
# file. GitHub forbids expressions in `uses:`, so the fixture cannot take the
# candidate as a dispatch input. This script therefore:
#
#   0. decides whether to run at all (`decide_run_mode`): workflow_dispatch
#      always runs the full set; a pull request runs it when it carries the
#      force label or touches an adoption-relevant path (workflows, actions,
#      scripts/ci, schemas, examples); fork PRs, unrelated `labeled` events
#      and PRs without relevant changes exit 0 with a "skipped" summary so
#      the check always reports (no `paths:` filter),
#   1. resolves <ref> to a full lgtm-ci SHA (via the lgtm-ci API, LGTM_CI_TOKEN),
#   2. reads every fixture workflow file from the fixture's base branch,
#      rewrites each lgtm-ci pin to the candidate (same regex as the fixture's
#      scripts/pin.sh), refuses any lgtm-ci reference that is not then pinned
#      to the candidate, and commits the result through the git data API as
#      branch `canary/<sha>-<run-id>-<attempt>` — never touching the base branch,
#   3. checks every lgtm-ci path each workflow references, and every input
#      it passes to an lgtm-ci reusable (#1134), against the
#      candidate (`reference_verdict`, #1128): a path missing at the candidate
#      but present at its merge base with lgtm-ci main means the candidate
#      removes or renames a public interface (`removed_by_candidate`, fails
#      the canary for any role); a path missing at both but present on main
#      landed after the candidate branched (`not_applicable`: listed, not
#      dispatched, rebase suggested). Lookup errors fail closed,
#   4. dispatches every gate and informational fixture workflow that declares
#      `workflow_dispatch` on that branch (manual ones only when asked); a
#      negative-by-design workflow with a `<name>-probe.yml` companion is
#      reached only through that probe (`via_probe`),
#   5. polls the fixture's run list until each dispatched workflow has a
#      completed run with separate queue and execution budgets; a gate that
#      dies at startup, demonstrably in fixture setup, or in a step whose
#      check-run annotation is a confirmed infrastructure signature
#      (infra_canary_signatures, #1475) is re-dispatched once within the same
#      admission limit and queue budget (probes excluded); a dispatched run
#      GitHub never started (still `queued` with no job after
#      CANARY_REDISPATCH_AFTER_SECONDS) is dispatched once more and judged by
#      the new run, at most CANARY_MAX_REDISPATCHES times per canary (#1601),
#   6. writes a markdown table (workflow, role, expected, conclusion,
#      verdict, run URL) to $GITHUB_STEP_SUMMARY,
#   7. cancels owned unfinished runs; deletes the ref only once runs settle, and
#   8. exits non-zero when any GATE workflow did not succeed or any workflow
#      is `removed_by_candidate`, unless the owner-only override label (CANARY_OVERRIDE_LABEL) is on the pull
#      request, in which case the failure is reported as a warning.
#
# Roles (`classify_workflow`, contract-tested against the workflow header):
#   gate           must conclude `success`; the expected set is
#                  CANARY_EXPECTED_GATES, and a gate the fixture no longer
#                  exposes for dispatch is reported `not_dispatchable` and
#                  fails the canary (fail closed). Unknown workflows are gates.
#   informational  reported against an expected conclusion (`success` for the
#                  App-token / SBOM paths, the tooling App credential and the
#                  negative probes, `failure` /
#                  `startup_failure` for the negative-by-design workflows);
#                  never fails the canary. A negative-by-design run is red on
#                  the fixture's Actions page, and a job calling a reusable
#                  cannot take `continue-on-error`, so each negative has a
#                  `<name>-probe.yml` that dispatches it, asserts the designed
#                  failure (run conclusion and job evidence), deletes the red
#                  run after a pass and is itself green. When the probe exists
#                  the canary dispatches only the probe and lists the negative
#                  as `via_probe`; without one it dispatches the negative.
#   manual         the three reusable-release-version-pr callers: they share
#                  one fixture concurrency group, so concurrent dispatch
#                  cancels one of them, and each success opens a version PR in
#                  the fixture that a human closes. Not dispatched unless
#                  CANARY_INCLUDE_MANUAL=true; reported `not_dispatched`.
#
# Environment:
#   GH_TOKEN                 fixture token: installation token of the App
#                            lgtm-ci-fixture-release (secrets
#                            EXTERNAL_FIXTURE_APP_ID and
#                            EXTERNAL_FIXTURE_APP_PRIVATE_KEY), Actions,
#                            Contents and Workflows write on the fixture only
#                            (workflow files cannot be written without the
#                            Workflows permission)
#   LGTM_CI_TOKEN            token for the lgtm-ci repository (github.token):
#                            resolves <ref>, lists the PR's files, reads the
#                            referenced paths and the merge base; defaults to GH_TOKEN
#   LGTM_CI_MAIN_BRANCH      lgtm-ci branch for the merge-base comparison (default main)
#   GITHUB_REPOSITORY        lgtm-ci repository (default lgtm-hq/lgtm-ci)
#   EVENT_NAME               github.event_name (default workflow_dispatch)
#   EVENT_ACTION             github.event.action (pull_request: opened, labeled, ...)
#   EVENT_LABEL              github.event.label.name on `labeled` events
#   PR_NUMBER                pull request number (pull_request events)
#   PR_LABELS                comma-separated label names of the pull request
#   PR_HEAD_REPO_FORK        "true" when the PR head is a fork (secret unavailable)
#   CANARY_FORCE_LABEL       label forcing a full run (default needs-external-canary)
#   CANARY_OVERRIDE_LABEL    owner-only label turning gate failures into warnings
#                            (default canary-informational)
#   CANARY_RELEVANT_PATHS    space-separated path prefixes that make a PR
#                            adoption-relevant (default: see below)
#   CANARY_EXPECTED_GATES    space-separated gate workflow names (no .yml) that
#                            must be dispatchable (default: see below)
#   CANARY_INCLUDE_MANUAL    "true" also dispatches the manual release workflows
#   FIXTURE_REPO             default TurboCoder13/lgtm-ci-consumer-fixture
#   FIXTURE_BASE_BRANCH      default main (read only; never written)
#   CANARY_TIMEOUT_SECONDS   execution bound from first job start, default 1500
#   CANARY_QUEUE_TIMEOUT_SECONDS  admission/queue budget, default 1500 (blocking inconclusive for gates)
#   CANARY_MAX_IN_FLIGHT     dispatched workflow limit (including queued), default 6
#   CANARY_RETRY_INFRA       "true" (default) re-dispatches a gate once after
#                            startup_failure, jobs-API-proven setup failure or
#                            a failed step whose check-run annotation is a
#                            signature in infra_canary_signatures (#1475);
#                            never retries probes or other lgtm-ci-step
#                            failures
#   CANARY_REDISPATCH_AFTER_SECONDS  a dispatched run still `queued` with no
#                            job this long after its dispatch never started
#                            and is dispatched once more (#1601), default 300
#   CANARY_MAX_REDISPATCHES  extra dispatches of never-started runs per canary,
#                            default 3; 0 disables them. A fixture is dispatched
#                            at most twice in all, whatever the reason
#   CANARY_NEVER_STARTED_PRUNE_HOURS  age in hours (from its latest attempt)
#                            past which a fixture run still `queued` with no
#                            job, on the stale ref of a completed canary
#                            attempt, is deleted if GitHub allows it and the
#                            ref goes either way (#1605); default and minimum 24.
#                            A stale ref with no run goes once its owning
#                            attempt completed this long ago
#   CANARY_SWEEP_MAX_REFS    stale canary refs of other candidate SHAs checked
#                            per run, after this run's own cleanup (#1652):
#                            a quarter rotated by GITHUB_RUN_NUMBER first,
#                            then the oldest; default 20, 0
#                            disables the sweep
#   CANARY_SWEEP_BUDGET_SECONDS  wall-clock budget of that sweep, default 120;
#                            it stops before the next ref once spent, and is
#                            skipped when the budget does not end 10 minutes
#                            before the job's limit (counted from the
#                            canary's start)
#   CANARY_SWEEP_CALL_TIMEOUT_SECONDS  limit of each sweep API call, default
#                            30 (never past the budget; SIGKILL 5s after
#                            SIGTERM, to the call's whole process group).
#                            Needs GNU timeout (gnutimeout, else timeout);
#                            without it the sweep is skipped
#   CANARY_JOB_TIMEOUT_MINUTES  the canary job's timeout-minutes, default 55
#                            (contract-tested against the workflow)
#   CANARY_STATE_DIR         owned-ref journal shared with the always-run cleanup step
#   CANARY_CLEANUP_POLL_SECONDS  cancellation settle interval, default 5
#   CANARY_POLL_SECONDS      poll interval, default 30
#   CANARY_SINCE_SLACK_SECONDS  clock slack subtracted from the run-list
#                            `created>=` filter, default 120
#   CANARY_WRITE_RETRY_SECONDS  pause before the single retry of a failed write, default 10
#   GITHUB_RUN_ID            canary owner (local runs use a timestamp and PID)
#   GITHUB_RUN_ATTEMPT       rerun attempt (default 1)
#   CANARY_KEEP_BRANCH       "true" keeps this run's canary ref for inspection
#   CANARY_SOURCE_URL        lgtm-ci run/PR URL recorded in the branch commit
#   GITHUB_STEP_SUMMARY      summary file (optional)
#   GITHUB_OUTPUT            receives `mode`, `branch`, `gate-failures`, `table` (optional)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"
# Infrastructure annotation signatures for the bounded gate retry (#1475).
# shellcheck source=../lib/infra-signatures.sh
source "$SCRIPT_DIR/../lib/infra-signatures.sh"

FIXTURE_REPO="${FIXTURE_REPO:-TurboCoder13/lgtm-ci-consumer-fixture}"
FIXTURE_BASE_BRANCH="${FIXTURE_BASE_BRANCH:-main}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-lgtm-hq/lgtm-ci}"
LGTM_CI_MAIN_BRANCH="${LGTM_CI_MAIN_BRANCH:-main}"
EVENT_NAME="${EVENT_NAME:-workflow_dispatch}"
EVENT_ACTION="${EVENT_ACTION:-}"
EVENT_LABEL="${EVENT_LABEL:-}"
PR_NUMBER="${PR_NUMBER:-}"
PR_LABELS="${PR_LABELS:-}"
PR_HEAD_REPO_FORK="${PR_HEAD_REPO_FORK:-false}"
CANARY_FORCE_LABEL="${CANARY_FORCE_LABEL:-needs-external-canary}"
CANARY_OVERRIDE_LABEL="${CANARY_OVERRIDE_LABEL:-canary-informational}"
CANARY_RELEVANT_PATHS="${CANARY_RELEVANT_PATHS:-.github/workflows/ .github/actions/ scripts/ci/ schemas/ examples/}"
# Keep in sync with the "Gate workflows" header of
# .github/workflows/external-consumer-canary.yml (contract-tested).
CANARY_EXPECTED_GATES="${CANARY_EXPECTED_GATES:-actions-direct build-python-direct coverage-lcov docker-facade-validate docker-orchestrator docker-publish docker-scan-failure-probe e2e-matrix egress node-bun node-npm node-pnpm perms playwright python python-private-dep readonly-docker readonly-node readonly-rust readonly-shell recover retry rust rust-build-siblings rust-release-build siblings verify-fresh-install vuln-suppression}"
CANARY_INCLUDE_MANUAL="${CANARY_INCLUDE_MANUAL:-false}"
CANARY_TIMEOUT_SECONDS="${CANARY_TIMEOUT_SECONDS:-1500}"
CANARY_MAX_IN_FLIGHT="${CANARY_MAX_IN_FLIGHT:-6}"
CANARY_RETRY_INFRA="${CANARY_RETRY_INFRA:-true}"
CANARY_QUEUE_TIMEOUT_SECONDS="${CANARY_QUEUE_TIMEOUT_SECONDS:-1500}"
# A run normally has its jobs within seconds of creation, queued for a runner
# if none is free. Ten 30-second polls with no job at all is far past that,
# and leaves at least 1,200s of the queue budget for a run dispatched at the
# start (#1601).
CANARY_REDISPATCH_AFTER_SECONDS="${CANARY_REDISPATCH_AFTER_SECONDS:-300}"
# One or two of about 45 runs never started per attempt when this was seen;
# three leaves headroom, and more than that is an outage the canary reports
# as inconclusive instead of feeding more dispatches into it.
CANARY_MAX_REDISPATCHES="${CANARY_MAX_REDISPATCHES:-3}"
# GitHub gives up on a job waiting for a runner after 24 hours, so a run that
# old with no job at all has no job that could start; the canary itself is
# bounded by well under an hour (#1605). That limit is the safety argument, so
# 24 is also the minimum: stale cleanup keeps every such ref on an unset,
# malformed or lower value, and the full run rejects one up front.
CANARY_NEVER_STARTED_PRUNE_HOURS="${CANARY_NEVER_STARTED_PRUNE_HOURS:-24}"
# Each ref the cross-SHA sweep checks costs about three API calls, so the
# default bounds it at about 60 per canary run (#1652; see
# sweep_stale_canary_refs). Cleanup skips the sweep on a malformed value, and
# the full run rejects one up front.
CANARY_SWEEP_MAX_REFS="${CANARY_SWEEP_MAX_REFS:-20}"
# The sweep runs in the EXIT trap of the result step, so its time counts
# against the job's limit: 120s holds the default cap at ordinary latency
# (about 60 calls), and every call is bounded on its own (#1656).
CANARY_SWEEP_BUDGET_SECONDS="${CANARY_SWEEP_BUDGET_SECONDS:-120}"
CANARY_SWEEP_CALL_TIMEOUT_SECONDS="${CANARY_SWEEP_CALL_TIMEOUT_SECONDS:-30}"
# Keep in sync with timeout-minutes of the canary job in
# .github/workflows/external-consumer-canary.yml (contract-tested).
CANARY_JOB_TIMEOUT_MINUTES="${CANARY_JOB_TIMEOUT_MINUTES:-55}"
CANARY_STATE_DIR="${CANARY_STATE_DIR:-}"
CANARY_CLEANUP_POLL_SECONDS="${CANARY_CLEANUP_POLL_SECONDS:-5}"
CANARY_POLL_SECONDS="${CANARY_POLL_SECONDS:-30}"
CANARY_SINCE_SLACK_SECONDS="${CANARY_SINCE_SLACK_SECONDS:-120}"
CANARY_WRITE_RETRY_SECONDS="${CANARY_WRITE_RETRY_SECONDS:-10}"
CANARY_KEEP_BRANCH="${CANARY_KEEP_BRANCH:-false}"
CANARY_SOURCE_URL="${CANARY_SOURCE_URL:-}"
# Resolve once so branch creation and dispatch agree even in local invocations.
CANARY_RUN_ID="${GITHUB_RUN_ID:-local-$(date +%s)-$$}"
CANARY_RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"

# Same pattern as the fixture's scripts/pin.sh: reusable workflow or direct
# composite action reference, followed by a 40-hex pin.
PIN_RE='lgtm-hq/lgtm-ci/\.github/(workflows/[A-Za-z0-9._-]+\.yml|actions/[A-Za-z0-9._-]+)@'

# The ownership journal is written only after create_canary_branch succeeds.
CANARY_BRANCH=""
CANARY_WORKDIR=""
# reference_verdict caches: "<ref>:<path>" -> present|absent, and the merge base.
declare -A LGTM_CI_PATH_STATE=()
# "<ref>:<reusable path>" -> " <input> <input> ... " or "<absent>".
declare -A LGTM_CI_INPUTS=()
CANDIDATE_MERGE_BASE=""

# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------

# Print "<role>\t<expected conclusion>" for one fixture workflow file name.
# role is `gate`, `informational` or `manual`. Keep in sync with the header
# comment of .github/workflows/external-consumer-canary.yml (contract-tested).
classify_workflow() {
	local name="${1:?workflow file name required}"
	name="${name##*/}"
	case "$name" in
	# reusable-release-version-pr callers: one shared fixture concurrency
	# group and a version PR per success; dispatched only on request.
	release-version-pr.yml | release-benign-hook.yml)
		printf 'manual\tsuccess\n'
		;;
	release-tamper-hook.yml)
		printf 'manual\tfailure\n'
		;;
	# App-token reach and SBOM release upload (self-cleaning release paths),
	# and the tooling App credential (#1622): all depend on owner-held App
	# secrets or releases, not only on the candidate.
	app-token-probe.yml | sbom-release-upload.yml | tooling-app.yml)
		printf 'informational\tsuccess\n'
		;;
	# Probes of the negative-by-design workflows: each dispatches its
	# negative, asserts the designed failure and is green when it holds.
	perms-negative-probe.yml | playwright-negative-probe.yml | verify-negative-probe.yml | tooling-app-negative-probe.yml)
		printf 'informational\tsuccess\n'
		;;
	# Negative-by-design workflows: a green run here is the finding.
	verify-negative.yml | playwright-negative.yml | docker-scan-failure.yml | tooling-app-negative.yml)
		printf 'informational\tfailure\n'
		;;
	# Under-permissioned callers: GitHub rejects the run at parse time, before
	# any job (and so any publish step) starts (#735, #1081).
	perms-negative.yml | perms-negative-node.yml | perms-negative-shell.yml | perms-negative-rust.yml | perms-negative-docker.yml | perms-negative-recover.yml)
		printf 'informational\tstartup_failure\n'
		;;
	*)
		printf 'gate\tsuccess\n'
		;;
	esac
}

workflow_role() {
	classify_workflow "$1" | cut -f1
}

workflow_expected() {
	classify_workflow "$1" | cut -f2
}

is_gate() {
	[[ "$(workflow_role "$1")" == "gate" ]]
}

# True when the workflow should be dispatched in this run.
should_dispatch() {
	local role
	role="$(workflow_role "$1")"
	[[ "$role" != "manual" ]] || [[ "$CANARY_INCLUDE_MANUAL" == "true" ]]
}

# ---------------------------------------------------------------------------
# Run-mode decision (always-run / fast-skip)
# ---------------------------------------------------------------------------

# gh api against the lgtm-ci repository (github.token).
lgtm_ci_api() {
	GH_TOKEN="${LGTM_CI_TOKEN:-${GH_TOKEN:-}}" gh api "$@"
}

# Look up the candidate PR afresh; errors/unknown states must never mean closed.
check_candidate_pr() {
	CANDIDATE_PR_INACTIVE=false
	[[ "$EVENT_NAME" == pull_request ]] || return 0
	[[ -n "$PR_NUMBER" ]] || die "PR_NUMBER is required for pull_request events"
	[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || return 1
	local state
	state="$(lgtm_ci_api -X GET "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" \
		--jq 'if .merged == true then "merged" else .state end')" || return 1
	case "$state" in
	open) ;;
	closed | merged) CANDIDATE_PR_INACTIVE=true ;;
	*) return 1 ;;
	esac
}

inactive_candidate_notice() {
	echo "::notice::candidate pull request #${PR_NUMBER} is closed or merged; canary no longer applies"
	_write_summary "## External consumer canary" "" "Candidate pull request #${PR_NUMBER} is closed or merged; canary no longer applies."
	_write_output "mode=skipped" "gate-failures=0"
}

# True when PR_LABELS (comma-separated) contains the given label.
has_label() {
	local want="${1:?label required}" label
	local IFS=','
	for label in $PR_LABELS; do
		[[ "${label// /}" == "$want" ]] && return 0
	done
	return 1
}

# True when the path starts with one of CANARY_RELEVANT_PATHS.
is_adoption_relevant() {
	local path="${1:?path required}" prefix
	for prefix in $CANARY_RELEVANT_PATHS; do
		[[ "$path" == "$prefix"* ]] && return 0
	done
	return 1
}

# Changed file names of the pull request, one per line. Fails loudly: a
# listing error must never read as "no relevant changes".
pr_changed_files() {
	[[ -n "$PR_NUMBER" ]] || die "PR_NUMBER is required for pull_request events"
	lgtm_ci_api -X GET "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/files?per_page=100" \
		--paginate --jq '.[].filename'
}

# Print "<mode>\t<reason>" where mode is `full` or `skip`. Exits non-zero
# when the decision cannot be made (API failure), so the job fails closed.
decide_run_mode() {
	if [[ "$EVENT_NAME" != "pull_request" ]]; then
		printf 'full\t%s\n' "${EVENT_NAME} always runs the full fixture set"
		return 0
	fi
	if [[ "$PR_HEAD_REPO_FORK" == "true" ]]; then
		printf 'skip\t%s\n' "fork pull request: the fixture App secrets (EXTERNAL_FIXTURE_APP_ID, EXTERNAL_FIXTURE_APP_PRIVATE_KEY) are not available; re-run from a same-repository branch"
		return 0
	fi
	if [[ "$EVENT_ACTION" == "labeled" && "$EVENT_LABEL" != "$CANARY_FORCE_LABEL" && "$EVENT_LABEL" != "$CANARY_OVERRIDE_LABEL" ]]; then
		printf 'skip\t%s\n' "label '${EVENT_LABEL}' is not a canary label; this head was already decided on push"
		return 0
	fi
	if has_label "$CANARY_FORCE_LABEL"; then
		printf 'full\t%s\n' "label ${CANARY_FORCE_LABEL} forces a full run"
		return 0
	fi
	local files path
	files="$(pr_changed_files)" || die "cannot list the files of pull request #${PR_NUMBER}; refusing to skip"
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		if is_adoption_relevant "$path"; then
			printf 'full\t%s\n' "pull request touches ${path}"
			return 0
		fi
	done <<<"$files"
	printf 'skip\t%s\n' "no adoption-relevant changes (none of: ${CANARY_RELEVANT_PATHS})"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_require_env() {
	local var
	for var in "$@"; do
		[[ -n "${!var:-}" ]] || die "$var is required"
	done
}

# gh api against the fixture repository (GH_TOKEN = fixture token).
fixture_api() {
	gh api "$@"
}

# An idempotent preparation write to the fixture (git data API) with one bounded retry and
# a named error, so a transient failure does not abort the canary silently
# and a hard failure says which step died. stdout is the API answer only;
# stderr is captured separately so a gh notice cannot leak into a SHA.
#   fixture_write <step name> <gh api args...>
fixture_write() {
	local step="${1:?step name required}" out errf
	shift
	errf="$(mktemp)"
	if out="$(fixture_api "$@" 2>"$errf")"; then
		rm -f "$errf"
		printf '%s\n' "$out"
		return 0
	fi
	log_warn "${step}: $(tr '\n' ' ' <"$errf"); retrying in ${CANARY_WRITE_RETRY_SECONDS}s"
	sleep "$CANARY_WRITE_RETRY_SECONDS"
	if out="$(fixture_api "$@" 2>"$errf")"; then
		rm -f "$errf"
		printf '%s\n' "$out"
		return 0
	fi
	log_error "${step} failed on ${FIXTURE_REPO}: $(tr '\n' ' ' <"$errf")"
	rm -f "$errf"
	return 1
}

# Resolve a ref on the lgtm-ci repository to a full SHA. A 40-hex argument is
# returned as-is without a network call.
resolve_candidate_sha() {
	local ref="${1:?ref required}"
	if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
		printf '%s\n' "$ref"
		return 0
	fi
	local sha
	sha="$(lgtm_ci_api -X GET "repos/${GITHUB_REPOSITORY}/commits/${ref}" --jq .sha)" ||
		die "cannot resolve '$ref' on ${GITHUB_REPOSITORY}"
	[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "resolved '$ref' to '$sha', not a full SHA"
	printf '%s\n' "$sha"
}

canary_branch_name() {
	printf 'canary/%s-%s-%s\n' "${1:?sha required}" "$CANARY_RUN_ID" "$CANARY_RUN_ATTEMPT"
}

# ISO-8601 UTC timestamp CANARY_SINCE_SLACK_SECONDS in the past (GNU or BSD date).
since_timestamp() {
	local epoch
	epoch=$(($(date +%s) - CANARY_SINCE_SLACK_SECONDS))
	date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ
}

# Rewrite every lgtm-ci pin in one workflow file to the candidate SHA, then
# refuse any lgtm-ci reference that is not pinned to it (a tag or branch pin
# would otherwise run old code and report green). Like the fixture's
# scripts/pin.sh, a 40-hex `ref:` value tagged `# lgtm-ci-pin` (a direct
# tooling checkout, or a `tooling-ref:` input that must name the same commit
# as the `uses:` line) is rewritten too (#1081).
rewrite_pins() {
	local file="${1:?file required}" sha="${2:?sha required}" stale
	[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "not a full SHA: $sha"
	sed -E -e "s#(${PIN_RE})[0-9a-f]{40}#\1${sha}#g" \
		-e "s#(ref: )[0-9a-f]{40}([[:space:]]+\# lgtm-ci-pin)#\1${sha}\2#g" "$file" >"$file.tmp"
	mv "$file.tmp" "$file"
	# Only `uses:` lines count: header comments quote the pattern with a
	# `@<sha>` placeholder.
	stale="$(grep -E '^[[:space:]]*(-[[:space:]]+)?uses:' "$file" | grep -oE "${PIN_RE}[^[:space:]\"']+" | grep -v "@${sha}\$" || true)"
	[[ -z "$stale" ]] || die "$(basename "$file"): lgtm-ci reference not pinned to the candidate: ${stale//$'\n'/, }"
	# A tagged ref the rewrite could not match would run old tooling green.
	# Only YAML lines that set a value count: comment lines may mention the
	# marker (as the fixture's headers do).
	stale="$(grep -E '^[[:space:]]*[^#[:space:]].*#[[:space:]]*lgtm-ci-pin' "$file" | grep -vE "ref: ${sha}[[:space:]]+# lgtm-ci-pin" || true)"
	[[ -z "$stale" ]] || die "$(basename "$file"): lgtm-ci-pin ref not pinned to the candidate: ${stale//$'\n'/, }"
}

# Print the file names (basenames) under <dir> that declare workflow_dispatch
# (block key, list item, or inline flow sequence under `on:`).
discover_dispatchable() {
	local dir="${1:?dir required}" file
	for file in "$dir"/*.yml; do
		[[ -f "$file" ]] || continue
		grep -qE '^[[:space:]]+workflow_dispatch:|^[[:space:]]+-[[:space:]]+workflow_dispatch[[:space:]]*$|^["'"'"']?on["'"'"']?:[[:space:]]*\[[^]]*\bworkflow_dispatch\b' "$file" || continue
		basename "$file"
	done
}

# Print the distinct lgtm-ci paths (`.github/workflows/<f>.yml`,
# `.github/actions/<name>`) referenced from `uses:` lines of one workflow file.
lgtm_ci_references() {
	local file="${1:?file required}"
	{ grep -E '^[[:space:]]*(-[[:space:]]+)?uses:' "$file" || true; } |
		{ grep -oE "${PIN_RE}" || true; } |
		sed -E 's#^lgtm-hq/lgtm-ci/##; s#@$##' | sort -u
}

# Set REPLY to `present` or `absent` for one lgtm-ci path at <ref> (contents
# API, cached per run). Any error other than a 404 fails, so a lookup outage
# never reads as "absent". Runs in the caller's shell so the cache survives.
lgtm_ci_path_state() {
	local path="${1:?path required}" ref="${2:?ref required}" errf key
	key="${2}:${1}"
	if [[ -n "${LGTM_CI_PATH_STATE[$key]:-}" ]]; then
		REPLY="${LGTM_CI_PATH_STATE[$key]}"
		return 0
	fi
	errf="$(mktemp)"
	# Presence is the HTTP status alone: an action path is a directory, which
	# the contents API answers with an array, not an object.
	if lgtm_ci_api -X GET "repos/${GITHUB_REPOSITORY}/contents/${path}?ref=${ref}" --silent 2>"$errf"; then
		LGTM_CI_PATH_STATE[$key]=present
	elif grep -q 'HTTP 404' "$errf"; then
		LGTM_CI_PATH_STATE[$key]=absent
	else
		log_error "cannot read ${GITHUB_REPOSITORY}/${path} at ${ref}: $(tr '\n' ' ' <"$errf")"
		rm -f "$errf"
		return 1
	fi
	rm -f "$errf"
	REPLY="${LGTM_CI_PATH_STATE[$key]}"
}

# Set CANDIDATE_MERGE_BASE to the merge base of <sha> with
# LGTM_CI_MAIN_BRANCH (compare API), once per run.
resolve_candidate_merge_base() {
	local sha="${1:?sha required}" base
	[[ -z "$CANDIDATE_MERGE_BASE" ]] || return 0
	base="$(lgtm_ci_api -X GET "repos/${GITHUB_REPOSITORY}/compare/${LGTM_CI_MAIN_BRANCH}...${sha}" \
		--jq .merge_base_commit.sha)" || {
		log_error "cannot compare ${LGTM_CI_MAIN_BRANCH}...${sha} on ${GITHUB_REPOSITORY}"
		return 1
	}
	[[ "$base" =~ ^[0-9a-f]{40}$ ]] || {
		log_error "merge base of ${sha} is '${base}', not a full SHA"
		return 1
	}
	CANDIDATE_MERGE_BASE="$base"
}

# Print "<reusable path>#<input>" for every `with:` key a fixture job passes to
# an lgtm-ci reusable workflow (job-level `uses:`; jobs at two-space indent).
# GitHub refuses a run that passes an input the called workflow does not
# declare, so a new input the fixture adopts has the same "landed after the
# candidate branched" problem as a new reusable, and a removed input is a
# consumer-breaking change (#1134).
#
# Line-based, for the two-space indentation yamllint enforces on the fixture:
# comments and blank lines are skipped, a trailing comment and quotes are
# stripped, and each job's `uses:` and `with:` keys are collected in either
# order and emitted when the job ends. A flow-style `with: {...}` on an
# lgtm-ci call cannot be read line by line, so it is emitted as
# `<reusable>#<unparsed>` and reference_verdict fails closed on it.
lgtm_ci_passed_inputs() {
	local file="${1:?file required}"
	awk '
		function strip(s) {
			sub(/[[:space:]]+#.*$/, "", s)
			sub(/[[:space:]]+$/, "", s)
			return s
		}
		function flush(i) {
			if (wf != "") for (i = 1; i <= n; i++) print wf "#" keys[i]
			if (wf != "" && flow) print wf "#<unparsed>"
			wf = ""; n = 0; inwith = 0; flow = 0
		}
		/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
		{ line = strip($0); gsub(/["\047]/, "", line) }
		line ~ /^[^ ]/ { flush(); injobs = (line ~ /^jobs:$/); next }
		!injobs { next }
		line ~ /^  [^ ]/ { flush(); next }
		line ~ /^    uses:/ {
			v = line
			sub(/^    uses:[[:space:]]*/, "", v)
			gsub(/["\047]/, "", v)
			if (v ~ /^lgtm-hq\/lgtm-ci\/\.github\/workflows\//) {
				sub(/^lgtm-hq\/lgtm-ci\//, "", v)
				sub(/@.*/, "", v)
				wf = v
			}
			inwith = 0
			next
		}
		line ~ /^    with:$/ { inwith = 1; next }
		line ~ /^    with:[[:space:]]*[{]/ { flow = 1; inwith = 0; next }
		line ~ /^    [^ ]/ { inwith = 0; next }
		inwith && line ~ /^      [A-Za-z0-9_-]+:/ {
			k = line
			sub(/^      /, "", k)
			sub(/:.*/, "", k)
			keys[++n] = k
		}
		END { flush() }
	' "$file" | sort -u
}

# Set REPLY to the space-separated `workflow_call` input names of one lgtm-ci
# reusable at <ref> (raw contents API, cached per run), or to `<absent>` when
# the file does not exist there. Any error other than a 404 fails.
lgtm_ci_reusable_inputs() {
	local path="${1:?path required}" ref="${2:?ref required}" errf out key
	key="${2}:${1}"
	if [[ -n "${LGTM_CI_INPUTS[$key]:-}" ]]; then
		REPLY="${LGTM_CI_INPUTS[$key]}"
		return 0
	fi
	errf="$(mktemp)"
	if out="$(lgtm_ci_api -X GET -H "Accept: application/vnd.github.raw+json" \
		"repos/${GITHUB_REPOSITORY}/contents/${path}?ref=${ref}" 2>"$errf")"; then
		# Only `on.workflow_call.inputs` (a `workflow_dispatch` input of the
		# same name does not make a call valid); comments and quoted keys are
		# tolerated, a flow-style `inputs: {...}` is not.
		LGTM_CI_INPUTS[$key]=" $(awk '
			function strip(s) {
				sub(/[[:space:]]+#.*$/, "", s)
				sub(/[[:space:]]+$/, "", s)
				return s
			}
			/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
			{ line = strip($0); gsub(/["\047]/, "", line) }
			line ~ /^[^ ]/ { inon = (line ~ /^on:$/); incall = 0; ininputs = 0; next }
			!inon { next }
			line ~ /^  [^ ]/ { incall = (line ~ /^  workflow_call:$/); if (incall) found = 1; ininputs = 0; next }
			!incall { next }
			line ~ /^    [^ ]/ { ininputs = (line ~ /^    inputs:$/); if (line ~ /^    inputs:[[:space:]]*[{]/) flow = 1; next }
			ininputs && line ~ /^      [A-Za-z0-9_-]+:/ { k = line; sub(/^      /, "", k); sub(/:.*/, "", k); printf "%s ", k }
			END { if (!found || flow) printf "<unparsed>" }
		' <<<"$out")"
		# A file that exists but shows no block-style `on.workflow_call` inputs
		# would read as "no inputs" and turn every passed input into a false
		# removal; refuse instead of guessing.
		if [[ "${LGTM_CI_INPUTS[$key]}" == *"<unparsed>"* ]]; then
			log_error "cannot read block-style on.workflow_call inputs in ${GITHUB_REPOSITORY}/${path} at ${ref}"
			rm -f "$errf"
			return 1
		fi
	elif grep -q 'HTTP 404' "$errf"; then
		LGTM_CI_INPUTS[$key]="<absent>"
	else
		log_error "cannot read ${GITHUB_REPOSITORY}/${path} at ${ref}: $(tr '\n' ' ' <"$errf")"
		rm -f "$errf"
		return 1
	fi
	rm -f "$errf"
	REPLY="${LGTM_CI_INPUTS[$key]}"
}

# Set REPLY to `present` or `absent` for one reference item at <ref>: a path
# (`.github/workflows/<f>.yml`, `.github/actions/<name>`) or a passed input
# (`<reusable path>#<input>`, absent when the reusable or the input is).
lgtm_ci_item_state() {
	local item="${1:?item required}" ref="${2:?ref required}"
	if [[ "$item" != *"#"* ]]; then
		lgtm_ci_path_state "$item" "$ref"
		return
	fi
	lgtm_ci_reusable_inputs "${item%%#*}" "$ref" || return 1
	if [[ "$REPLY" == *" ${item#*#} "* ]]; then
		REPLY=present
	else
		REPLY=absent
	fi
}

# Pre-dispatch verdict for one re-pinned workflow file (#1128). Sets REPLY to
#   dispatch                          every referenced path exists at <sha>
#                                     (or is missing everywhere: the run reports it)
#   removed_by_candidate<TAB><paths>  missing at <sha>, present at its merge
#                                     base with main: the candidate deletes or
#                                     renames a public interface
#   not_applicable<TAB><paths>        missing at <sha> and at the merge base,
#                                     present on main: it landed after the
#                                     candidate branched
# Returns non-zero when any lookup fails (fail closed).
reference_verdict() {
	local file="${1:?file required}" sha="${2:?sha required}" item
	local -a items=() removed=() later=()
	while IFS= read -r item; do
		[[ -z "$item" ]] || items+=("$item")
	done < <(
		lgtm_ci_references "$file"
		lgtm_ci_passed_inputs "$file"
	)
	for item in "${items[@]}"; do
		if [[ "$item" == *"#<unparsed>" ]]; then
			log_error "${file##*/}: flow-style with: on the call to ${item%%#*} cannot be checked; write it in block style"
			return 1
		fi
		lgtm_ci_item_state "$item" "$sha" || return 1
		[[ "$REPLY" == "absent" ]] || continue
		resolve_candidate_merge_base "$sha" || return 1
		lgtm_ci_item_state "$item" "$CANDIDATE_MERGE_BASE" || return 1
		if [[ "$REPLY" == "present" ]]; then
			removed+=("$item")
			continue
		fi
		lgtm_ci_item_state "$item" "$LGTM_CI_MAIN_BRANCH" || return 1
		[[ "$REPLY" == "absent" ]] || later+=("$item")
	done
	if ((${#removed[@]})); then
		REPLY="removed_by_candidate"$'\t'"${removed[*]}"
	elif ((${#later[@]})); then
		REPLY="not_applicable"$'\t'"${later[*]}"
	else
		REPLY="dispatch"
	fi
}

# Build the git tree payload for the re-pinned workflow files.
# stdout: JSON {"base_tree": <sha>, "tree": [{path, mode, type, content}...]}
build_tree_payload() {
	local base_tree="${1:?base tree sha required}" dir="${2:?dir required}" file
	local entries
	entries="$(mktemp)"
	for file in "$dir"/*.yml; do
		[[ -f "$file" ]] || continue
		jq -n --arg p ".github/workflows/$(basename "$file")" --rawfile c "$file" \
			'{path: $p, mode: "100644", type: "blob", content: $c}' >>"$entries"
	done
	jq -n --arg base "$base_tree" '{base_tree: $base, tree: [inputs]}' "$entries"
	rm -f "$entries"
}

# Create a run-specific canary/<sha>-<run-id>-<attempt> ref with re-pinned workflows.
# Fetches the base branch's workflow files (direct .yml children of
# .github/workflows/ only) into <workdir>, rewrites them,
# and commits via the git data API. Journals ownership once the ref exists.
# Prints the new commit SHA.
create_canary_branch() {
	local sha="${1:?sha required}" workdir="${2:?workdir required}"
	local branch base_sha base_tree path commit_sha tree_sha message payload

	branch="$(canary_branch_name "$sha")"
	[[ "$branch" != "$FIXTURE_BASE_BRANCH" && "$branch" == canary/* ]] ||
		die "refusing to write to fixture branch '$branch'"

	base_sha="$(fixture_api -X GET "repos/${FIXTURE_REPO}/git/ref/heads/${FIXTURE_BASE_BRANCH}" --jq .object.sha)"
	base_tree="$(fixture_api -X GET "repos/${FIXTURE_REPO}/git/commits/${base_sha}" --jq .tree.sha)"
	log_info "fixture ${FIXTURE_BASE_BRANCH} = ${base_sha}"

	mkdir -p "$workdir"
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		fixture_api -X GET -H "Accept: application/vnd.github.raw+json" \
			"repos/${FIXTURE_REPO}/contents/${path}?ref=${base_sha}" >"$workdir/$(basename "$path")"
		rewrite_pins "$workdir/$(basename "$path")" "$sha"
	done < <(fixture_api -X GET "repos/${FIXTURE_REPO}/git/trees/${base_tree}?recursive=1" \
		--jq '.tree[] | select(.type == "blob" and (.path | test("^\\.github/workflows/[^/]+\\.yml$"))) | .path')

	local count
	count="$(find "$workdir" -maxdepth 1 -name '*.yml' | wc -l | tr -d ' ')"
	[[ "$count" -gt 0 ]] || die "no workflow files found on ${FIXTURE_REPO}@${FIXTURE_BASE_BRANCH}"
	log_info "re-pinned ${count} fixture workflow files to ${sha}"

	payload="$workdir/.tree-payload.json"
	build_tree_payload "$base_tree" "$workdir" >"$payload"
	tree_sha="$(fixture_write "create tree" -X POST "repos/${FIXTURE_REPO}/git/trees" --input "$payload" --jq .sha)" ||
		die "cannot create the canary tree (the token needs Contents and Workflows read/write on ${FIXTURE_REPO})"

	message="canary: pin every lgtm-ci reference to ${sha}"
	[[ -z "$CANARY_SOURCE_URL" ]] || message+=$'\n\n'"Source: ${CANARY_SOURCE_URL}"
	jq -n --arg m "$message" --arg t "$tree_sha" --arg p "$base_sha" \
		'{message: $m, tree: $t, parents: [$p]}' >"$workdir/.commit-payload.json"
	commit_sha="$(fixture_write "create commit" -X POST "repos/${FIXTURE_REPO}/git/commits" \
		--input "$workdir/.commit-payload.json" --jq .sha)" || die "cannot create the canary commit"

	fixture_write "create branch ${branch}" -X POST "repos/${FIXTURE_REPO}/git/refs" \
		-f ref="refs/heads/${branch}" -f sha="$commit_sha" --jq .ref >/dev/null ||
		die "cannot create ${FIXTURE_REPO}@${branch} (this run's ref may already exist; it is left untouched)"
	printf '%s\n' "$branch" >"$CANARY_STATE_DIR/branch"
	log_info "created ${FIXTURE_REPO}@${branch} (${commit_sha})"
	printf '%s\n' "$commit_sha"
}

delete_canary_branch() {
	local branch="${1:?branch required}"
	[[ "$branch" == canary/* ]] || die "refusing to delete fixture branch '$branch'"
	if fixture_api -X DELETE "repos/${FIXTURE_REPO}/git/refs/heads/${branch}" >/dev/null 2>&1; then
		log_info "deleted ${FIXTURE_REPO}@${branch}"
	else
		log_warn "could not delete ${FIXTURE_REPO}@${branch} (already gone?)"
		return 1
	fi
}

# Dispatch one workflow file on the canary branch.
dispatch_workflow() {
	local file="${1:?workflow file required}" branch="${2:?branch required}"
	# A dispatch is not idempotent: retrying an ambiguous response can double
	# the fan-out. Journal it and let cleanup discover any accepted run.
	fixture_api -X POST "repos/${FIXTURE_REPO}/actions/workflows/${file}/dispatches" -f ref="$branch" >/dev/null || {
		log_error "dispatch ${file} failed on ${FIXTURE_REPO}"
		return 1
	}
}

# shellcheck source=../canary/runs.sh
source "$SCRIPT_DIR/../canary/runs.sh"

# Gate failure text when the harden-runner agent start-up label proved both
# the first and the retried run (agent_startup_repeated, #1616).
CANARY_AGENT_STARTUP_REPEAT="harden-runner agent start-up failed in both runs; a candidate change (for example an allowed host that does not resolve) is the likely cause"

# Verdict for one row: "pass" when the conclusion equals the expected one,
# "skipped" for a manual workflow that was not dispatched, "probed" for a
# negative reached through its probe, "not_applicable" for a workflow whose
# lgtm-ci reference post-dates the candidate, "inconclusive" for a gate's
# queue expiry, startup_failure or proven fixture infrastructure failure (the
# optional third argument, the row's evidence field), else "fail".
verdict_for() {
	local file="${1:?}" conclusion="${2:?}" evidence="${3:-}"
	if [[ "$conclusion" == "not_dispatched" ]]; then
		printf 'skipped\n'
	elif [[ "$conclusion" == "queued-timeout" ]]; then
		if is_gate "$file"; then printf 'inconclusive\n'; else printf 'queued-timeout\n'; fi
	elif [[ "$conclusion" == "via_probe" ]]; then
		printf 'probed\n'
	elif [[ "$conclusion" == "not_applicable" ]]; then
		printf 'not_applicable\n'
	elif [[ "$conclusion" == "$(workflow_expected "$file")" ]]; then
		printf 'pass\n'
	elif is_gate "$file" && [[ -n "$evidence" || "$conclusion" == startup_failure ]]; then
		# startup_failure identifies itself: no lgtm-ci step ran.
		printf 'inconclusive\n'
	else
		printf 'fail\n'
	fi
}

# Render the markdown table for result rows (stdin, poll_runs format; for
# via_probe / not_applicable / removed_by_candidate rows the fourth field is
# the probe or the lgtm-ci paths concerned), then one note per not_applicable
# or removed_by_candidate row. Optional later fields (see result_row) preserve
# dispatch errors, inconclusive evidence and the retry record.
render_summary() {
	local sha="${1:?sha required}" branch="${2:-}" file conclusion url name role expected verdict mark link error
	local evidence retry_reason first_url retry_status
	local -a notes=()
	echo "## External consumer canary"
	echo
	echo "Fixture: \`${FIXTURE_REPO}\` at branch \`${branch:-$(canary_branch_name "$sha")}\`, every lgtm-ci reference pinned to \`${sha}\`."
	echo
	echo "Queue budget: ${CANARY_QUEUE_TIMEOUT_SECONDS}s (including admission); execution budget: ${CANARY_TIMEOUT_SECONDS}s from first job start; max in flight: ${CANARY_MAX_IN_FLIGHT}. Queue expiry is inconclusive and blocks gates; it does not prove the candidate passed. A run still queued with no job ${CANARY_REDISPATCH_AFTER_SECONDS}s after dispatch never started: it is dispatched once more within the same queue budget (at most ${CANARY_MAX_REDISPATCHES} per canary) and the new run decides."
	echo
	echo "| Workflow | Role | Expected | Conclusion | Verdict | Run |"
	echo "|---|---|---|---|---|---|"
	# Tab is IFS whitespace, so consecutive tabs would collapse an empty run
	# URL; split on a non-whitespace separator instead.
	while IFS=$'\x1f' read -r file conclusion url name error evidence retry_reason retry_status first_url; do
		[[ -n "$file" ]] || continue
		if [[ -n "$error" ]]; then
			# Escape diagnostic text before embedding it in Markdown/HTML.
			error="$(printf '%s' "$error" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/`/\&#96;/g' -e 's/|/\&#124;/g')"
			notes+=("> Dispatch response for \`${file}\`: ${error}")
		fi
		role="$(workflow_role "$file")"
		expected="$(workflow_expected "$file")"
		verdict="$(verdict_for "$file" "$conclusion" "$evidence")"
		case "$verdict" in
		pass) mark="✅ pass" ;;
		inconclusive) mark="⚠️ inconclusive" ;;
		queued-timeout) mark="ℹ️ queue budget exhausted (not exercised)" ;;
		skipped) mark="➖ not dispatched" ;;
		probed) mark="↪ via \`${name}\`" ;;
		not_applicable)
			mark="➖ not applicable"
			notes+=("> ℹ️ \`${file}\` references \`${name// /\`, \`}\`, which landed on lgtm-ci \`${LGTM_CI_MAIN_BRANCH}\` after this candidate branched; it was not dispatched. Rebase onto \`${LGTM_CI_MAIN_BRANCH}\` to exercise it.")
			;;
		*)
			if [[ "$conclusion" == "removed_by_candidate" ]]; then
				mark="❌ **removed by candidate**"
				notes+=("> ❌ \`${file}\` references \`${name// /\`, \`}\`, present at the candidate's merge base with \`${LGTM_CI_MAIN_BRANCH}\` but missing at the candidate: this change deletes or renames a public interface an external consumer calls.")
			elif [[ "$role" == "gate" ]]; then
				mark="❌ **gate failed**"
			else
				mark="⚠️ unexpected"
			fi
			;;
		esac
		link="—"
		[[ -z "$url" ]] || link="[run](${url})"
		# A fixture dispatched twice links both runs; the deciding run comes first.
		if [[ "$retry_status" == late-first && -n "$first_url" ]]; then
			link+=" · [second run](${first_url})"
		elif [[ "$retry_status" == dispatched && -n "$first_url" && "$first_url" != "$url" ]]; then
			if [[ "$retry_reason" == never-started ]]; then
				link+=" · [first run, not started in time](${first_url})"
			else
				link+=" · [first run](${first_url})"
			fi
		fi
		echo "| \`${file}\` | ${role} | \`${expected}\` | \`${conclusion}\` | ${mark} | ${link} |"
		if [[ "$retry_reason" == never-started && "$retry_status" == failed ]]; then
			notes+=("> \`${file}\`: its first run never started and dispatching it again failed; first run: ${first_url}")
		elif [[ "$retry_reason" == never-started && "$retry_status" == late-first ]]; then
			notes+=("> \`${file}\`: dispatched twice: the first run had not started (queued with no job) when the second was dispatched, then started late and concluded \`${conclusion}\`. A failure of either run counts, so the first run decides; second run: ${first_url}")
			[[ -z "$evidence" ]] ||
				notes+=("> \`${file}\`: the late first run failed on fixture infrastructure (${evidence}), not on the candidate.")
		elif [[ "$retry_reason" == never-started && -n "$retry_status" ]]; then
			notes+=("> \`${file}\`: dispatched twice: the first run never started (queued with no job), so the second run decides; first run: ${first_url}")
			[[ "$evidence" != first-run-started-late ]] ||
				notes+=("> \`${file}\`: the first run started late and the second run was cancelled, which GitHub can do when both share a concurrency group. Not a product failure.")
		elif [[ "$retry_status" == failed ]]; then
			notes+=("> \`${file}\`: retry dispatch failed; first run: ${first_url}")
		elif [[ "$retry_status" == agent-startup-repeat ]]; then
			notes+=("> \`${file}\`: ${CANARY_AGENT_STARTUP_REPEAT}. Retried once (${retry_reason}); first run: ${first_url}")
		elif [[ -n "$retry_status" ]]; then
			notes+=("> \`${file}\`: retried once (${retry_reason}); first run: ${first_url}")
		elif [[ "$evidence" == never-started ]]; then
			notes+=("> \`${file}\`: its first run never started, and the queue budget ran out before it could be dispatched again.")
		fi
	done < <(tr '\t' '\037')
	if ((${#notes[@]})); then
		echo
		printf '%s\n' "${notes[@]}"
	fi
}

# Print the workflows that fail the canary (stdin: result rows): every
# `removed_by_candidate` row whatever its role, and every gate whose verdict
# is neither pass nor not_applicable. Inconclusive gates block too.
# Exit 0 either way; the caller counts the lines.
failed_gates() {
	local file conclusion _url _name _error evidence _rest verdict
	while IFS=$'\x1f' read -r file conclusion _url _name _error evidence _rest; do
		[[ -n "$file" ]] || continue
		if [[ "$conclusion" == "removed_by_candidate" ]]; then
			printf '%s\t%s\n' "$file" "$conclusion"
			continue
		fi
		is_gate "$file" || continue
		verdict="$(verdict_for "$file" "$conclusion" "$evidence")"
		[[ "$verdict" == "pass" || "$verdict" == "not_applicable" ]] || printf '%s\t%s\n' "$file" "$conclusion"
	done < <(tr '\t' '\037')
}

# Print the gate rows (stdin: result rows) whose verdict is inconclusive, as
# workflow and conclusion. These block and no label can waive them.
inconclusive_gates() {
	local file conclusion _url _name _error evidence _rest
	while IFS=$'\x1f' read -r file conclusion _url _name _error evidence _rest; do
		[[ -n "$file" ]] || continue
		[[ "$(verdict_for "$file" "$conclusion" "$evidence")" == inconclusive ]] || continue
		printf '%s\t%s\n' "$file" "$conclusion"
	done < <(tr '\t' '\037')
}

# The one instruction for a blocking inconclusive result (#1475): re-run this
# canary run's failed job. The re-run replaces the attempt in place (same run
# ID), which is what lets the all-checks gate clear the commit; a new run on
# the same commit would leave this failed run gating it.
inconclusive_instruction() {
	local rerun="gh run rerun <run-id> --repo ${GITHUB_REPOSITORY} --failed"
	[[ ! "$CANARY_RUN_ID" =~ ^[0-9]+$ ]] || rerun="gh run rerun ${CANARY_RUN_ID} --repo ${GITHUB_REPOSITORY} --failed"
	# The backticks are literal Markdown around the command, not an expansion.
	# shellcheck disable=SC2016
	printf 'Not a product failure: the candidate was not proven broken (infrastructure or queue). Re-run this canary with `%s`, which replaces this attempt so the all-checks gate can clear the commit.\n' "$rerun"
}

_write_output() {
	[[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
	printf '%s\n' "$@" >>"$GITHUB_OUTPUT"
}

_write_summary() {
	[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
	printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"
}

# EXIT and signal traps, backed by an always-run workflow cleanup step.
_cleanup() {
	cleanup_fixture_runs
	[[ -z "$CANARY_WORKDIR" ]] || rm -rf "$CANARY_WORKDIR"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local ref="${1:-${CANDIDATE_REF:-}}" started_at
	# The canary's start, kept in the state directory below: the stale ref
	# sweep runs only when its budget ends well before the job's limit
	# counted from here (sweep_time_bounds in ../canary/runs.sh). The printf
	# builtin reads the clock without a fork and without consuming a call of
	# a replaced `date` that a caller counts.
	printf -v started_at '%(%s)T' -1
	[[ -n "$ref" ]] || die "usage: $0 <lgtm-ci ref or sha>"
	command -v jq >/dev/null || die "jq is required"

	check_candidate_pr || die "cannot read candidate pull request state; refusing to skip"
	if [[ "$CANDIDATE_PR_INACTIVE" == true ]]; then
		inactive_candidate_notice
		return 0
	fi

	# The decision runs in the main shell so a failure (API error) aborts
	# instead of reading as an empty, skipped result.
	local decision mode reason
	decision="$(decide_run_mode)" || die "run/skip decision failed; refusing to skip"
	IFS=$'\t' read -r mode reason <<<"$decision"
	[[ "$mode" == "full" || "$mode" == "skip" ]] || die "run/skip decision returned '${mode}'; refusing to skip"
	if [[ "$mode" == "skip" ]]; then
		log_info "skipped: ${reason}"
		_write_summary "## External consumer canary" "" "Skipped: ${reason}."
		_write_output "mode=skipped" "gate-failures=0"
		echo "::notice title=external canary::skipped: ${reason}"
		return 0
	fi
	log_info "running the full fixture set: ${reason}"
	[[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN is required for a full run: no fixture App token was minted (see the 'Create fixture App installation token' step: secrets EXTERNAL_FIXTURE_APP_ID / EXTERNAL_FIXTURE_APP_PRIVATE_KEY, and Actions, Contents, Workflows write on the App installation)"

	local setting
	for setting in CANARY_TIMEOUT_SECONDS CANARY_QUEUE_TIMEOUT_SECONDS CANARY_POLL_SECONDS CANARY_CLEANUP_POLL_SECONDS; do
		[[ "${!setting}" =~ ^[0-9]+$ ]] || die "${setting} must be a non-negative integer"
	done
	# Plain decimals only: bash arithmetic reads a leading zero as octal ("08"
	# is an error on every poll) and overflows on very long numbers.
	[[ "$CANARY_MAX_REDISPATCHES" =~ ^(0|[1-9][0-9]{0,5})$ ]] || die "CANARY_MAX_REDISPATCHES must be a non-negative integer without leading zeros, at most 999999"
	# Zero would re-dispatch a run before GitHub had a chance to create its jobs.
	[[ "$CANARY_REDISPATCH_AFTER_SECONDS" =~ ^[1-9][0-9]{0,5}$ ]] || die "CANARY_REDISPATCH_AFTER_SECONDS must be a positive integer without leading zeros, at most 999999"
	# GitHub's 24h limit for a job waiting for a runner is the safety argument.
	if ! [[ "$CANARY_NEVER_STARTED_PRUNE_HOURS" =~ ^[1-9][0-9]{0,4}$ ]] || ((CANARY_NEVER_STARTED_PRUNE_HOURS < 24)); then
		die "CANARY_NEVER_STARTED_PRUNE_HOURS must be an integer from 24 to 99999 without leading zeros"
	fi
	[[ "$CANARY_SWEEP_MAX_REFS" =~ ^(0|[1-9][0-9]{0,2})$ ]] || die "CANARY_SWEEP_MAX_REFS must be an integer from 0 to 999 without leading zeros"
	for setting in CANARY_SWEEP_BUDGET_SECONDS CANARY_SWEEP_CALL_TIMEOUT_SECONDS; do
		[[ "${!setting}" =~ ^[1-9][0-9]{0,2}$ ]] || die "${setting} must be an integer from 1 to 999 without leading zeros"
	done
	[[ "$CANARY_JOB_TIMEOUT_MINUTES" =~ ^[1-9][0-9]{0,3}$ ]] || die "CANARY_JOB_TIMEOUT_MINUTES must be an integer from 1 to 9999 without leading zeros"
	[[ "$CANARY_MAX_IN_FLIGHT" =~ ^[1-9][0-9]*$ ]] || die "CANARY_MAX_IN_FLIGHT must be a positive integer"
	local sha since results table failures fixture_head
	sha="$(resolve_candidate_sha "$ref")"
	CANARY_BRANCH="$(canary_branch_name "$sha")"
	CANARY_WORKDIR="$(mktemp -d)"
	log_info "candidate ${GITHUB_REPOSITORY}@${sha}"
	trap _cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	if [[ -z "$CANARY_STATE_DIR" ]]; then CANARY_STATE_DIR="$CANARY_WORKDIR/state"; fi
	mkdir -p "$CANARY_STATE_DIR"
	printf '%s\n' "$started_at" >"$CANARY_STATE_DIR/started"
	since="$(since_timestamp)"

	create_canary_branch "$sha" "$CANARY_WORKDIR" >"$CANARY_WORKDIR/.fixture-head"
	fixture_head="$(cat "$CANARY_WORKDIR/.fixture-head")"

	# Discover, classify every workflow's lgtm-ci references against the
	# candidate (#1128), then split into dispatch targets and pre-filled rows.
	local -a discovered=() to_dispatch=() extra_rows=()
	local -A ref_state=() ref_paths=()
	local file gate state paths negative probe key
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		discovered+=("$file")
		reference_verdict "$CANARY_WORKDIR/$file" "$sha" ||
			die "cannot check the lgtm-ci references of ${file} against the candidate; refusing to dispatch"
		IFS=$'\t' read -r state paths <<<"$REPLY"
		ref_state[$file]="$state"
		ref_paths[$file]="$paths"
	done < <(discover_dispatchable "$CANARY_WORKDIR")
	((${#discovered[@]})) || die "no fixture workflow declares workflow_dispatch"

	for file in "${discovered[@]}"; do
		state="${ref_state[$file]}"
		paths="${ref_paths[$file]}"
		# A probe stands or falls with the negative it dispatches.
		negative="${file%-probe.yml}.yml"
		probe="${file%.yml}-probe.yml"
		if [[ "$file" == *-probe.yml && -n "${ref_state[$negative]:-}" && "${ref_state[$negative]}" != "dispatch" && "$state" == "dispatch" ]]; then
			state="${ref_state[$negative]}"
			paths="${ref_paths[$negative]}"
		fi
		if [[ "$state" != "dispatch" ]]; then
			extra_rows+=("$(printf '%s\t%s\t\t%s' "$file" "$state" "$paths")")
		elif ! is_gate "$file" && [[ "${ref_state[$probe]:-}" == "dispatch" ]]; then
			# Only a probe that is itself dispatched stands in for its negative;
			# otherwise the negative is dispatched directly.
			extra_rows+=("$(printf '%s\tvia_probe\t\t%s' "$file" "$probe")")
		elif should_dispatch "$file"; then
			to_dispatch+=("$file")
		else
			extra_rows+=("$(printf '%s\tnot_dispatched\t\t' "$file")")
		fi
	done
	if ((${#to_dispatch[@]} == 0)); then
		echo "::warning title=external canary::no fixture workflow was dispatched against ${sha}; nothing was exercised"
		_write_summary "> ⚠️ No fixture workflow was dispatched against this candidate (see the not_applicable rows); nothing was exercised."
	fi
	for gate in $CANARY_EXPECTED_GATES; do
		key="${gate}.yml"
		[[ -n "${ref_state[$key]:-}" ]] ||
			extra_rows+=("$(printf '%s\tnot_dispatchable\t\t' "${gate}.yml")")
	done

	results="$(
		CANARY_FIXTURE_HEAD="$fixture_head" CANARY_DISPATCH=true poll_runs "$CANARY_BRANCH" "$since" "${to_dispatch[@]}" || exit 1
		if ((${#extra_rows[@]})); then printf '%s\n' "${extra_rows[@]}"; fi
	)" || die "cannot monitor fixture runs"
	check_candidate_pr || die "cannot read candidate pull request state; refusing to skip"
	if [[ "$CANDIDATE_PR_INACTIVE" == true ]]; then
		inactive_candidate_notice
		return 0
	fi
	results="$(sort <<<"$results")"
	table="$(render_summary "$sha" "$CANARY_BRANCH" <<<"$results")"
	printf '%s\n' "$table"
	_write_summary "$table"

	failures="$(failed_gates <<<"$results")"
	_write_output "mode=full" "branch=${CANARY_BRANCH}" \
		"gate-failures=$(grep -c . <<<"$failures" || true)" \
		"table<<LGTM_CI_CANARY_EOF" "$table" "LGTM_CI_CANARY_EOF"

	local conclusion
	if [[ -n "$failures" ]]; then
		local inconclusive
		inconclusive="$(inconclusive_gates <<<"$results")"
		# Inconclusive rows, and missing or unreadable execution after an
		# ambiguous POST, cannot be waived.
		if [[ -z "$inconclusive" ]] && has_label "$CANARY_OVERRIDE_LABEL" &&
			! grep -qE $'\t(dispatch_failed|monitoring_failed)$' <<<"$failures"; then
			while IFS=$'\t' read -r file conclusion; do
				echo "::warning title=external canary::$(workflow_role "$file") ${file} concluded '${conclusion}' (reported as success: label ${CANARY_OVERRIDE_LABEL})"
			done <<<"$failures"
			_write_summary "" "> ⚠️ Gate failures above are reported as success because the pull request carries the owner-only label \`${CANARY_OVERRIDE_LABEL}\`."
			return 0
		fi
		# Annotate every failing row; inconclusive ones say so and say what to do.
		local instruction repeated
		instruction="$(inconclusive_instruction)"
		# Rows whose harden-runner agent start-up failed in both runs (#1616).
		repeated="$(awk -F'\t' '$8 == "agent-startup-repeat" { print $1 }' <<<"$results")"
		while IFS=$'\t' read -r file conclusion; do
			if [[ -n "$inconclusive" ]] && grep -qxF "${file}"$'\t'"${conclusion}" <<<"$inconclusive"; then
				echo "::error title=external canary::result is inconclusive: ${file} concluded '${conclusion}' (not a pass or product failure). ${instruction}"
			elif [[ -n "$repeated" ]] && grep -qxF "$file" <<<"$repeated"; then
				echo "::error title=external canary::$(workflow_role "$file") ${file} concluded '${conclusion}': ${CANARY_AGENT_STARTUP_REPEAT}"
			else
				echo "::error title=external canary::$(workflow_role "$file") ${file} concluded '${conclusion}'"
			fi
		done <<<"$failures"
		[[ -z "$inconclusive" ]] || _write_summary "" "> ⚠️ **Blocking inconclusive.** ${instruction}"
		return 1
	fi
	log_success "all applicable gates passed on ${FIXTURE_REPO}@${CANARY_BRANCH}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	if [[ "${1:-}" == --cleanup ]]; then cleanup_fixture_runs; else main "$@"; fi
fi
