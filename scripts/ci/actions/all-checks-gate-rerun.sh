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
gate_ids="$(jq -r --arg sha "$sha" '.[] | select(.head_sha == $sha and .name == "All Checks Gate" and .path == ".github/workflows/all-checks-gate.yml") | .id | select(type == "number")' <<<"$runs")"

# Refresh one gate: 0 when refreshed or not eligible, 1 on failure. It runs
# inside an `if`, where set -e is suspended, so every step checks itself.
refresh_gate() {
	local gate_id="$1" gate attempt fresh verified=false
	# Re-read immediately before writing, rather than trusting the listing.
	if ! gate="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${gate_id}")"; then
		echo "Could not read gate ${gate_id}" >&2
		return 1
	fi
	if ! jq -e --arg sha "$sha" --argjson trigger "$trigger" '
		.head_sha == $sha and .name == "All Checks Gate"
		and .path == ".github/workflows/all-checks-gate.yml"
		and .status == "completed" and .conclusion == "failure"
		and (.updated_at | fromdateiso8601) < ($trigger.updated_at | fromdateiso8601)
		' <<<"$gate" >/dev/null; then
		return 0
	fi
	if ! attempt="$(jq -er '.run_attempt | select(type == "number" and . >= 1)' <<<"$gate")"; then
		echo "Gate ${gate_id} has no valid run_attempt" >&2
		return 1
	fi
	# No automatic POST retry: an ambiguous response may already have applied.
	if ! gh api --method POST "repos/${GITHUB_REPOSITORY}/actions/runs/${gate_id}/rerun-failed-jobs"; then
		echo "Rerun request for gate ${gate_id} failed; not retrying" >&2
		return 1
	fi
	for _ in 1 2 3 4 5; do
		# Only the read is repeated; a failed read counts as not yet verified.
		if fresh="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${gate_id}")" &&
			jq -e --argjson attempt "$attempt" '.run_attempt > $attempt or (.status != "completed" and (.status == "queued" or .status == "in_progress" or .status == "requested" or .status == "pending" or .status == "waiting"))' <<<"$fresh" >/dev/null; then
			verified=true
			break
		fi
		sleep 2
	done
	if [[ "$verified" != true ]]; then
		echo "Could not verify rerun of gate ${gate_id}" >&2
		return 1
	fi
	echo "Re-ran gate ${gate_id} attempt ${attempt}"
}

# Gates are independent: one failure must not leave the others unrefreshed.
failed=()
while read -r gate_id; do
	[[ -n "$gate_id" ]] || continue
	if ! refresh_gate "$gate_id"; then
		failed+=("$gate_id")
	fi
done <<<"$gate_ids"
if ((${#failed[@]} > 0)); then
	echo "Failed to refresh gate(s): ${failed[*]}" >&2
	exit 1
fi
