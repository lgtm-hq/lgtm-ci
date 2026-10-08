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
#      and the force label always run the full set; a pull request runs it
#      only when it touches an adoption-relevant path (workflows, actions,
#      scripts/ci, schemas, examples); otherwise it exits 0 with a
#      "skipped" summary so the check always reports (no `paths:` filter),
#   1. resolves <ref> to a full lgtm-ci SHA (via the lgtm-ci API, LGTM_CI_TOKEN),
#   2. reads every fixture workflow file from the fixture's base branch,
#      rewrites each lgtm-ci pin to the candidate (same regex as the fixture's
#      scripts/pin.sh) and commits the result through the git data API as
#      branch `canary/<sha>` — never touching the fixture's base branch,
#   3. dispatches every fixture workflow that declares `workflow_dispatch`
#      on that branch,
#   4. polls the fixture's run list until each dispatched workflow has a
#      completed run (bounded by CANARY_TIMEOUT_SECONDS),
#   5. writes a markdown table (workflow, role, expected, conclusion,
#      verdict, run URL) to $GITHUB_STEP_SUMMARY,
#   6. deletes the canary branch (also on failure), and
#   7. exits non-zero when any GATE workflow did not succeed, unless the
#      owner-only override label (CANARY_OVERRIDE_LABEL) is on the pull
#      request, in which case the failure is reported as a warning.
#
# Gate vs informational: every dispatchable fixture workflow is a gate unless
# `classify_workflow` lists it as informational. Informational workflows are
# the release/App-token paths (they mutate the fixture: open a version PR,
# create and delete a prerelease) and the negative-by-design probes (expected
# `failure` / `startup_failure`); their verdict is reported but never fails
# the canary. A workflow this script has never seen is a gate (fail closed).
#
# Environment:
#   GH_TOKEN                 fixture token (EXTERNAL_FIXTURE_TOKEN): Actions
#                            read/write + Contents read/write on the fixture only
#   LGTM_CI_TOKEN            token for the lgtm-ci repository (github.token):
#                            resolves <ref>, lists the PR's files; defaults to GH_TOKEN
#   GITHUB_REPOSITORY        lgtm-ci repository (default lgtm-hq/lgtm-ci)
#   EVENT_NAME               github.event_name (default workflow_dispatch)
#   PR_NUMBER                pull request number (pull_request events)
#   PR_LABELS                comma-separated label names of the pull request
#   PR_HEAD_REPO_FORK        "true" when the PR head is a fork (secret unavailable)
#   CANARY_FORCE_LABEL       label forcing a full run (default needs-external-canary)
#   CANARY_OVERRIDE_LABEL    owner-only label turning gate failures into warnings
#                            (default canary-informational)
#   CANARY_RELEVANT_PATHS    space-separated path prefixes that make a PR
#                            adoption-relevant (default: see below)
#   FIXTURE_REPO             default TurboCoder13/lgtm-ci-consumer-fixture
#   FIXTURE_BASE_BRANCH      default main (read only; never written)
#   CANARY_TIMEOUT_SECONDS   poll bound, default 1500 (25 minutes)
#   CANARY_POLL_SECONDS      poll interval, default 30
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
PR_NUMBER="${PR_NUMBER:-}"
PR_LABELS="${PR_LABELS:-}"
PR_HEAD_REPO_FORK="${PR_HEAD_REPO_FORK:-false}"
CANARY_FORCE_LABEL="${CANARY_FORCE_LABEL:-needs-external-canary}"
CANARY_OVERRIDE_LABEL="${CANARY_OVERRIDE_LABEL:-canary-informational}"
CANARY_RELEVANT_PATHS="${CANARY_RELEVANT_PATHS:-.github/workflows/ .github/actions/ scripts/ci/ schemas/ examples/}"
CANARY_TIMEOUT_SECONDS="${CANARY_TIMEOUT_SECONDS:-1500}"
CANARY_POLL_SECONDS="${CANARY_POLL_SECONDS:-30}"
CANARY_KEEP_BRANCH="${CANARY_KEEP_BRANCH:-false}"
CANARY_SOURCE_URL="${CANARY_SOURCE_URL:-}"

# Same pattern as the fixture's scripts/pin.sh: reusable workflow or direct
# composite action reference, followed by a 40-hex pin.
PIN_RE='lgtm-hq/lgtm-ci/\.github/(workflows/[A-Za-z0-9._-]+\.yml|actions/[A-Za-z0-9._-]+)@'

# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------

# Print "<role>\t<expected conclusion>" for one fixture workflow file name.
# role is `gate` or `informational`. Keep in sync with the header comment of
# .github/workflows/external-consumer-canary.yml (contract-tested).
classify_workflow() {
	local name="${1:?workflow file name required}"
	name="${name##*/}"
	case "$name" in
	# Release / App-token paths: mutate the fixture (open a version PR,
	# create a prerelease) or need the fixture's GitHub App; informational.
	release-version-pr.yml | release-benign-hook.yml | app-token-probe.yml | sbom-release-upload.yml)
		printf 'informational\tsuccess\n'
		;;
	# Negative-by-design probes: a green run here is the finding.
	release-tamper-hook.yml | verify-negative.yml | playwright-negative.yml)
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

is_gate() {
	[[ "$(classify_workflow "$1" | cut -f1)" == "gate" ]]
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

# Changed file names of the pull request, one per line.
pr_changed_files() {
	[[ -n "$PR_NUMBER" ]] || die "PR_NUMBER is required for pull_request events"
	lgtm_ci_api -X GET "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/files?per_page=100" \
		--paginate --jq '.[].filename'
}

# Print "<mode>\t<reason>" where mode is `full` or `skip`.
decide_run_mode() {
	if [[ "$EVENT_NAME" != "pull_request" ]]; then
		printf 'full\t%s\n' "${EVENT_NAME} always runs the full fixture set"
		return 0
	fi
	if has_label "$CANARY_FORCE_LABEL"; then
		printf 'full\t%s\n' "label ${CANARY_FORCE_LABEL} forces a full run"
		return 0
	fi
	if [[ "$PR_HEAD_REPO_FORK" == "true" ]]; then
		printf 'skip\t%s\n' "fork pull request: EXTERNAL_FIXTURE_TOKEN is not available; label ${CANARY_FORCE_LABEL} on a same-repo branch to run it"
		return 0
	fi
	local path
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		if is_adoption_relevant "$path"; then
			printf 'full\t%s\n' "pull request touches ${path}"
			return 0
		fi
	done < <(pr_changed_files)
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

# Rewrite every lgtm-ci pin in one workflow file to the candidate SHA.
rewrite_pins() {
	local file="${1:?file required}" sha="${2:?sha required}"
	[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "not a full SHA: $sha"
	sed -E "s#(${PIN_RE})[0-9a-f]{40}#\1${sha}#g" "$file" >"$file.tmp"
	mv "$file.tmp" "$file"
}

# Print the file names (basenames) under <dir> that declare workflow_dispatch.
discover_dispatchable() {
	local dir="${1:?dir required}" file
	for file in "$dir"/*.yml; do
		[[ -f "$file" ]] || continue
		grep -qE '^[[:space:]]+workflow_dispatch:' "$file" || continue
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
# Fetches the base branch's workflow files into <workdir>, rewrites them,
# and commits via the git data API. Prints the new commit SHA.
create_canary_branch() {
	local sha="${1:?sha required}" workdir="${2:?workdir required}"
	local branch base_sha base_tree path commit_sha tree_sha message

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
		--jq '.tree[] | select(.type == "blob" and (.path | startswith(".github/workflows/")) and (.path | endswith(".yml"))) | .path')

	local count
	count="$(find "$workdir" -maxdepth 1 -name '*.yml' | wc -l | tr -d ' ')"
	[[ "$count" -gt 0 ]] || die "no workflow files found on ${FIXTURE_REPO}@${FIXTURE_BASE_BRANCH}"
	log_info "re-pinned ${count} fixture workflow files to ${sha}"

	tree_sha="$(build_tree_payload "$base_tree" "$workdir" |
		fixture_api -X POST "repos/${FIXTURE_REPO}/git/trees" --input - --jq .sha)"

	message="canary: pin every lgtm-ci reference to ${sha}"
	[[ -z "$CANARY_SOURCE_URL" ]] || message+=$'\n\n'"Source: ${CANARY_SOURCE_URL}"
	commit_sha="$(jq -n --arg m "$message" --arg t "$tree_sha" --arg p "$base_sha" \
		'{message: $m, tree: $t, parents: [$p]}' |
		fixture_api -X POST "repos/${FIXTURE_REPO}/git/commits" --input - --jq .sha)"

	fixture_api -X POST "repos/${FIXTURE_REPO}/git/refs" \
		-f ref="refs/heads/${branch}" -f sha="$commit_sha" --jq .ref >/dev/null
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
	fixture_api -X POST "repos/${FIXTURE_REPO}/actions/workflows/${file}/dispatches" -f ref="$branch"
}

# Poll the fixture's workflow_dispatch runs on <branch> created at or after
# <since> (ISO-8601 UTC) until every workflow in <files...> has a completed
# run or the bound is reached. Prints one TSV row per workflow:
#   <file>\t<conclusion>\t<run url>\t<run name>
# conclusion is the run's conclusion, `timeout` when still running at the
# bound, or `missing` when no run ever appeared.
poll_runs() {
	local branch="${1:?branch required}" since="${2:?since required}"
	shift 2
	local files=("$@") deadline runs pending file row
	((${#files[@]})) || die "poll_runs: no workflows to poll"

	deadline=$((SECONDS + CANARY_TIMEOUT_SECONDS))
	while :; do
		runs="$(fixture_api -X GET \
			"repos/${FIXTURE_REPO}/actions/runs?branch=${branch}&event=workflow_dispatch&created=%3E%3D${since}&per_page=100" \
			--jq '.workflow_runs[] | [(.path | sub("^\\.github/workflows/"; "")), .status, (.conclusion // ""), .html_url, .name] | @tsv')" || runs=""
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

# Verdict for one row: "pass" when the conclusion equals the expected one.
verdict_for() {
	local file="${1:?}" conclusion="${2:?}" expected
	expected="$(classify_workflow "$file" | cut -f2)"
	[[ "$conclusion" == "$expected" ]] && printf 'pass\n' || printf 'fail\n'
}

# Render the markdown table for a poll_runs result (stdin).
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
		role="$(classify_workflow "$file" | cut -f1)"
		expected="$(classify_workflow "$file" | cut -f2)"
		verdict="$(verdict_for "$file" "$conclusion")"
		if [[ "$verdict" == "pass" ]]; then
			mark="✅ pass"
		elif [[ "$role" == "gate" ]]; then
			mark="❌ **gate failed**"
		else
			mark="⚠️ unexpected"
		fi
		link="—"
		[[ -z "$url" ]] || link="[run](${url})"
		echo "| \`${file}\` | ${role} | \`${expected}\` | \`${conclusion}\` | ${mark} | ${link} |"
	done
}

# Print the gate workflows whose conclusion is not the expected one (stdin:
# poll_runs rows). Exit 0 either way; the caller counts the lines.
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local ref="${1:-${CANDIDATE_REF:-}}"
	[[ -n "$ref" ]] || die "usage: $0 <lgtm-ci ref or sha>"
	command -v jq >/dev/null || die "jq is required"

	local mode reason
	IFS=$'\t' read -r mode reason < <(decide_run_mode)
	if [[ "$mode" == "skip" ]]; then
		log_info "skipped: ${reason}"
		_write_summary "## External consumer canary" "" "Skipped: ${reason}."
		_write_output "mode=skipped" "gate-failures=0"
		echo "::notice title=external canary::skipped: ${reason}"
		return 0
	fi
	log_info "running the full fixture set: ${reason}"
	_require_env GH_TOKEN

	local sha branch workdir since results table failures
	sha="$(resolve_candidate_sha "$ref")"
	branch="$(canary_branch_name "$sha")"
	workdir="$(mktemp -d)"
	log_info "candidate ${GITHUB_REPOSITORY}@${sha}"

	# Delete the branch on every exit path unless asked to keep it.
	# shellcheck disable=SC2064
	trap "rm -rf '$workdir'; [[ '$CANARY_KEEP_BRANCH' == 'true' ]] || delete_canary_branch '$branch'" EXIT

	create_canary_branch "$sha" "$workdir" >/dev/null

	local -a files=()
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		files+=("$file")
	done < <(discover_dispatchable "$workdir")
	((${#files[@]})) || die "no fixture workflow declares workflow_dispatch"

	since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	local file
	for file in "${files[@]}"; do
		if dispatch_workflow "$file" "$branch"; then
			log_info "dispatched ${file} on ${branch}"
		else
			log_error "dispatch failed for ${file}"
		fi
	done

	results="$(poll_runs "$branch" "$since" "${files[@]}")"
	table="$(render_summary "$sha" "$branch" <<<"$results")"
	printf '%s\n' "$table"
	_write_summary "$table"

	failures="$(failed_gates <<<"$results")"
	_write_output "mode=full" "branch=${branch}" \
		"gate-failures=$(grep -c . <<<"$failures" || true)" \
		"table<<LGTM_CI_CANARY_EOF" "$table" "LGTM_CI_CANARY_EOF"

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
	log_success "every gate workflow passed on ${FIXTURE_REPO}@${branch}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
