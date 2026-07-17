#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Workflow context and status helpers for notification actions
#
# Usage:
#   source "scripts/ci/lib/notify.sh"
#   notify_validate_status "failure"
#   color="$(notify_status_color "failure")"
#   run_url="$(notify_run_url)"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_NOTIFY_CONTEXT_LOADED:-}" ]] && return 0
readonly _LGTM_CI_NOTIFY_CONTEXT_LOADED=1

# Validate a notification status value.
# Usage: notify_validate_status <status>
# Returns 0 for success|failure|cancelled, 1 (with an error) otherwise.
notify_validate_status() {
	local status="${1:-}"
	case "$status" in
	success | failure | cancelled)
		return 0
		;;
	*)
		echo "notify: invalid status '${status}' (expected success, failure, or cancelled)" >&2
		return 1
		;;
	esac
}

# Hex color (with leading #) for a status. Used by Slack attachments.
# Usage: notify_status_color <status>
notify_status_color() {
	local status="${1:-}"
	case "$status" in
	success) echo "#2da44e" ;;
	failure) echo "#cf222e" ;;
	cancelled) echo "#d4a72c" ;;
	*)
		notify_validate_status "$status"
		return 1
		;;
	esac
}

# Decimal color for a status. Used by Discord embeds (integer color field).
# Usage: notify_status_color_decimal <status>
notify_status_color_decimal() {
	local status="${1:-}"
	local hex
	hex="$(notify_status_color "$status")" || return 1
	printf '%d\n' "0x${hex#\#}"
}

# Emoji marker for a status.
# Usage: notify_status_emoji <status>
notify_status_emoji() {
	local status="${1:-}"
	case "$status" in
	success) echo "✅" ;;
	failure) echo "❌" ;;
	cancelled) echo "🚫" ;;
	*)
		notify_validate_status "$status"
		return 1
		;;
	esac
}

# URL of the current workflow run, built from GitHub Actions environment.
# Usage: notify_run_url
notify_run_url() {
	local server="${GITHUB_SERVER_URL:-https://github.com}"
	local repo="${GITHUB_REPOSITORY:-}"
	local run_id="${GITHUB_RUN_ID:-}"

	if [[ -z "$repo" || -z "$run_id" ]]; then
		echo "notify: GITHUB_REPOSITORY and GITHUB_RUN_ID are required to build the run URL" >&2
		return 1
	fi
	echo "${server}/${repo}/actions/runs/${run_id}"
}

# Workflow context as a compact JSON object (repo, run_url, ref, actor,
# workflow, sha). Injected into every notification payload.
# Usage: notify_context_json
notify_context_json() {
	local run_url
	run_url="$(notify_run_url)" || return 1

	jq -cn \
		--arg repo "${GITHUB_REPOSITORY:-}" \
		--arg run_url "$run_url" \
		--arg ref "${GITHUB_REF_NAME:-${GITHUB_REF:-}}" \
		--arg actor "${GITHUB_ACTOR:-}" \
		--arg workflow "${GITHUB_WORKFLOW:-}" \
		--arg sha "${GITHUB_SHA:-}" \
		'{repo: $repo, run_url: $run_url, ref: $ref, actor: $actor,
			workflow: $workflow, sha: $sha}'
}
