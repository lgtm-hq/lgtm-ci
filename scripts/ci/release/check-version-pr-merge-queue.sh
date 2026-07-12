#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Detect whether a version PR is already in the merge queue
#
# peter-evans/create-pull-request cannot update a branch whose PR sits in a
# merge queue ("Branches queued for merging cannot be updated"). Detect that
# state before the update and emit a skip signal so the workflow stays green.
#
# Why skip (not dequeue/requeue or per-run branch names):
# - Dequeue/requeue races auto-merge and can drop a ready release mid-queue.
# - Per-run branch names orphan prior version PRs and break 1 PR = 1 release.
# - Skipping is idempotent: the queued PR already carries the release bump.
#
# Env (optional unless noted):
#   GH_TOKEN     - required for gh/api auth
#   PR_NUMBER    - known version PR number (preferred when set)
#   BRANCH       - head branch name to resolve a PR (e.g. release/v1.2.3)
#   REPO         - owner/name (defaults to github.repository / gh repo resolve)
#
# Outputs (GITHUB_OUTPUT + stdout):
#   queued              - true | false | unknown
#   skip-branch-update  - true when update must be skipped
#   pr-number           - resolved PR number (may be empty)
#   reason              - short machine-readable reason

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"

PR_TITLE_PREFIX="${PR_TITLE_PREFIX:-chore(release): version}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
PR_NUMBER="${PR_NUMBER:-}"
BRANCH="${BRANCH:-}"

emit() {
	local queued="$1"
	local skip="$2"
	local number="$3"
	local reason="$4"

	set_github_output "queued" "$queued"
	set_github_output "skip-branch-update" "$skip"
	set_github_output "pr-number" "$number"
	set_github_output "reason" "$reason"
	echo "queued=${queued}"
	echo "skip-branch-update=${skip}"
	echo "pr-number=${number}"
	echo "reason=${reason}"
}

if [[ -z "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
	log_warn "GH_TOKEN unset; cannot query merge queue (skipping branch update)"
	emit "unknown" "true" "" "missing-token"
	exit 0
fi

if [[ -z "$REPO" ]]; then
	REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
fi

if [[ -z "$REPO" || "$REPO" != */* ]]; then
	log_warn "Unable to resolve repository owner/name; skipping branch update"
	emit "unknown" "true" "" "missing-repo"
	exit 0
fi

OWNER="${REPO%%/*}"
NAME="${REPO#*/}"

resolve_pr_number() {
	if [[ -n "$PR_NUMBER" ]]; then
		echo "$PR_NUMBER"
		return 0
	fi

	local found=""
	if [[ -n "$BRANCH" ]]; then
		found="$(
			gh pr list --repo "$REPO" --state open --head "$BRANCH" \
				--json number --jq '.[0].number // empty' 2>/dev/null || true
		)"
		if [[ -n "$found" ]]; then
			echo "$found"
			return 0
		fi
	fi

	found="$(
		gh pr list --repo "$REPO" --state open \
			--search "in:title ${PR_TITLE_PREFIX}" \
			--json number --jq '.[0].number // empty' 2>/dev/null || true
	)"
	echo "$found"
}

PR_NUMBER="$(resolve_pr_number || true)"

if [[ -z "$PR_NUMBER" ]]; then
	log_info "No open version PR found for merge-queue check"
	emit "false" "false" "" "no-pr"
	exit 0
fi

# GraphQL variable names ($owner/$name/$number) are not shell expansions.
# shellcheck disable=SC2016
QUERY='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){number mergeQueueEntry{position state}}}}'

RESPONSE="$(
	gh api graphql \
		-F owner="$OWNER" \
		-F name="$NAME" \
		-F number="$PR_NUMBER" \
		-f query="$QUERY" 2>/dev/null || true
)"

if [[ -z "$RESPONSE" ]]; then
	log_warn "Merge-queue GraphQL query failed for PR #${PR_NUMBER}; skipping branch update"
	emit "unknown" "true" "$PR_NUMBER" "api-error"
	exit 0
fi

if echo "$RESPONSE" | jq -e '.errors? | select(length > 0)' >/dev/null 2>&1; then
	log_warn "Merge-queue GraphQL returned errors for PR #${PR_NUMBER}; skipping branch update"
	emit "unknown" "true" "$PR_NUMBER" "api-error"
	exit 0
fi

ENTRY="$(echo "$RESPONSE" | jq -c '.data.repository.pullRequest.mergeQueueEntry // null' 2>/dev/null || echo "null")"

if [[ "$ENTRY" != "null" && -n "$ENTRY" ]]; then
	log_info "Version PR #${PR_NUMBER} is in the merge queue; skipping branch update"
	emit "true" "true" "$PR_NUMBER" "queued"
	exit 0
fi

log_info "Version PR #${PR_NUMBER} is not in the merge queue"
emit "false" "false" "$PR_NUMBER" "not-queued"
