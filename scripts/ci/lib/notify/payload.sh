#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Build Slack (Block Kit) and Discord (embed) notification payloads
#
# Payloads are assembled with jq and always include workflow context
# (repository, run URL, ref, actor) resolved from the GitHub Actions
# environment by notify/context.sh.
#
# Usage:
#   source "scripts/ci/lib/notify.sh"
#   payload="$(notify_slack_payload "failure" "Build Failed" "msg" "$fields_json")"
#   payload="$(notify_discord_payload "success" "Deployed" "" "[]")"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_NOTIFY_PAYLOAD_LOADED:-}" ]] && return 0
readonly _LGTM_CI_NOTIFY_PAYLOAD_LOADED=1

# Build a Slack Block Kit payload (attachment with status color + blocks).
# Usage: notify_slack_payload <status> <title> <message> <fields-json>
notify_slack_payload() {
	local status="${1:-}"
	local title="${2:-}"
	local message="${3:-}"
	local fields_json="${4:-[]}"
	local color emoji context

	notify_validate_status "$status" || return 1
	color="$(notify_status_color "$status")" || return 1
	emoji="$(notify_status_emoji "$status")" || return 1
	context="$(notify_context_json)" || return 1

	jq -cn \
		--arg color "$color" \
		--arg title "${emoji} ${title}" \
		--arg message "$message" \
		--argjson fields "$fields_json" \
		--argjson ctx "$context" \
		'{
			attachments: [
				{
					color: $color,
					blocks: (
						[{type: "header",
							text: {type: "plain_text", text: $title, emoji: true}}]
						+ (if $message != ""
							then [{type: "section",
								text: {type: "mrkdwn", text: $message}}]
							else [] end)
						+ (if ($fields | length) > 0
							then [{type: "section",
								fields: [$fields[]
									| {type: "mrkdwn",
										text: ("*" + .name + "*\n" + .value)}]}]
							else [] end)
						+ [{type: "context",
							elements: [{type: "mrkdwn",
								text: ("<" + $ctx.run_url + "|" + $ctx.repo + ">"
									+ " • `" + $ctx.ref + "`"
									+ " • by " + $ctx.actor)}]}]
					)
				}
			]
		}'
}

# Build a Discord embed payload with status color and context fields.
# Usage: notify_discord_payload <status> <title> <message> <fields-json>
notify_discord_payload() {
	local status="${1:-}"
	local title="${2:-}"
	local message="${3:-}"
	local fields_json="${4:-[]}"
	local color emoji context

	notify_validate_status "$status" || return 1
	color="$(notify_status_color_decimal "$status")" || return 1
	emoji="$(notify_status_emoji "$status")" || return 1
	context="$(notify_context_json)" || return 1

	jq -cn \
		--argjson color "$color" \
		--arg title "${emoji} ${title}" \
		--arg message "$message" \
		--argjson fields "$fields_json" \
		--argjson ctx "$context" \
		'{
			embeds: [
				({
					title: $title,
					url: $ctx.run_url,
					color: $color,
					fields: (
						[$fields[] | {name, value, inline: true}]
						+ [
							{name: "Repository", value: $ctx.repo, inline: true},
							{name: "Ref", value: $ctx.ref, inline: true},
							{name: "Actor", value: $ctx.actor, inline: true}
						]
					)
				}
				+ (if $message != "" then {description: $message} else {} end))
			]
		}'
}
