#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Parse the notification actions' `fields` input into JSON
#
# The `fields` input is a newline-separated KEY=VALUE list (a simple YAML
# mapping with `KEY: VALUE` lines, optionally as `- ` list items, is also
# accepted). Blank lines and `#` comments are ignored.
#
# Usage:
#   source "scripts/ci/lib/notify.sh"
#   fields_json="$(notify_fields_json "$FIELDS")"
#   # => [{"name":"Environment","value":"production"}, ...]

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_NOTIFY_FIELDS_LOADED:-}" ]] && return 0
readonly _LGTM_CI_NOTIFY_FIELDS_LOADED=1

# Parse raw fields text into a JSON array of {name, value} objects.
# Usage: notify_fields_json <raw-fields-text>
notify_fields_json() {
	local raw="${1:-}"
	local line trimmed name value
	local json='[]'

	if [[ -z "${raw//[[:space:]]/}" ]]; then
		echo '[]'
		return 0
	fi

	while IFS= read -r line || [[ -n "$line" ]]; do
		trimmed="${line#"${line%%[![:space:]]*}"}"
		trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
		[[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
		# Allow YAML list items: "- KEY=VALUE"
		trimmed="${trimmed#- }"

		if [[ "$trimmed" == *=* ]]; then
			name="${trimmed%%=*}"
			value="${trimmed#*=}"
		elif [[ "$trimmed" == *:* ]]; then
			name="${trimmed%%:*}"
			value="${trimmed#*:}"
		else
			echo "notify: invalid fields line (expected KEY=VALUE or KEY: VALUE): ${trimmed}" >&2
			return 1
		fi

		# Trim whitespace around name and value
		name="${name#"${name%%[![:space:]]*}"}"
		name="${name%"${name##*[![:space:]]}"}"
		value="${value#"${value%%[![:space:]]*}"}"
		value="${value%"${value##*[![:space:]]}"}"

		if [[ -z "$name" ]]; then
			echo "notify: invalid fields line (empty key): ${trimmed}" >&2
			return 1
		fi

		json="$(jq -cn --argjson acc "$json" --arg name "$name" --arg value "$value" \
			'$acc + [{name: $name, value: $value}]')" || return 1
	done <<<"$raw"

	echo "$json"
}
