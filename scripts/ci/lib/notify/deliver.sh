#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Webhook delivery with retry/backoff for notification actions
#
# Delivery uses curl only (no extra dependencies). Transient failures —
# curl transport errors (timeouts, connection resets), HTTP 429, and HTTP
# 5xx — are retried with linear backoff. Other non-2xx responses fail
# immediately (a bad webhook URL or payload will not succeed on retry).
#
# Environment overrides:
#   NOTIFY_MAX_ATTEMPTS    Delivery attempts before giving up (default: 3)
#   NOTIFY_RETRY_BACKOFF   Backoff base in seconds; sleep = base * attempt
#                          (default: 2)
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

# POST a JSON payload to a webhook with retry/backoff on transient failures.
# Usage: notify_deliver <webhook-url> <payload-json>
notify_deliver() {
	local webhook_url="${1:-}"
	local payload="${2:-}"
	local max_attempts="${NOTIFY_MAX_ATTEMPTS:-3}"
	local backoff="${NOTIFY_RETRY_BACKOFF:-2}"
	local attempt http_code curl_rc body_file

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
	for ((attempt = 1; attempt <= max_attempts; attempt++)); do
		curl_rc=0
		http_code="$(curl -sS -o "$body_file" -w '%{http_code}' \
			--connect-timeout "${NOTIFY_CONNECT_TIMEOUT:-10}" \
			--max-time "${NOTIFY_MAX_TIME:-30}" \
			-H "Content-Type: application/json" \
			-X POST --data "$payload" \
			"$webhook_url")" || curl_rc=$?

		if [[ "$curl_rc" -eq 0 && "$http_code" =~ ^2[0-9][0-9]$ ]]; then
			log_success "notify: delivered (HTTP ${http_code}, attempt ${attempt}/${max_attempts})"
			rm -f "$body_file"
			return 0
		fi

		if [[ "$curl_rc" -ne 0 ]]; then
			log_warn "notify: transport error (curl exit ${curl_rc}, attempt ${attempt}/${max_attempts})"
		elif _notify_transient_http_code "$http_code"; then
			log_warn "notify: transient HTTP ${http_code} (attempt ${attempt}/${max_attempts})"
		else
			log_error "notify: webhook rejected the request (HTTP ${http_code}): $(cat "$body_file")"
			rm -f "$body_file"
			return 1
		fi

		if ((attempt < max_attempts)); then
			local delay=$((backoff * attempt))
			log_info "notify: retrying in ${delay}s..."
			sleep "$delay"
		fi
	done

	rm -f "$body_file"
	log_error "notify: delivery failed after ${max_attempts} attempts"
	return 1
}
