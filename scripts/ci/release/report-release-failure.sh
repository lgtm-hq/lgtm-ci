#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Surface reusable release workflow failures via step summary and issues
#
# Subcommands:
#   write_trigger_summary — append release trigger context to $GITHUB_STEP_SUMMARY
#   notify_failure        — create or comment on a deduplicated GitHub issue
#
# Required environment variables (notify_failure):
#   GH_TOKEN            — GitHub token with issues: write
#   GITHUB_REPOSITORY   — Target repository (owner/name)
#   RELEASE_WORKFLOW_KEY — Stable workflow key for marker namespacing
#                          (e.g. release-version-pr, release-auto-tag)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"
# shellcheck source=../lib/github/summary.sh
source "$SCRIPT_DIR/../lib/github/summary.sh"

usage() {
	cat <<'EOF'
Usage: report-release-failure.sh <subcommand>

Subcommands:
  write_trigger_summary  Write release trigger context to $GITHUB_STEP_SUMMARY
  notify_failure         Create or update a deduplicated GitHub issue on target branch
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
	echo "${RELEASE_WORKFLOW_KEY:?RELEASE_WORKFLOW_KEY is required}"
}

marker_key() {
	local branch
	branch="$(release_branch)"
	echo "release-automation-failure:$(workflow_key):${branch}"
}

issue_marker() {
	echo "<!-- $(marker_key) -->"
}

failure_issue_title() {
	local target_branch="${1:?target_branch is required}"
	printf 'fix(release): release automation failed on %s (%s)' \
		"$target_branch" "$(workflow_key)"
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
	local heading="## Release Automation Context"

	if [[ -z "${GITHUB_STEP_SUMMARY:-}" ]]; then
		log_error "GITHUB_STEP_SUMMARY is required"
		exit 1
	fi

	branch="$(release_branch)"
	sha="$(release_sha)"
	current_run_url="$(run_url)"
	upstream_url="$(upstream_run_url)"

	if [[ "${PRIMARY_JOB_FAILED:-false}" == "true" ]]; then
		heading="## Release Automation Failure"
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
	local branch
	local sha
	local current_run_url
	local upstream_url
	local marker
	local tracking_key
	branch="$(release_branch)"
	sha="$(release_sha)"
	current_run_url="$(run_url)"
	upstream_url="$(upstream_run_url)"
	marker="$(issue_marker)"
	tracking_key="$(marker_key)"

	cat <<EOF
$marker

## Summary

Release automation failed on \`${target_branch}\`. This issue keeps post-merge release failures visible outside the Actions history.

## Failure Context

- **Workflow:** ${GITHUB_WORKFLOW:-unknown}
- **Workflow key:** $(workflow_key)
- **Event:** ${GITHUB_EVENT_NAME:-unknown}
- **Branch:** ${branch}
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
		log_error "Could not search for existing release failure issues: $(cat "$gh_stderr")"
		rm -f "$gh_stderr"
		exit 1
	fi
	rm -f "$gh_stderr"

	issue_number="$search_output"
	if [[ "$issue_number" =~ ^[0-9]+$ ]]; then
		echo "$issue_number"
	fi
}

find_existing_issue() {
	local target_branch="${1:?target_branch is required}"
	local title
	local search_key
	local issue_number

	title="$(failure_issue_title "$target_branch")"
	issue_number="$(lookup_open_issue "\"${title}\" in:title")"
	if [[ -n "$issue_number" ]]; then
		echo "$issue_number"
		return
	fi

	# Visible tracking keys are indexed; HTML comment markers may not be.
	search_key="$(marker_key)"
	issue_number="$(lookup_open_issue "\"${search_key}\"")"
	if [[ -n "$issue_number" ]]; then
		echo "$issue_number"
	fi
}

collect_existing_issue_label_args() {
	local -n _label_args=$1
	local default_labels="${FAILURE_ISSUE_LABELS:-bug,ci,release,automation,infrastructure}"
	local label
	local repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

	_label_args=()
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

	branch="$(release_branch)"
	target_branch="$(resolve_target_branch)"

	if [[ "$branch" != "$target_branch" ]]; then
		log_info "Release failure notification skipped for branch '$branch' (target: '$target_branch')"
		exit 0
	fi

	body_file="$(mktemp)"
	trap 'rm -f "$body_file"' EXIT
	render_failure_body "$target_branch" >"$body_file"

	existing_issue="$(find_existing_issue "$target_branch")"
	if [[ -n "$existing_issue" ]]; then
		comment_on_failure_issue "$existing_issue" "$body_file"
	else
		# Brief pause reduces duplicate issues when concurrent runs fail together.
		sleep 2
		existing_issue="$(find_existing_issue "$target_branch")"
		if [[ -n "$existing_issue" ]]; then
			comment_on_failure_issue "$existing_issue" "$body_file"
		elif create_failure_issue "$body_file" "$target_branch"; then
			:
		else
			existing_issue="$(find_existing_issue "$target_branch")"
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

case "${1:-}" in
write_trigger_summary)
	write_trigger_summary
	;;
notify_failure)
	notify_failure
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
