#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Send a Slack notification via incoming webhook (notify-slack action)
#
# Builds a Block Kit payload with a status-based color and auto-injected
# workflow context (repository, run URL, ref, actor), then POSTs it with
# curl, retrying transient failures with backoff. In dry-run mode the
# payload is printed to stdout instead of being delivered.
#
# Environment variables:
#   STATUS: success | failure | cancelled (required)
#   TITLE: Notification title (required)
#   WEBHOOK_URL: Slack incoming webhook URL (required unless DRY_RUN=true)
#   MESSAGE: Notification body, Slack mrkdwn (optional)
#   FIELDS: Extra fields as newline KEY=VALUE (or KEY: VALUE) list (optional)
#   DRY_RUN: Print the payload instead of POSTing (default: false)
set -euo pipefail

: "${STATUS:?STATUS is required}"
: "${TITLE:?TITLE is required}"
: "${MESSAGE:=}"
: "${FIELDS:=}"
: "${DRY_RUN:=false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
source "$SCRIPT_DIR/../lib/actions.sh"
source "$SCRIPT_DIR/../lib/notify.sh"

notify_validate_status "$STATUS" || die "notify-slack: invalid status"

fields_json="$(notify_fields_json "$FIELDS")" || die "notify-slack: invalid FIELDS input"
payload="$(notify_slack_payload "$STATUS" "$TITLE" "$MESSAGE" "$fields_json")" ||
	die "notify-slack: failed to build payload"

if [[ "$DRY_RUN" == "true" ]]; then
	log_info "notify-slack: dry-run enabled; printing payload instead of delivering"
	echo "$payload"
	set_github_output "delivered" "false"
	exit 0
fi

: "${WEBHOOK_URL:?WEBHOOK_URL is required}"

if notify_deliver "$WEBHOOK_URL" "$payload"; then
	set_github_output "delivered" "true"
	log_success "notify-slack: notification sent"
else
	set_github_output "delivered" "false"
	die "notify-slack: delivery failed"
fi
