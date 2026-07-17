#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Webhook delivery with retry/backoff for notification actions
#
# Delivery uses curl only (no extra dependencies). Transient failures —
# curl transport errors (timeouts, connection resets), HTTP 429, and HTTP
# 5xx — are retried with linear backoff. On HTTP 429 the Retry-After
# header (or a Discord JSON `retry_after` body) is honored when present,
# capped at NOTIFY_RETRY_MAX_DELAY. Other non-2xx responses fail
# immediately (a bad webhook URL or payload will not succeed on retry).
#
# The webhook URL is passed to curl via a config file on stdin (-K -),
# never as a CLI argument, so it does not leak through /proc cmdline on
# shared runners.
#
# Environment overrides:
#   NOTIFY_MAX_ATTEMPTS    Delivery attempts before giving up (default: 3)
#   NOTIFY_RETRY_BACKOFF   Backoff base in seconds; sleep = base * attempt
#                          (default: 2)
#   NOTIFY_RETRY_MAX_DELAY Cap for any retry sleep in seconds (default: 30)
#   NOTIFY_CONNECT_TIMEOUT curl --connect-timeout seconds (default: 10)
#   NOTIFY_MAX_TIME        curl --max-time seconds (default: 30)
#
# Usage:
#   source "scripts/ci/lib/notify.sh"
#   notify_deliver "$WEBHOOK_URL" "$payload"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_NOTIFY_DELIVER_LOADED:-}" ]] && return 0
readonly _LGTM_CI_NOTIFY_DELIVER_LOADED=1

# True when an HTTP status code is worth retrying (429 or 5xx).
# Usage: _notify_transient_http_code <code>
_notify_transient_http_code() {
	local code="${1:-}"
	[[ "$code" == "429" || "$code" =~ ^5[0-9][0-9]$ ]]
}

# Resolve the sleep before the next attempt after an HTTP 429: prefer the
# Retry-After response header (integer seconds), then a Discord-style JSON
# `retry_after` body value (seconds, rounded up), then the fallback backoff.
# The result is capped at NOTIFY_RETRY_MAX_DELAY seconds.
# Usage: _notify_retry_delay <headers-file> <body-file> <fallback-seconds>
_notify_retry_delay() {
	local headers_file="${1:-}"
	local body_file="${2:-}"
	local fallback="${3:-2}"
	local cap="${NOTIFY_RETRY_MAX_DELAY:-30}"
	local delay="" value

	if [[ -s "$headers_file" ]]; then
		value="$(awk -F': *' 'tolower($1) == "retry-after" {v = $2} END {print v}' \
			"$headers_file" | tr -d '\r')"
		if [[ "$value" =~ ^[0-9]+$ ]]; then
			delay="$value"
		fi
	fi

	if [[ -z "$delay" && -s "$body_file" ]]; then
		value="$(jq -r 'try (.retry_after // empty)' "$body_file" 2>/dev/null || true)"
		if [[ "$value" =~ ^([0-9]+)(\.([0-9]+))?$ ]]; then
			delay="${BASH_REMATCH[1]}"
			if [[ "${BASH_REMATCH[3]:-}" =~ [1-9] ]]; then
				delay=$((delay + 1))
			fi
		fi
	fi

	[[ -z "$delay" ]] && delay="$fallback"
	((delay > cap)) && delay="$cap"
	echo "$delay"
}

# POST a JSON payload to a webhook with retry/backoff on transient failures.
# Usage: notify_deliver <webhook-url> <payload-json>
notify_deliver() {
	local webhook_url="${1:-}"
	local payload="${2:-}"
	local max_attempts="${NOTIFY_MAX_ATTEMPTS:-3}"
	local backoff="${NOTIFY_RETRY_BACKOFF:-2}"
	local attempt http_code curl_rc body_file headers_file escaped_url delay

	if [[ -z "$webhook_url" ]]; then
		log_error "notify: webhook URL must not be empty"
		return 1
	fi
	if [[ "$webhook_url" != https://* ]]; then
		log_error "notify: webhook URL must use https:// (got: ${webhook_url%%:*}://...)"
		return 1
	fi
	if [[ -z "$payload" ]]; then
		log_error "notify: payload must not be empty"
		return 1
	fi

	body_file="$(mktemp)"
	headers_file="$(mktemp)"
	trap 'rm -f "$body_file" "$headers_file"; trap - RETURN' RETURN

	# Escape for a double-quoted curl config value (backslash, then quote).
	escaped_url="${webhook_url//\\/\\\\}"
	escaped_url="${escaped_url//\"/\\\"}"

	for ((attempt = 1; attempt <= max_attempts; attempt++)); do
		curl_rc=0
		: >"$headers_file"
		: >"$body_file"
		# The URL travels via a curl config file on stdin (-K -), not argv,
		# so it is not visible in the process table on shared runners.
		http_code="$(curl -sS -o "$body_file" -D "$headers_file" -w '%{http_code}' \
			--connect-timeout "${NOTIFY_CONNECT_TIMEOUT:-10}" \
			--max-time "${NOTIFY_MAX_TIME:-30}" \
			-H "Content-Type: application/json" \
			-X POST --data-raw "$payload" \
			-K - <<<"url = \"${escaped_url}\"")" || curl_rc=$?

		if [[ "$curl_rc" -eq 0 && "$http_code" =~ ^2[0-9][0-9]$ ]]; then
			log_success "notify: delivered (HTTP ${http_code}, attempt ${attempt}/${max_attempts})"
			return 0
		fi

		if [[ "$curl_rc" -ne 0 ]]; then
			log_warn "notify: transport error (curl exit ${curl_rc}, attempt ${attempt}/${max_attempts})"
		elif _notify_transient_http_code "$http_code"; then
			log_warn "notify: transient HTTP ${http_code} (attempt ${attempt}/${max_attempts})"
		else
			log_error "notify: webhook rejected the request (HTTP ${http_code}): $(cat "$body_file")"
			return 1
		fi

		if ((attempt < max_attempts)); then
			delay=$((backoff * attempt))
			if [[ "$http_code" == "429" && "$curl_rc" -eq 0 ]]; then
				delay="$(_notify_retry_delay "$headers_file" "$body_file" "$delay")"
			fi
			log_info "notify: retrying in ${delay}s..."
			sleep "$delay"
		fi
	done

	log_error "notify: delivery failed after ${max_attempts} attempts"
	return 1
}
