#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Surface workflow failures via step summary and deduplicated issues.
# Originally release-specific; now parameterized so any main-branch workflow
# (via reusable-main-failure-notifier.yml) can use the same mechanism.
#
# Subcommands:
#   write_trigger_summary   — append trigger context to $GITHUB_STEP_SUMMARY
#   notify_failure          — create or comment on a deduplicated GitHub issue
#   notify_release_failure  — release mode: dedup by tag, branch gate bypassed,
#                             publish-channel table in the body
#   close_release_failure   — release mode: comment and close the deduplicated
#                             issue when the tag publishes successfully
#   classify_release_failure — release mode: print success|failure|rerunning
#                             for the caller's publish channels; "rerunning"
#                             means an automatic infra re-run may still be in
#                             flight, so the notifier must stay quiet for now
#
# Required environment variables:
#   WORKFLOW_KEY        — Stable workflow key for marker namespacing
#                         (e.g. release-version-pr, docker-publish).
#                         RELEASE_WORKFLOW_KEY is honored as a fallback.
#                         Required by both subcommands.
#   GH_TOKEN            — GitHub token with issues: write (notify_failure only)
#   GITHUB_REPOSITORY   — Target repository (owner/name) (notify_failure only)
#
# Optional parameterization (defaults preserve the release wording so existing
# callers and open dedup'd issues keep working):
#   FAILURE_MARKER_PREFIX — dedup marker/tracking-key prefix
#                           (default: release-automation-failure)
#   FAILURE_TITLE_PREFIX  — issue title prefix
#                           (default: "fix(release): release automation failed on")
#   FAILURE_SUMMARY_TEXT  — first body sentence (default: release wording)
#   FAILURE_HEADING_LABEL — step-summary heading label
#                           (default: "Release Automation")

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"
# shellcheck source=../lib/github/summary.sh
source "$SCRIPT_DIR/../lib/github/summary.sh"
# Sourced for the transient-infrastructure signature matcher, which the
# release-mode classifier reuses so "an automatic re-run may still fire" is
# decided by exactly the same signatures the auto-rerun safety net acts on.
# shellcheck source=../lib/infra-signatures.sh
source "$SCRIPT_DIR/../lib/infra-signatures.sh"

usage() {
	cat <<'EOF'
Usage: report-release-failure.sh <subcommand>

Subcommands:
  write_trigger_summary    Write release trigger context to $GITHUB_STEP_SUMMARY
  notify_failure           Create or update a deduplicated GitHub issue on target branch
  notify_release_failure   Release mode: dedup by tag, channel table in the body
  close_release_failure    Release mode: comment and close the issue on success
  classify_release_failure Release mode: print success|failure|rerunning
EOF
}

release_branch() {
	if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_run" ]]; then
		echo "${UPSTREAM_HEAD_BRANCH:-${GITHUB_REF_NAME:-unknown}}"
	else
		echo "${GITHUB_REF_NAME:-unknown}"
	fi
}

release_sha() {
	if [[ -n "${CHECKOUT_SHA:-}" ]]; then
		echo "$CHECKOUT_SHA"
	elif [[ "${GITHUB_EVENT_NAME:-}" == "workflow_run" && -n "${UPSTREAM_HEAD_SHA:-}" ]]; then
		echo "$UPSTREAM_HEAD_SHA"
	else
		echo "${GITHUB_SHA:-unknown}"
	fi
}

run_url() {
	echo "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}/actions/runs/${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
}

upstream_run_url() {
	if [[ -n "${UPSTREAM_RUN_URL:-}" ]]; then
		echo "$UPSTREAM_RUN_URL"
	elif [[ -n "${UPSTREAM_RUN_ID:-}" ]]; then
		echo "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}/actions/runs/${UPSTREAM_RUN_ID}"
	else
		echo ""
	fi
}

workflow_key() {
	if [[ -n "${WORKFLOW_KEY:-}" ]]; then
		echo "$WORKFLOW_KEY"
	else
		echo "${RELEASE_WORKFLOW_KEY:?WORKFLOW_KEY (or RELEASE_WORKFLOW_KEY) is required}"
	fi
}

marker_prefix() {
	echo "${FAILURE_MARKER_PREFIX:-release-automation-failure}"
}

marker_key() {
	local branch="${1:-$(release_branch)}"
	echo "$(marker_prefix):$(workflow_key):${branch}"
}

issue_marker() {
	local branch="${1:?branch is required}"
	echo "<!-- $(marker_key "$branch") -->"
}

failure_issue_title() {
	local target_branch="${1:?target_branch is required}"
	local prefix="${FAILURE_TITLE_PREFIX:-fix(release): release automation failed on}"
	printf '%s %s (%s)' "$prefix" "$target_branch" "$(workflow_key)"
}

resolve_target_branch() {
	if [[ -n "${FAILURE_TARGET_BRANCH:-}" ]]; then
		echo "$FAILURE_TARGET_BRANCH"
		return
	fi

	local default_branch="main"
	if [[ -n "${GH_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
		default_branch="$(gh repo view "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}" \
			--json defaultBranchRef \
			--jq '.defaultBranchRef.name' 2>/dev/null || echo main)"
	fi
	echo "$default_branch"
}

write_trigger_summary() {
	local branch
	local sha
	local current_run_url
	local upstream_url
	local heading_label="${FAILURE_HEADING_LABEL:-Release Automation}"
	local heading="## ${heading_label} Context"

	if [[ -z "${GITHUB_STEP_SUMMARY:-}" ]]; then
		log_error "GITHUB_STEP_SUMMARY is required"
		exit 1
	fi

	# Validate up front: later uses run in command substitutions, where the
	# :? expansion would kill only the subshell and the script would exit 0.
	workflow_key >/dev/null

	branch="$(release_branch)"
	sha="$(release_sha)"
	current_run_url="$(run_url)"
	upstream_url="$(upstream_run_url)"

	if [[ "${PRIMARY_JOB_FAILED:-false}" == "true" ]]; then
		heading="## ${heading_label} Failure"
	fi

	add_github_summary "$heading"
	add_github_summary ""
	add_github_summary "- **Workflow:** ${GITHUB_WORKFLOW:-unknown}"
	add_github_summary "- **Workflow key:** $(workflow_key)"
	add_github_summary "- **Event:** ${GITHUB_EVENT_NAME:-unknown}"
	add_github_summary "- **Branch:** ${branch}"
	add_github_summary "- **Checkout SHA:** ${sha}"
	add_github_summary "- **Actor:** ${GITHUB_ACTOR:-unknown}"
	add_github_summary "- **Run:** ${current_run_url}"

	if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_run" ]]; then
		add_github_summary ""
		add_github_summary "### Upstream Workflow"
		add_github_summary ""
		add_github_summary "- **Workflow:** ${UPSTREAM_WORKFLOW_NAME:-unknown}"
		add_github_summary "- **Run ID:** ${UPSTREAM_RUN_ID:-unknown}"
		if [[ -n "$upstream_url" ]]; then
			add_github_summary "- **Run:** ${upstream_url}"
		fi
		add_github_summary "- **Conclusion:** ${UPSTREAM_CONCLUSION:-unknown}"
		add_github_summary "- **Head branch:** ${UPSTREAM_HEAD_BRANCH:-unknown}"
		add_github_summary "- **Head SHA:** ${UPSTREAM_HEAD_SHA:-unknown}"
	fi
}

failed_step_summary() {
	if ! command -v gh >/dev/null 2>&1; then
		echo "Failed job and step details unavailable because gh is not installed."
		return
	fi

	local failed
	# gh --jq receives this expression literally; shell variables inside it are jq variables.
	# shellcheck disable=SC2016
	failed=$(
		gh run view "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}" \
			--repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}" \
			--json jobs \
			--jq '.jobs[] | select(.conclusion == "failure") | .name as $job | if ([.steps[]? | select(.conclusion == "failure")] | length) > 0 then .steps[]? | select(.conclusion == "failure") | "- **Job:** " + $job + "\n  **Step:** " + .name else "- **Job:** " + $job + "\n  **Step:** unavailable" end' \
			2>/dev/null || true
	)

	if [[ -n "$failed" ]]; then
		echo "$failed"
	else
		echo "Failed job and step details unavailable. See the run logs."
	fi
}

render_failure_body() {
	local target_branch="${1:?target_branch is required}"
	local sha
	local current_run_url
	local upstream_url
	local marker
	local tracking_key
	sha="$(release_sha)"
	current_run_url="$(run_url)"
	upstream_url="$(upstream_run_url)"
	marker="$(issue_marker "$target_branch")"
	tracking_key="$(marker_key "$target_branch")"

	cat <<EOF
$marker

## Summary

${FAILURE_SUMMARY_TEXT:-Release automation failed on \`${target_branch}\`. This issue keeps post-merge release failures visible outside the Actions history.}

## Failure Context

- **Workflow:** ${GITHUB_WORKFLOW:-unknown}
- **Workflow key:** $(workflow_key)
- **Event:** ${GITHUB_EVENT_NAME:-unknown}
- **Branch:** ${target_branch}
- **SHA:** ${sha}
- **Actor:** ${GITHUB_ACTOR:-unknown}
- **Run:** ${current_run_url}
EOF

	if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_run" ]]; then
		cat <<EOF

## Upstream Workflow

- **Workflow:** ${UPSTREAM_WORKFLOW_NAME:-unknown}
- **Run ID:** ${UPSTREAM_RUN_ID:-unknown}
EOF
		if [[ -n "$upstream_url" ]]; then
			echo "- **Run:** ${upstream_url}"
		fi
		cat <<EOF
- **Conclusion:** ${UPSTREAM_CONCLUSION:-unknown}
- **Head branch:** ${UPSTREAM_HEAD_BRANCH:-unknown}
- **Head SHA:** ${UPSTREAM_HEAD_SHA:-unknown}
EOF
	fi

	cat <<EOF

## Failed Job or Step

$(failed_step_summary)

## Suggested Next Action

Open the failed run, inspect the failed step logs, and either fix the release automation failure or close this issue with the run URL if the failure was transient.

---
**Tracking key:** \`${tracking_key}\`
EOF
}

lookup_open_issue() {
	local search_query="$1"
	local issue_number
	local search_output
	local gh_stderr

	gh_stderr="$(mktemp)"
	if ! search_output="$(gh issue list \
		--repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}" \
		--state open \
		--limit 1 \
		--search "$search_query" \
		--json number \
		--jq '.[0].number // empty' 2>"$gh_stderr")"; then
		log_info "Release failure issue search failed: $(cat "$gh_stderr")"
		rm -f "$gh_stderr"
		return 1
	fi
	rm -f "$gh_stderr"

	issue_number="$search_output"
	if [[ "$issue_number" =~ ^[0-9]+$ ]]; then
		echo "$issue_number"
	fi
	return 0
}

find_existing_issue() {
	local target_branch="${1:?target_branch is required}"
	local title
	local search_key
	local issue_number

	title="$(failure_issue_title "$target_branch")"
	if issue_number="$(lookup_open_issue "\"${title}\" in:title")"; then
		if [[ -n "$issue_number" ]]; then
			echo "$issue_number"
			return
		fi
	else
		log_info "Title search unavailable; falling back to tracking key"
	fi

	# Visible tracking keys are indexed; HTML comment markers may not be.
	search_key="$(marker_key "$target_branch")"
	if issue_number="$(lookup_open_issue "\"${search_key}\"")"; then
		if [[ -n "$issue_number" ]]; then
			echo "$issue_number"
		fi
	else
		log_error "Could not search for existing release failure issues"
		exit 1
	fi
}

collect_existing_issue_label_args() {
	local -n _label_args=$1
	local default_labels="${FAILURE_ISSUE_LABELS:-bug,ci,release,automation,infrastructure}"
	local label
	local repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

	_label_args=()
	local -a labels
	IFS=',' read -ra labels <<<"$default_labels"
	for label in "${labels[@]}"; do
		label="$(echo "$label" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		if [[ -z "$label" ]]; then
			continue
		fi
		if gh label view "$label" --repo "$repo" >/dev/null 2>&1; then
			_label_args+=(--label "$label")
		else
			log_info "Skipping missing issue label '$label'"
		fi
	done
}

comment_on_failure_issue() {
	local issue_number="$1"
	local body_file="$2"
	gh issue comment "$issue_number" \
		--repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}" \
		--body-file "$body_file" >/dev/null
	log_success "Updated release failure issue #${issue_number}"
}

create_failure_issue() {
	local body_file="$1"
	local target_branch="$2"
	local title
	local issue_url
	local label_args=()
	title="$(failure_issue_title "$target_branch")"
	collect_existing_issue_label_args label_args
	if ((${#label_args[@]} > 0)); then
		if ! issue_url="$(gh issue create \
			--repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}" \
			--title "$title" \
			--body-file "$body_file" \
			"${label_args[@]}")"; then
			return 1
		fi
	else
		if ! issue_url="$(gh issue create \
			--repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}" \
			--title "$title" \
			--body-file "$body_file")"; then
			return 1
		fi
	fi
	log_success "Created release failure issue: ${issue_url}"
}

notify_failure() {
	local branch
	local target_branch
	local body_file
	local existing_issue

	if [[ -z "${GH_TOKEN:-}" ]]; then
		log_error "GH_TOKEN is required"
		exit 1
	fi

	if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
		log_error "GITHUB_REPOSITORY is required"
		exit 1
	fi

	if ! command -v gh >/dev/null 2>&1; then
		log_error "gh CLI is required to report release automation failures"
		exit 1
	fi

	# Validate up front: later uses run in command substitutions, where the
	# :? expansion would kill only the subshell and the script would exit 0.
	workflow_key >/dev/null

	branch="$(release_branch)"
	target_branch="$(resolve_target_branch)"

	if [[ "$branch" != "$target_branch" ]]; then
		log_info "Release failure notification skipped for branch '$branch' (target: '$target_branch')"
		exit 0
	fi

	_notify_failure_for_target "$target_branch" render_failure_body
}

# Shared create-or-comment flow behind notify_failure and
# notify_release_failure. $1 is the dedup target (branch or tag) already
# validated against the caller's gate; $2 names the body renderer so each
# mode keeps its own issue shape.
_notify_failure_for_target() {
	local target="$1"
	local renderer="$2"
	local body_file
	local existing_issue

	body_file="$(mktemp)"
	trap 'rm -f "$body_file"' EXIT
	"$renderer" "$target" >"$body_file"

	existing_issue="$(find_existing_issue "$target")"
	if [[ -n "$existing_issue" ]]; then
		comment_on_failure_issue "$existing_issue" "$body_file"
	else
		# Brief pause reduces duplicate issues when concurrent runs fail together.
		sleep 2
		existing_issue="$(find_existing_issue "$target")"
		if [[ -n "$existing_issue" ]]; then
			comment_on_failure_issue "$existing_issue" "$body_file"
		elif create_failure_issue "$body_file" "$target"; then
			:
		else
			existing_issue="$(find_existing_issue "$target")"
			if [[ -n "$existing_issue" ]]; then
				comment_on_failure_issue "$existing_issue" "$body_file"
			else
				log_error "Failed to create release failure issue"
				exit 1
			fi
		fi
	fi

	rm -f "$body_file"
	trap - EXIT
}

# =============================================================================
# Release mode (tag publishes) — #964
# =============================================================================
#
# A tag-triggered publish run has no branch to gate on (GITHUB_REF_NAME is the
# tag), so the branch gate of notify_failure would silently swallow every
# failure (report-release-failure.sh returned 0 for any non-branch ref). The
# release mode deduplicates by tag instead, renders the caller's publish
# channels as a table, and pairs file-on-failure with close-on-success under
# the same key.

release_tag() {
	echo "${RELEASE_TAG:?RELEASE_TAG is required}"
}

# Validations shared by the release-mode issue-writing subcommands.
_require_issue_access() {
	if [[ -z "${GH_TOKEN:-}" ]]; then
		log_error "GH_TOKEN is required"
		exit 1
	fi
	if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
		log_error "GITHUB_REPOSITORY is required"
		exit 1
	fi
	if ! command -v gh >/dev/null 2>&1; then
		log_error "gh CLI is required to report release automation failures"
		exit 1
	fi
	workflow_key >/dev/null
	if [[ -z "${RELEASE_TAG:-}" ]]; then
		log_error "RELEASE_TAG is required"
		exit 1
	fi
}

# jq filter shared by the channel table and the verdict: normalizes the two
# accepted CHANNELS_JSON shapes to an array of objects, or fails on any other
# shape. Accepted:
#   [{"name":"pypi","result":"failure","url":"https://...","probe":"absent"}]
#   {"pypi":{"result":"failure"},"npm":{"result":"success"}}   (toJson(needs))
# Rejected (jq exits non-zero): null, scalars, arrays with non-object members,
# objects with non-object values such as {"pypi":"failure"}.
CHANNELS_NORMALIZE_JQ='
	if type == "array" and all(.[]; type == "object") then .
	elif type == "object" and all(.[]; type == "object") then [to_entries[] | (.value + {name: .key})]
	else error("unrecognized channel payload shape") end
'

# True when CHANNELS_JSON parses and has one of the accepted shapes.
channels_shape_ok() {
	printf '%s' "$1" | jq -e "$CHANNELS_NORMALIZE_JQ" >/dev/null 2>&1
}

# Rows of the publish-channel table from CHANNELS_JSON.
#
# `toJson(needs)` carries job results and outputs but no job URLs, so a
# channel without a `url` links to the run (which lists every job) rather
# than rendering nothing: the issue must always give a responder a link.
# `probe` is the optional published/not-yet-published check; when a caller
# does not supply one the column renders an em dash rather than a lie.
channel_table_rows() {
	local channels="${CHANNELS_JSON:-[]}"
	if ! printf '%s' "$channels" | jq -e . >/dev/null 2>&1; then
		log_warn "CHANNELS_JSON is not valid JSON; the channel table will say so"
		echo "| *(unparseable channel payload)* | | | |"
		return 0
	fi
	if ! channels_shape_ok "$channels"; then
		log_warn "CHANNELS_JSON has an unrecognized shape; the channel table will say so"
		echo "| *(unrecognized channel payload shape; expected an array of objects or toJson(needs))* | | | |"
		return 0
	fi
	# Every field goes through tostring: a caller-built array may carry a
	# number or object where a string is expected, and a jq type error here
	# would abort the render and leave the release failure unfiled. A url
	# that is not a string cannot be linked, so it falls back to the run link.
	jq -r --arg run_url "$(run_url)" "${CHANNELS_NORMALIZE_JQ}"'
		| .[]
		| [((.name // "unknown") | tostring), ((.result // "unknown") | tostring),
		   (.url | if type == "string" then . else "" end), ((.probe // "") | tostring)]
		| "| " + .[0] + " | " + .[1] + " | "
		  + (if .[2] == "" then "[run](" + $run_url + ")" else "[job](" + .[2] + ")" end)
		  + " | " + (if .[3] == "" then "—" else .[3] end) + " |"
	' <<<"$channels"
}

render_channel_table() {
	echo "| Channel | Result | Job | Probe |"
	echo "| --- | --- | --- | --- |"
	local rows
	rows="$(channel_table_rows)"
	if [[ -z "$rows" ]]; then
		echo "| *(no channels reported)* | | | |"
	else
		printf '%s\n' "$rows"
	fi
}

# One sentence describing why the notifier is filing now, from the classify
# step's `reason` output (FAILURE_REASON). Every filed issue used to claim
# "retries were exhausted", which was false for a first-attempt failure with
# no infra signature and sent responders to the wrong recovery tier.
release_failure_summary_sentence() {
	local tag="$1"
	local attempt="${RUN_ATTEMPT:-unknown}"
	local max_reruns="${MAX_RERUNS:-unknown}"
	case "${FAILURE_REASON:-}" in
	budget-exhausted)
		if [[ "$max_reruns" == "0" ]]; then
			echo "A tag publish for \`${tag}\` failed on attempt ${attempt} with automatic re-runs disabled (max-reruns 0), so no further attempt will fire."
		else
			echo "A tag publish for \`${tag}\` failed on attempt ${attempt} after the automatic re-run budget (max-reruns ${max_reruns}) was exhausted."
		fi
		;;
	no-infra-signature)
		echo "A tag publish for \`${tag}\` failed on attempt ${attempt}; the failed-job logs match no known transient-infrastructure signature, so no automatic re-run will fire."
		;;
	logs-unavailable)
		echo "A tag publish for \`${tag}\` failed on attempt ${attempt}; the failed-job logs could not be classified in time, so this issue is filed now even though an automatic re-run may still be pending."
		;;
	attempt-invalid)
		echo "A tag publish for \`${tag}\` failed and the run attempt could not be read, so this is treated as the final attempt."
		;;
	channels-invalid)
		echo "A tag publish for \`${tag}\` reported a publish-channel payload the notifier could not parse, so it is filed as a failure to keep the run visible."
		;;
	*)
		echo "A tag publish for \`${tag}\` failed."
		;;
	esac
}

render_release_failure_body() {
	local tag="${1:?tag is required}"
	local sha
	local current_run_url
	local marker
	local tracking_key
	sha="$(release_sha)"
	current_run_url="$(run_url)"
	marker="$(issue_marker "$tag")"
	tracking_key="$(marker_key "$tag")"

	cat <<EOF
$marker

## Summary

$(release_failure_summary_sentence "$tag") This issue keeps the partial release visible with the per-channel state needed to act. Recovery tiers are defined in [docs/release-security-policy.md](https://github.com/lgtm-hq/lgtm-ci/blob/main/docs/release-security-policy.md); the recovery runbook is tracked in lgtm-hq/lgtm-ci#966.

## Failure Context

- **Workflow:** ${GITHUB_WORKFLOW:-unknown}
- **Workflow key:** $(workflow_key)
- **Event:** ${GITHUB_EVENT_NAME:-unknown}
- **Tag:** ${tag}
- **Run attempt:** ${GITHUB_RUN_ATTEMPT:-unknown}
- **Checkout SHA:** ${sha}
- **Actor:** ${GITHUB_ACTOR:-unknown}
- **Run:** ${current_run_url}

## Publish Channels

$(render_channel_table)

## Failed Job or Step

$(failed_step_summary)

## Suggested Next Action

- **Tier 1 (transient infra):** re-run the failed jobs — the known flake signatures are already covered by the automatic re-run safety net.
- **Tier 2 (resume):** run the release recovery workflow against this tag and the original attested artifacts once available (lgtm-hq/lgtm-ci#966); it publishes only the missing channels.
- **Tier 3 (new patch version):** required when any published bytes differ from the attested artifacts, or when PyPI uploaded partially — a PyPI version is burned on first upload and can never be resumed.

---
**Tracking key:** \`${tracking_key}\`
EOF
}

notify_release_failure() {
	_require_issue_access
	# Release-mode namespace for the shared dedup machinery: same tracking-key
	# footer and title lookup as the branch mode, keyed by tag instead.
	FAILURE_MARKER_PREFIX="release-failure"
	FAILURE_TITLE_PREFIX="fix(release): tag publish failed:"
	_notify_failure_for_target "$(release_tag)" render_release_failure_body
}

close_release_failure() {
	_require_issue_access
	local tag
	local title
	local existing
	tag="$(release_tag)"
	FAILURE_MARKER_PREFIX="release-failure"
	FAILURE_TITLE_PREFIX="fix(release): tag publish failed:"
	title="$(failure_issue_title "$tag")"

	# Soft lookups on purpose: the close job runs on a successful release run,
	# and a search API hiccup must not redden a green publish. No open issue is
	# the normal repeat-success case, not an error.
	# Fall through to the visible tracking key both when the title search is
	# unavailable and when it succeeds with no match: an operator who edited
	# the issue title still keeps the key footer, and a green publish must
	# close that issue rather than leave it open.
	if ! existing="$(lookup_open_issue "\"${title}\" in:title")"; then
		log_info "Title search unavailable; falling back to tracking key"
		existing=""
	fi
	if [[ -z "$existing" ]]; then
		if ! existing="$(lookup_open_issue "\"$(marker_key "$tag")\"")"; then
			log_warn "Could not search for the open release-failure issue; leaving it open"
			exit 0
		fi
	fi
	if [[ -z "$existing" ]]; then
		log_info "No open release-failure issue for tag '${tag}'; nothing to close"
		exit 0
	fi

	if ! gh issue close "$existing" \
		--repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}" \
		--comment "Resolved: tag \`${tag}\` is fully published (run: $(run_url)). Closing this issue." >/dev/null; then
		log_error "Failed to close release failure issue #${existing}"
		exit 1
	fi
	log_success "Closed release failure issue #${existing} (tag ${tag} fully published)"
}

# True when CHANNELS_JSON reports at least one channel whose result is neither
# success nor skipped. An empty channel list is NOT "all succeeded": a caller
# that wired no channels has told us nothing, and silence is the failure mode
# this notifier exists to prevent.
channels_all_succeeded() {
	local channels="$1"
	printf '%s' "$channels" | jq -e "${CHANNELS_NORMALIZE_JQ}"'
		| length > 0
		and all(.[]; (((.result // "unknown") | tostring) == "success"
			or ((.result // "unknown") | tostring) == "skipped"))
	' >/dev/null 2>&1
}

# Bounds on the classifier's log fetch, mirroring the auto-rerun safety net
# (scripts/ci/actions/rerun-on-infra-failure.sh): an unbounded
# `gh run view --log-failed` has stalled for a whole job before, and a
# notifier that never writes a verdict is exactly the silent failure this
# mode exists to prevent. Log ingestion can also lag the completion event, so
# an empty fetch is retried until LOG_FETCH_DEADLINE (seconds) runs out.
#   GH_CMD_TIMEOUT        wall-clock bound in seconds on each gh call
#   LOG_FETCH_DEADLINE    wall-clock budget in seconds for the whole fetch loop
#   LOG_FETCH_RETRY_DELAY seconds between empty fetches
#   TIMEOUT_BIN           coreutils timeout binary (default: timeout/gtimeout)
: "${GH_CMD_TIMEOUT:=60}"
: "${LOG_FETCH_DEADLINE:=180}"
: "${LOG_FETCH_RETRY_DELAY:=15}"

_nonnegative_int_or() {
	local value="$1"
	local fallback="$2"
	local name="$3"
	if [[ "$value" =~ ^[0-9]+$ ]]; then
		echo "$value"
	else
		log_warn "${name} '${value}' is not a non-negative integer; using ${fallback}"
		echo "$fallback"
	fi
}

# Zero is not a bound: GNU timeout treats 0 as "no timeout" and a zero
# deadline would never retry, so the command and deadline knobs must be >= 1.
_positive_int_or() {
	local value="$1"
	local fallback="$2"
	local name="$3"
	if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
		echo "$value"
	else
		log_warn "${name} '${value}' is not a positive integer; using ${fallback}"
		echo "$fallback"
	fi
}

_timeout_bin() {
	local candidate
	if [[ -n "${TIMEOUT_BIN:-}" ]]; then
		command -v "$TIMEOUT_BIN" && return 0
		return 1
	fi
	for candidate in timeout gtimeout; do
		command -v "$candidate" && return 0
	done
	return 1
}

# Best-effort, bounded fetch of this run's failed-job logs. Empty output when
# the logs stay unavailable within the deadline (or when no coreutils timeout
# is on PATH to bound gh): the caller treats that as inconclusive and files,
# because a visible duplicate on the issue costs far less than a silently
# exhausted release.
fetch_infra_signature_logs() {
	local timeout_bin
	local cmd_timeout
	local deadline
	local retry_delay
	local started
	local logs
	if ! timeout_bin="$(_timeout_bin)"; then
		log_warn "coreutils timeout is not on PATH; cannot bound the log fetch, classifying logs as unavailable"
		return 0
	fi
	cmd_timeout="$(_positive_int_or "$GH_CMD_TIMEOUT" 60 GH_CMD_TIMEOUT)"
	deadline="$(_positive_int_or "$LOG_FETCH_DEADLINE" 180 LOG_FETCH_DEADLINE)"
	retry_delay="$(_nonnegative_int_or "$LOG_FETCH_RETRY_DELAY" 15 LOG_FETCH_RETRY_DELAY)"
	started=$SECONDS
	while :; do
		logs="$("$timeout_bin" --kill-after=10s "$cmd_timeout" \
			gh run view "${GITHUB_RUN_ID:-}" \
			--repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}" \
			--log-failed 2>/dev/null </dev/null || true)"
		if [[ -n "$logs" ]]; then
			printf '%s\n' "$logs"
			return 0
		fi
		if ((SECONDS - started + retry_delay + cmd_timeout > deadline)); then
			log_warn "Failed-job logs unavailable after ${deadline}s; classifying logs as unavailable"
			return 0
		fi
		log_info "Failed-job logs not available yet; retrying in ${retry_delay}s"
		sleep "$retry_delay"
	done
}

# Why rerun_may_be_in_flight last returned false; read by
# classify_release_failure and surfaced as the `reason` output so the filed
# issue can say what actually happened instead of always claiming that the
# retries were exhausted.
RERUN_BLOCK_REASON=""

# True when this attempt can still be superseded by an automatic re-run:
# the attempt is within the caller's re-run budget AND the failure matches an
# infra signature (the same classifier the auto-rerun safety net acts on, so
# the notifier and the re-runner can never disagree about what counts as
# transient). Anything inconclusive — malformed attempt, empty logs — returns
# false and files, because the cost asymmetry is entirely on the silent side.
rerun_may_be_in_flight() {
	local attempt="$1"
	local max_reruns="$2"
	local logs
	RERUN_BLOCK_REASON=""
	if [[ ! "$attempt" =~ ^[0-9]+$ ]]; then
		RERUN_BLOCK_REASON="attempt-invalid"
		return 1
	fi
	[[ "$max_reruns" =~ ^[0-9]+$ ]] || max_reruns=0
	if ((attempt > max_reruns)); then
		RERUN_BLOCK_REASON="budget-exhausted"
		return 1
	fi
	logs="$(fetch_infra_signature_logs)"
	if [[ -z "$logs" ]]; then
		RERUN_BLOCK_REASON="logs-unavailable"
		return 1
	fi
	if ! infra_match_signature "$logs" >/dev/null; then
		RERUN_BLOCK_REASON="no-infra-signature"
		return 1
	fi
}

# Decide what the release-mode notifier should do for this run and print the
# verdict (also written to $GITHUB_OUTPUT as `verdict=` when set, with a
# `reason=` line explaining a failure verdict):
#   success   — every reported channel succeeded or was skipped: close the issue
#   rerunning — a failed channel, but an automatic infra re-run may still be in
#               flight: stay quiet for now
#   failure   — file or update the issue; `reason` is one of channels-invalid,
#               attempt-invalid, budget-exhausted, logs-unavailable,
#               no-infra-signature
#
# Suppression is opt-in: MAX_RERUNS defaults to 0, so a caller that has not
# wired the auto-rerun reusable never gets a `rerunning` verdict on a first
# failure that nothing will actually re-run (Greptile on #973).
classify_release_failure() {
	local channels="${CHANNELS_JSON:-[]}"
	local attempt="${RUN_ATTEMPT:-}"
	local max_reruns="${MAX_RERUNS:-0}"
	local verdict
	local reason=""

	if [[ -n "$attempt" && ! "$attempt" =~ ^[0-9]+$ ]]; then
		log_warn "RUN_ATTEMPT '${attempt}' is not an integer; treating this as the final attempt"
		attempt=""
	fi
	if [[ -n "$max_reruns" && ! "$max_reruns" =~ ^[0-9]+$ ]]; then
		log_warn "MAX_RERUNS '${max_reruns}' is not an integer; defaulting to 0 (no suppression)"
		max_reruns=0
	fi

	if ! channels_shape_ok "$channels"; then
		log_warn "CHANNELS_JSON is not valid JSON or has an unrecognized shape; filing a failure so the run stays visible"
		verdict="failure"
		reason="channels-invalid"
	elif channels_all_succeeded "$channels"; then
		verdict="success"
	elif rerun_may_be_in_flight "$attempt" "$max_reruns"; then
		verdict="rerunning"
	else
		verdict="failure"
		reason="$RERUN_BLOCK_REASON"
	fi

	if [[ "$verdict" == "rerunning" ]]; then
		add_github_summary "## Release failure notifier"
		add_github_summary ""
		add_github_summary "Attempt ${attempt:-unknown} is within the automatic re-run budget (max-reruns ${max_reruns}) and the failed-job logs match a known transient-infrastructure signature, so a re-run may still be in flight. No issue filed yet; the final attempt files or closes."
	fi

	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf 'verdict=%s\n' "$verdict" >>"${GITHUB_OUTPUT}"
		printf 'reason=%s\n' "$reason" >>"${GITHUB_OUTPUT}"
	fi
	log_info "Release-failure verdict: ${verdict}${reason:+ (${reason})}"
	echo "$verdict"
}

case "${1:-}" in
write_trigger_summary)
	write_trigger_summary
	;;
notify_failure)
	notify_failure
	;;
notify_release_failure)
	notify_release_failure
	;;
close_release_failure)
	close_release_failure
	;;
classify_release_failure)
	classify_release_failure
	;;
--help | -h)
	usage
	;;
"")
	log_error "Subcommand is required"
	usage >&2
	exit 1
	;;
*)
	log_error "Unknown subcommand: $1"
	usage >&2
	exit 1
	;;
esac
