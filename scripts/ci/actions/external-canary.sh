#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run the external consumer fixture against one lgtm-ci candidate SHA (#1074)
#
# Usage:
#   GH_TOKEN=<EXTERNAL_FIXTURE_TOKEN> bash scripts/ci/actions/external-canary.sh <ref>
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
#      branch `canary/<sha>` — never touching the fixture's base branch,
#   3. dispatches every gate and informational fixture workflow that declares
#      `workflow_dispatch` on that branch (manual ones only when asked),
#   4. polls the fixture's run list until each dispatched workflow has a
#      completed run (bounded by CANARY_TIMEOUT_SECONDS),
#   5. writes a markdown table (workflow, role, expected, conclusion,
#      verdict, run URL) to $GITHUB_STEP_SUMMARY,
#   6. deletes the canary branch it created (also on failure), and
#   7. exits non-zero when any GATE workflow did not succeed, unless the
#      owner-only override label (CANARY_OVERRIDE_LABEL) is on the pull
#      request, in which case the failure is reported as a warning.
#
# Roles (`classify_workflow`, contract-tested against the workflow header):
#   gate           must conclude `success`; the expected set is
#                  CANARY_EXPECTED_GATES, and a gate the fixture no longer
#                  exposes for dispatch is reported `not_dispatchable` and
#                  fails the canary (fail closed). Unknown workflows are gates.
#   informational  reported against an expected conclusion (`success` for the
#                  App-token / SBOM paths, `failure` / `startup_failure` for
#                  the negative-by-design probes); never fails the canary.
#   manual         the three reusable-release-version-pr callers: they share
#                  one fixture concurrency group, so concurrent dispatch
#                  cancels one of them, and each success opens a version PR in
#                  the fixture that a human closes. Not dispatched unless
#                  CANARY_INCLUDE_MANUAL=true; reported `not_dispatched`.
#
# Environment:
#   GH_TOKEN                 fixture token (EXTERNAL_FIXTURE_TOKEN): Actions
#                            read/write, Contents read/write, Workflows
#                            read/write on the fixture only (workflow files
#                            cannot be written without the Workflows scope)
#   LGTM_CI_TOKEN            token for the lgtm-ci repository (github.token):
#                            resolves <ref>, lists the PR's files; defaults to GH_TOKEN
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
#   CANARY_TIMEOUT_SECONDS   poll bound, default 1500 (25 minutes)
#   CANARY_POLL_SECONDS      poll interval, default 30
#   CANARY_SINCE_SLACK_SECONDS  clock slack subtracted from the run-list
#                            `created>=` filter, default 120
#   CANARY_WRITE_RETRY_SECONDS  pause before the single retry of a failed write, default 10
#   CANARY_KEEP_BRANCH       "true" keeps canary/<sha> for inspection
#   CANARY_SOURCE_URL        lgtm-ci run/PR URL recorded in the branch commit
#   GITHUB_STEP_SUMMARY      summary file (optional)
#   GITHUB_OUTPUT            receives `mode`, `branch`, `gate-failures`, `table` (optional)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"

FIXTURE_REPO="${FIXTURE_REPO:-TurboCoder13/lgtm-ci-consumer-fixture}"
FIXTURE_BASE_BRANCH="${FIXTURE_BASE_BRANCH:-main}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-lgtm-hq/lgtm-ci}"
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
CANARY_EXPECTED_GATES="${CANARY_EXPECTED_GATES:-actions-direct build-python-direct coverage-lcov egress node-bun node-npm node-pnpm perms playwright python python-private-dep retry rust rust-build-siblings rust-release-build siblings verify-fresh-install vuln-suppression}"
CANARY_INCLUDE_MANUAL="${CANARY_INCLUDE_MANUAL:-false}"
CANARY_TIMEOUT_SECONDS="${CANARY_TIMEOUT_SECONDS:-1500}"
CANARY_POLL_SECONDS="${CANARY_POLL_SECONDS:-30}"
CANARY_SINCE_SLACK_SECONDS="${CANARY_SINCE_SLACK_SECONDS:-120}"
CANARY_WRITE_RETRY_SECONDS="${CANARY_WRITE_RETRY_SECONDS:-10}"
CANARY_KEEP_BRANCH="${CANARY_KEEP_BRANCH:-false}"
CANARY_SOURCE_URL="${CANARY_SOURCE_URL:-}"

# Same pattern as the fixture's scripts/pin.sh: reusable workflow or direct
# composite action reference, followed by a 40-hex pin.
PIN_RE='lgtm-hq/lgtm-ci/\.github/(workflows/[A-Za-z0-9._-]+\.yml|actions/[A-Za-z0-9._-]+)@'

# Set by create_canary_branch once the ref exists; the EXIT trap deletes only
# a branch this invocation created.
CANARY_BRANCH_CREATED=0
CANARY_BRANCH=""
CANARY_WORKDIR=""

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
	# App-token reach and SBOM release upload: self-cleaning release paths.
	app-token-probe.yml | sbom-release-upload.yml)
		printf 'informational\tsuccess\n'
		;;
	# Negative-by-design probes: a green run here is the finding.
	verify-negative.yml | playwright-negative.yml)
		printf 'informational\tfailure\n'
		;;
	# Under-permissioned caller: GitHub rejects the run at parse time.
	perms-negative.yml)
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
		printf 'skip\t%s\n' "fork pull request: EXTERNAL_FIXTURE_TOKEN is not available; re-run from a same-repository branch"
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

# A write to the fixture (git data API, dispatch) with one bounded retry and
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
	printf 'canary/%s\n' "${1:?sha required}"
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
# would otherwise run old code and report green).
rewrite_pins() {
	local file="${1:?file required}" sha="${2:?sha required}" stale
	[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "not a full SHA: $sha"
	sed -E "s#(${PIN_RE})[0-9a-f]{40}#\1${sha}#g" "$file" >"$file.tmp"
	mv "$file.tmp" "$file"
	# Only `uses:` lines count: header comments quote the pattern with a
	# `@<sha>` placeholder.
	stale="$(grep -E '^[[:space:]]*(-[[:space:]]+)?uses:' "$file" | grep -oE "${PIN_RE}[^[:space:]\"']+" | grep -v "@${sha}\$" || true)"
	[[ -z "$stale" ]] || die "$(basename "$file"): lgtm-ci reference not pinned to the candidate: ${stale//$'\n'/, }"
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

# Create branch canary/<sha> on the fixture with every workflow re-pinned.
# Fetches the base branch's workflow files (direct .yml children of
# .github/workflows/ only) into <workdir>, rewrites them,
# and commits via the git data API. Sets CANARY_BRANCH_CREATED=1 once the
# ref exists. Prints the new commit SHA.
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
		die "cannot create ${FIXTURE_REPO}@${branch} (another canary for this SHA may hold it; it is left untouched)"
	CANARY_BRANCH_CREATED=1
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
	fi
}

# Dispatch one workflow file on the canary branch.
dispatch_workflow() {
	local file="${1:?workflow file required}" branch="${2:?branch required}"
	fixture_write "dispatch ${file}" -X POST "repos/${FIXTURE_REPO}/actions/workflows/${file}/dispatches" -f ref="$branch" >/dev/null
}

# Poll the fixture's workflow_dispatch runs on <branch> created at or after
# <since> (ISO-8601 UTC) until every workflow in <files...> has a completed
# run or the bound is reached. Prints one TSV row per workflow:
#   <file>\t<conclusion>\t<run url>\t<run name>
# conclusion is the run's conclusion, `timeout` when still running at the
# bound, or `missing` when no run ever appeared. A failed list fetch keeps
# the previous snapshot.
poll_runs() {
	local branch="${1:?branch required}" since="${2:?since required}"
	shift 2
	local files=("$@") deadline runs="" fresh pending file row
	((${#files[@]})) || return 0

	deadline=$((SECONDS + CANARY_TIMEOUT_SECONDS))
	while :; do
		if fresh="$(fixture_api -X GET \
			"repos/${FIXTURE_REPO}/actions/runs?branch=${branch}&event=workflow_dispatch&created=%3E%3D${since}&per_page=100" \
			--jq '.workflow_runs[] | [(.path | sub("^\\.github/workflows/"; "")), .status, (.conclusion // ""), .html_url, .name] | @tsv')"; then
			runs="$fresh"
		else
			log_warn "run list fetch failed; keeping the previous snapshot"
		fi
		pending=0
		for file in "${files[@]}"; do
			row="$(awk -F'\t' -v f="$file" '$1 == f { print; exit }' <<<"$runs")"
			if [[ -z "$row" ]] || [[ "$(cut -f2 <<<"$row")" != "completed" ]]; then
				pending=$((pending + 1))
			fi
		done
		if ((pending == 0)) || ((SECONDS >= deadline)); then
			break
		fi
		log_info "waiting on ${pending}/${#files[@]} fixture workflows ($((deadline - SECONDS))s left)"
		sleep "$CANARY_POLL_SECONDS"
	done

	for file in "${files[@]}"; do
		row="$(awk -F'\t' -v f="$file" '$1 == f { print; exit }' <<<"$runs")"
		if [[ -z "$row" ]]; then
			printf '%s\tmissing\t\t\n' "$file"
		elif [[ "$(cut -f2 <<<"$row")" != "completed" ]]; then
			printf '%s\ttimeout\t%s\t%s\n' "$file" "$(cut -f4 <<<"$row")" "$(cut -f5 <<<"$row")"
		else
			printf '%s\t%s\t%s\t%s\n' "$file" "$(cut -f3 <<<"$row")" "$(cut -f4 <<<"$row")" "$(cut -f5 <<<"$row")"
		fi
	done
}

# Verdict for one row: "pass" when the conclusion equals the expected one,
# "skipped" for a manual workflow that was not dispatched, else "fail".
verdict_for() {
	local file="${1:?}" conclusion="${2:?}"
	if [[ "$conclusion" == "not_dispatched" ]]; then
		printf 'skipped\n'
	elif [[ "$conclusion" == "$(workflow_expected "$file")" ]]; then
		printf 'pass\n'
	else
		printf 'fail\n'
	fi
}

# Render the markdown table for result rows (stdin, poll_runs format).
render_summary() {
	local sha="${1:?sha required}" branch="${2:-}" file conclusion url name role expected verdict mark link
	echo "## External consumer canary"
	echo
	echo "Fixture: \`${FIXTURE_REPO}\` at branch \`${branch:-canary/${sha}}\`, every lgtm-ci reference pinned to \`${sha}\`."
	echo
	echo "| Workflow | Role | Expected | Conclusion | Verdict | Run |"
	echo "|---|---|---|---|---|---|"
	while IFS=$'\t' read -r file conclusion url name; do
		[[ -n "$file" ]] || continue
		role="$(workflow_role "$file")"
		expected="$(workflow_expected "$file")"
		verdict="$(verdict_for "$file" "$conclusion")"
		case "$verdict" in
		pass) mark="✅ pass" ;;
		skipped) mark="➖ not dispatched" ;;
		*)
			if [[ "$role" == "gate" ]]; then
				mark="❌ **gate failed**"
			else
				mark="⚠️ unexpected"
			fi
			;;
		esac
		link="—"
		[[ -z "$url" ]] || link="[run](${url})"
		echo "| \`${file}\` | ${role} | \`${expected}\` | \`${conclusion}\` | ${mark} | ${link} |"
	done
}

# Print the gate workflows whose conclusion is not the expected one (stdin:
# result rows). Exit 0 either way; the caller counts the lines.
failed_gates() {
	local file conclusion _rest
	while IFS=$'\t' read -r file conclusion _rest; do
		[[ -n "$file" ]] || continue
		is_gate "$file" || continue
		[[ "$(verdict_for "$file" "$conclusion")" == "pass" ]] || printf '%s\t%s\n' "$file" "$conclusion"
	done
}

_write_output() {
	[[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
	printf '%s\n' "$@" >>"$GITHUB_OUTPUT"
}

_write_summary() {
	[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
	printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"
}

# EXIT trap: remove the work dir and the branch this run created.
_cleanup() {
	[[ -z "$CANARY_WORKDIR" ]] || rm -rf "$CANARY_WORKDIR"
	if [[ "$CANARY_BRANCH_CREATED" == 1 && "$CANARY_KEEP_BRANCH" != "true" ]]; then
		delete_canary_branch "$CANARY_BRANCH"
	fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local ref="${1:-${CANDIDATE_REF:-}}"
	[[ -n "$ref" ]] || die "usage: $0 <lgtm-ci ref or sha>"
	command -v jq >/dev/null || die "jq is required"

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
	_require_env GH_TOKEN

	local sha since results table failures
	sha="$(resolve_candidate_sha "$ref")"
	CANARY_BRANCH="$(canary_branch_name "$sha")"
	CANARY_WORKDIR="$(mktemp -d)"
	log_info "candidate ${GITHUB_REPOSITORY}@${sha}"
	trap _cleanup EXIT

	create_canary_branch "$sha" "$CANARY_WORKDIR" >/dev/null

	# Discover, then split into dispatch targets and pre-filled rows.
	local -a to_dispatch=() dispatched=() extra_rows=()
	local file gate seen
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		if should_dispatch "$file"; then
			to_dispatch+=("$file")
		else
			extra_rows+=("$(printf '%s\tnot_dispatched\t\t' "$file")")
		fi
	done < <(discover_dispatchable "$CANARY_WORKDIR")
	for gate in $CANARY_EXPECTED_GATES; do
		seen=0
		for file in "${to_dispatch[@]}"; do
			[[ "$file" == "${gate}.yml" ]] && seen=1
		done
		((seen)) || extra_rows+=("$(printf '%s\tnot_dispatchable\t\t' "${gate}.yml")")
	done
	((${#to_dispatch[@]})) || die "no fixture workflow declares workflow_dispatch"

	since="$(since_timestamp)"
	for file in "${to_dispatch[@]}"; do
		if dispatch_workflow "$file" "$CANARY_BRANCH"; then
			log_info "dispatched ${file} on ${CANARY_BRANCH}"
			dispatched+=("$file")
		else
			extra_rows+=("$(printf '%s\tdispatch_failed\t\t' "$file")")
		fi
	done

	results="$(
		if ((${#dispatched[@]})); then poll_runs "$CANARY_BRANCH" "$since" "${dispatched[@]}"; fi
		if ((${#extra_rows[@]})); then printf '%s\n' "${extra_rows[@]}"; fi
	)"
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
		if has_label "$CANARY_OVERRIDE_LABEL"; then
			while IFS=$'\t' read -r file conclusion; do
				echo "::warning title=external canary::gate ${file} concluded '${conclusion}' (reported as success: label ${CANARY_OVERRIDE_LABEL})"
			done <<<"$failures"
			_write_summary "" "> ⚠️ Gate failures above are reported as success because the pull request carries the owner-only label \`${CANARY_OVERRIDE_LABEL}\`."
			return 0
		fi
		while IFS=$'\t' read -r file conclusion; do
			echo "::error title=external canary::gate ${file} concluded '${conclusion}'"
		done <<<"$failures"
		return 1
	fi
	log_success "every gate workflow passed on ${FIXTURE_REPO}@${CANARY_BRANCH}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
