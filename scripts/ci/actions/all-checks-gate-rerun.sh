#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Refresh failed gates after a successful later workflow attempt.
# Run only trusted default-branch code; never check out the triggering head.
# The caller must serialize handlers per head SHA, without cancelling them.
set -euo pipefail
exec </dev/null

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH is required}"

trigger="$(jq -ce '.workflow_run' "$GITHUB_EVENT_PATH")"
if ! jq -e '.status == "completed" and .conclusion == "success" and .run_attempt > 1 and .name != "All Checks Gate"' <<<"$trigger" >/dev/null; then
	echo 'Not a successful later check attempt; nothing to refresh'
	exit 0
fi
sha="$(jq -r .head_sha <<<"$trigger")"
id="$(jq -r .id <<<"$trigger")"
[[ "$sha" =~ ^[0-9a-f]{40}$ && "$id" =~ ^[0-9]+$ ]] || exit 1

# Reject stale deliveries: the triggering run may have been retried again.
current="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${id}")"
if ! jq -e --argjson event "$trigger" '.head_sha == $event.head_sha and .run_attempt == $event.run_attempt and .status == "completed" and .conclusion == "success"' <<<"$current" >/dev/null; then
	echo 'Trigger no longer matches the successful attempt; skipping'
	exit 0
fi

# Paginate all gate runs, including separate PR/event lanes on the same SHA.
runs="$(gh api --paginate "repos/${GITHUB_REPOSITORY}/actions/workflows/all-checks-gate.yml/runs?head_sha=${sha}&per_page=100" --jq '.workflow_runs[]' | jq -s 'unique_by(.id)')"
while read -r gate_id; do
	# Re-read immediately before writing, rather than trusting the listing.
	gate="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${gate_id}")"
	if ! jq -e --arg sha "$sha" --argjson trigger "$trigger" '
		.head_sha == $sha and .name == "All Checks Gate"
		and .path == ".github/workflows/all-checks-gate.yml"
		and .status == "completed" and .conclusion == "failure"
		and (.updated_at | fromdateiso8601) < ($trigger.updated_at | fromdateiso8601)
		' <<<"$gate" >/dev/null; then
		continue
	fi
	attempt="$(jq -er '.run_attempt | select(type == "number" and . >= 1)' <<<"$gate")"
	# No automatic POST retry: an ambiguous response may already have applied.
	gh api --method POST "repos/${GITHUB_REPOSITORY}/actions/runs/${gate_id}/rerun-failed-jobs"
	verified=false
	for _ in 1 2 3 4 5; do
		fresh="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${gate_id}")"
		if jq -e --argjson attempt "$attempt" '.run_attempt > $attempt or (.status != "completed" and (.status == "queued" or .status == "in_progress" or .status == "requested" or .status == "pending" or .status == "waiting"))' <<<"$fresh" >/dev/null; then
			verified=true
			break
		fi
		sleep 2
	done
	if [[ "$verified" != true ]]; then
		echo "Could not verify rerun of gate ${gate_id}" >&2
		exit 1
	fi
	echo "Re-ran gate ${gate_id} attempt ${attempt}"
done < <(jq -r --arg sha "$sha" '.[] | select(.head_sha == $sha and .name == "All Checks Gate" and .path == ".github/workflows/all-checks-gate.yml") | .id | select(type == "number")' <<<"$runs")
