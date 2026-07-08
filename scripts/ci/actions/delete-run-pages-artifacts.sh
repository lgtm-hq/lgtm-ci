#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Delete existing same-run Pages artifacts before a fresh upload so
#          `gh run rerun --failed` self-heals the deploy-pages deadlock (#415).
#
# When a Pages deploy fails transiently and the failed job is re-run, the rerun
# re-executes the artifact upload step and produces a SECOND `github-pages`
# artifact on the same run. actions/deploy-pages then hard-fails with
# "Multiple artifacts named ... Artifact count is 2", and every subsequent
# rerun re-uploads again, so the run can never self-heal. actions/upload-pages-
# artifact (pinned v5.0.0) has no overwrite semantics, so we delete any
# pre-existing artifact of the same name on the CURRENT run first, guaranteeing
# exactly one artifact exists at deploy time.
#
# Environment variables:
#   ARTIFACT_NAME     - Name of the Pages artifact (default: github-pages)
#   GITHUB_REPOSITORY - owner/repo (provided by GitHub Actions)
#   GITHUB_RUN_ID     - Current workflow run id (provided by GitHub Actions)
#   GH_TOKEN          - Token with actions:write scope
#   DRY_RUN           - Log intended deletions without performing them (default: false)

set -euo pipefail

: "${ARTIFACT_NAME:=github-pages}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${DRY_RUN:=false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

# List artifacts scoped to the current run and select ids matching the target
# name. Paginate defensively in case a run carries many artifacts.
fetch_matching_artifact_ids() {
	gh api --paginate \
		"/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/artifacts" |
		jq -r --arg name "$ARTIFACT_NAME" \
			'.artifacts[]? | select(.name == $name) | .id'
}

delete_artifact() {
	local artifact_id="$1"
	gh api --method DELETE \
		"/repos/${GITHUB_REPOSITORY}/actions/artifacts/${artifact_id}"
}

main() {
	local ids
	if ! ids="$(fetch_matching_artifact_ids)"; then
		die "Failed to list artifacts for run ${GITHUB_RUN_ID}"
	fi

	if [[ -z "$ids" ]]; then
		log_info "No existing '${ARTIFACT_NAME}' artifact on run ${GITHUB_RUN_ID}; nothing to delete"
		return 0
	fi

	local deleted=0 failed=0 id
	while IFS= read -r id; do
		[[ -z "$id" ]] && continue

		if [[ "$DRY_RUN" == "true" ]]; then
			log_info "[dry-run] Would delete stale '${ARTIFACT_NAME}' artifact ${id}"
			deleted=$((deleted + 1))
			continue
		fi

		if delete_artifact "$id"; then
			log_success "Deleted stale '${ARTIFACT_NAME}' artifact ${id}"
			deleted=$((deleted + 1))
		else
			log_error "Failed to delete stale '${ARTIFACT_NAME}' artifact ${id}"
			failed=$((failed + 1))
		fi
	done <<<"$ids"

	log_info "Pages artifact cleanup for run ${GITHUB_RUN_ID}: ${deleted} deleted, ${failed} failed"

	if [[ "$failed" -gt 0 ]]; then
		die "Failed to delete ${failed} stale '${ARTIFACT_NAME}' artifact(s)"
	fi
}

main "$@"
