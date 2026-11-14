#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Download utilities for CI scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/download.sh"
#   download_with_retries "https://example.com/file" "./file"
#
# Security model:
#   All downloads enforce a TLS floor (HTTPS-only, TLS >= 1.2) and reject
#   protocol downgrades in redirects. Two opt-in, defense-in-depth knobs are
#   supported via environment variables (defaults unchanged when unset):
#     LGTM_CI_CA_BUNDLE      Path to a custom CA bundle (curl --cacert)
#     LGTM_CI_PINNED_PUBKEY  Pinned public key (curl --pinnedpubkey), either
#                            a "sha256//BASE64" hash or a path to a PEM/DER
#                            public key file
#   For explicit caller-supplied pins use download_with_pinning, which fails
#   closed when no pin is available. Pins are the caller's responsibility to
#   rotate; this library deliberately does not ship a hard-coded pin registry.

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_NETWORK_DOWNLOAD_LOADED:-}" ]] && return 0
readonly _LGTM_CI_NETWORK_DOWNLOAD_LOADED=1

# Source logging if available
_LGTM_CI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")/.." && pwd)"
if [[ -f "$_LGTM_CI_LIB_DIR/log.sh" ]]; then
	# shellcheck source=../log.sh
	source "$_LGTM_CI_LIB_DIR/log.sh"
else
	log_verbose() { [[ "${VERBOSE:-}" == "1" ]] && echo "[VERBOSE] $*" >&2 || true; }
	log_warn() { echo "[WARN] $*" >&2; }
	log_error() { echo "[ERROR] $*" >&2; }
fi

# =============================================================================
# Download helpers
# =============================================================================

# Build hardened curl arguments into the global array _LGTM_CI_CURL_ARGS.
# Enforces HTTPS-only + TLS >= 1.2, and appends opt-in CA bundle / pinned
# public key options from the environment (see security model above).
# Usage: _lgtm_ci_build_curl_args [max_time]
# Returns 1 (fail closed) if LGTM_CI_CA_BUNDLE is set but not a readable file.
_lgtm_ci_build_curl_args() {
	local max_time="${1:-300}"
	_LGTM_CI_CURL_ARGS=(
		-fsSL
		--proto '=https'
		--tlsv1.2
		--connect-timeout 30
		--max-time "$max_time"
	)
	if [[ -n "${LGTM_CI_CA_BUNDLE:-}" ]]; then
		if [[ ! -r "$LGTM_CI_CA_BUNDLE" ]]; then
			log_error "CA bundle not readable: $LGTM_CI_CA_BUNDLE"
			return 1
		fi
		_LGTM_CI_CURL_ARGS+=(--cacert "$LGTM_CI_CA_BUNDLE")
	fi
	if [[ -n "${LGTM_CI_PINNED_PUBKEY:-}" ]]; then
		_LGTM_CI_CURL_ARGS+=(--pinnedpubkey "$LGTM_CI_PINNED_PUBKEY")
	fi
	return 0
}

# Print the header lines of the FINAL response in a curl --dump-header file.
# The dump holds one block per response (a proxy CONNECT reply, 1xx interim
# responses, every redirect hop, then the final response); each block starts
# with an "HTTP/<version> <status>" line, so everything before the last such
# line is discarded. Carriage returns are stripped. When the last block is an
# interim (1xx) or redirect (3xx) response, the terminal response never
# arrived (for example the redirect target failed to resolve), so nothing is
# printed: a hop's Retry-After must not steer the retry.
# Usage: _lgtm_ci_download_final_headers headers_file
_lgtm_ci_download_final_headers() {
	local headers="${1:-}"
	[[ -n "$headers" && -f "$headers" ]] || return 0
	tr -d '\r' <"$headers" |
		awk 'toupper($0) ~ /^HTTP\/[0-9.]+ [0-9][0-9][0-9]/ { buf = ""; st = $2 }
			{ buf = buf $0 "\n" }
			END { if (st !~ /^[13]/) printf "%s", buf }'
}

# Classify a failed download attempt.
# Usage: _lgtm_ci_download_retryable curl_exit http_code [headers_file]
# Returns 0 when the failure is transient and worth retrying, 1 otherwise.
#   An HTTP error status (4xx/5xx) decides: 408, 429 and 5xx are retried, as
#   is a 403 whose final response carries rate-limit headers (Retry-After, or
#   x-ratelimit-remaining: 0); any other 4xx (404, plain 403, ...) is not.
#   Otherwise (no status, or a 2xx/3xx whose body then failed) the curl exit
#   code decides. Retryable transport errors: DNS, connect, weird reply,
#   HTTP/2 framing, partial transfer, timeout, TLS connect, empty reply,
#   send/receive failure, HTTP/2 stream reset (exit codes 5, 6, 7, 8, 16, 18,
#   28, 35, 52, 55, 56, 92), and exit 22 when no HTTP status could be read.
#   TLS / certificate / pin failures (51, 58, 59, 60, 77, 80, 83, 90, 91) and
#   every other curl error are not retried, so a missing release or a pin
#   mismatch fails on the first attempt.
_lgtm_ci_download_retryable() {
	local rc="$1" code="$2" headers="${3:-}"
	if [[ "$code" =~ ^[45][0-9][0-9]$ ]]; then
		case "$code" in
		408 | 429 | 5??) return 0 ;;
		403)
			# No grep -q: it exits at the first match, the producer then dies
			# of SIGPIPE on a large header block and pipefail reports 141.
			_lgtm_ci_download_final_headers "$headers" |
				grep -iE '^(retry-after:|x-ratelimit-remaining:[[:space:]]*0[[:space:]]*$)' \
					>/dev/null
			return
			;;
		*) return 1 ;;
		esac
	fi
	case "$rc" in
	5 | 6 | 7 | 8 | 16 | 18 | 28 | 35 | 52 | 55 | 56 | 92) return 0 ;;
	22) return 0 ;; # HTTP error but no readable status: assume transient
	*) return 1 ;;
	esac
}

# Print the final response's Retry-After delay in seconds, or nothing.
# Only the delay-seconds form is honoured; an HTTP-date value is ignored.
# The value is printed as a digit string with leading zeros removed and is
# never converted to a number here, so an absurdly long value cannot overflow;
# callers must length-check it before any arithmetic.
# Usage: _lgtm_ci_download_retry_after headers_file
_lgtm_ci_download_retry_after() {
	_lgtm_ci_download_final_headers "${1:-}" |
		awk 'tolower($1) == "retry-after:" && NF == 2 && $2 ~ /^[0-9]+$/ { v = $2 }
			END { if (v != "") { sub(/^0+/, "", v); if (v == "") v = "0"; print v } }'
}

# Print a non-negative integer tunable, or the default (with a warning) when
# the value is not 1-9 decimal digits. Leading zeros are dropped.
# Usage: _lgtm_ci_download_int name value default
_lgtm_ci_download_int() {
	local name="$1" value="$2" default="$3"
	if [[ "$value" =~ ^[0-9]{1,9}$ ]]; then
		echo "$((10#$value))"
	else
		log_warn "Ignoring invalid ${name}='${value}' (want a whole number" \
			"of at most 9 digits); using ${default}"
		echo "$default"
	fi
}

# Current time in whole seconds; the download time budget is measured with it.
# Uses the system clock, not $SECONDS, which a caller may unset or reassign.
# Tests redefine this function to drive a fake clock.
_lgtm_ci_download_now() {
	date +%s
}

# Download file with retries and exponential backoff
# Usage: download_with_retries "url" "output_file" [max_attempts]
#   max_attempts  total attempts (default 5)
# Transient failures (see _lgtm_ci_download_retryable) are retried after
# 2s, 4s, 8s, 16s, ... (each wait capped at 30s). A Retry-After header given
# in seconds on the final response replaces the computed wait (same cap).
# Total sleep is capped at 60s, and the whole download (attempts plus waits)
# at 900s: each curl attempt gets --max-time of at most 300s and never more
# than the time left, and a retry whose wait does not fit is skipped. Once a
# budget is spent the download gives up. Permanent failures (404, TLS/pin
# errors) fail on the first attempt. Every failed attempt logs its HTTP status
# and curl exit code to stderr, so a rate limit (429) is distinguishable from
# a missing file (404).
# Tunables (whole seconds; invalid values fall back to the default):
#   LGTM_CI_DOWNLOAD_BACKOFF_BASE    first backoff wait (default 2)
#   LGTM_CI_DOWNLOAD_MAX_WAIT        cap on a single wait (default 30)
#   LGTM_CI_DOWNLOAD_MAX_SLEEP       cap on total sleep (default 60)
#   LGTM_CI_DOWNLOAD_TOTAL_TIMEOUT   cap on the whole download (default 900)
download_with_retries() {
	local url="$1"
	local out="$2"
	local attempts delay max_wait budget total
	attempts=$(_lgtm_ci_download_int max_attempts "${3:-5}" 5)
	delay=$(_lgtm_ci_download_int LGTM_CI_DOWNLOAD_BACKOFF_BASE \
		"${LGTM_CI_DOWNLOAD_BACKOFF_BASE:-2}" 2)
	max_wait=$(_lgtm_ci_download_int LGTM_CI_DOWNLOAD_MAX_WAIT \
		"${LGTM_CI_DOWNLOAD_MAX_WAIT:-30}" 30)
	budget=$(_lgtm_ci_download_int LGTM_CI_DOWNLOAD_MAX_SLEEP \
		"${LGTM_CI_DOWNLOAD_MAX_SLEEP:-60}" 60)
	total=$(_lgtm_ci_download_int LGTM_CI_DOWNLOAD_TOTAL_TIMEOUT \
		"${LGTM_CI_DOWNLOAD_TOTAL_TIMEOUT:-900}" 900)
	local per_attempt=300
	((attempts >= 1)) || attempts=1
	local i rc code wait retry_after start left headers=""
	local -a extra=()

	# Validate the hardened args (CA bundle) once before touching the network.
	_lgtm_ci_build_curl_args "$per_attempt" || return 1
	start=$(_lgtm_ci_download_now)

	# Response headers feed the Retry-After / rate-limit checks; without a temp
	# file the download still works, just without those hints.
	if headers=$(mktemp "${TMPDIR:-/tmp}/lgtm-dl-headers.XXXXXXXXXX" 2>/dev/null); then
		extra=(--dump-header "$headers")
	else
		headers=""
	fi

	for ((i = 1; i <= attempts; i++)); do
		left=$((total - ($(_lgtm_ci_download_now) - start)))
		if ((left <= 0)); then
			log_error "Download failed: ${total}s time budget spent" \
				"before attempt ${i}: $url"
			break
		fi
		# One --max-time per attempt: never longer than the time left.
		_lgtm_ci_build_curl_args "$((left < per_attempt ? left : per_attempt))" ||
			break
		log_verbose "Download attempt $i/$attempts: $url"
		if [[ -n "$headers" ]]; then
			: >"$headers"
		fi
		rc=0
		# --write-out prints only the final status to stdout (the body goes to
		# -o), and --fail from the hardened args still makes 4xx/5xx exit 22.
		code=$(curl "${_LGTM_CI_CURL_ARGS[@]}" ${extra[@]+"${extra[@]}"} \
			--write-out '%{http_code}' "$url" -o "$out") || rc=$?
		if [[ $rc -eq 0 ]]; then
			rm -f "${headers:-/nonexistent}"
			return 0
		fi
		code="${code: -3}"
		[[ "$code" =~ ^[0-9]{3}$ ]] || code="000"

		if ! _lgtm_ci_download_retryable "$rc" "$code" "$headers"; then
			log_error "Download failed (HTTP ${code}, curl exit ${rc});" \
				"not retryable: $url"
			break
		fi
		if ((i >= attempts)); then
			log_error "Download failed (HTTP ${code}, curl exit ${rc})" \
				"after ${attempts} attempts: $url"
			break
		fi

		wait="$delay"
		retry_after=$(_lgtm_ci_download_retry_after "$headers")
		if [[ -n "$retry_after" ]]; then
			# Length check first: a huge value must never reach arithmetic.
			if ((${#retry_after} > 9)); then
				wait="$max_wait"
			else
				wait="$retry_after"
			fi
		fi
		if ((wait > max_wait)); then
			wait="$max_wait"
		fi
		if ((wait > 0 && budget <= 0)); then
			log_error "Download failed (HTTP ${code}, curl exit ${rc});" \
				"retry budget spent after ${i} attempts: $url"
			break
		fi
		if ((wait > budget)); then
			wait="$budget"
		fi
		left=$((total - ($(_lgtm_ci_download_now) - start)))
		if ((left <= 0)); then
			log_error "Download failed (HTTP ${code}, curl exit ${rc});" \
				"${total}s time budget spent after ${i} attempts: $url"
			break
		fi
		if ((wait >= left)); then
			log_error "Download failed (HTTP ${code}, curl exit ${rc});" \
				"a ${wait}s wait does not fit the ${left}s left of the" \
				"${total}s time budget after ${i} attempts: $url"
			break
		fi
		budget=$((budget - wait))
		log_warn "Download attempt $i/$attempts failed (HTTP ${code}," \
			"curl exit ${rc}); retrying in ${wait}s: $url"
		if ((wait > 0)); then
			sleep "$wait"
		fi
		# Keep doubling bounded: it is capped by max_wait anyway.
		if ((delay < max_wait)); then
			delay=$((delay * 2))
		fi
	done
	rm -f "${headers:-/nonexistent}"
	return 1
}

# Download and execute installer script securely
# Downloads to temp file first, then executes (avoids curl|bash pattern)
# Note: Uses subshell for cleanup to avoid overwriting caller's traps
# Usage: download_and_run_installer "url" [expected_checksum] [args...]
# If expected_checksum is provided, verifies the download before execution
download_and_run_installer() {
	local url="$1"
	shift
	local expected_checksum=""
	local args=()

	# Check if first arg looks like a checksum (64 hex chars for sha256)
	if [[ $# -gt 0 && "$1" =~ ^[a-fA-F0-9]{64}$ ]]; then
		expected_checksum="$1"
		shift
	fi
	args=("$@")

	# Use subshell to avoid overwriting caller's traps
	(
		local tmpdir
		# Use portable mktemp with template (works on BSD/macOS/GNU)
		tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/lgtm-installer.XXXXXXXXXX") || {
			log_error "Failed to create temporary directory"
			exit 1
		}
		trap 'rm -rf "$tmpdir"' EXIT

		local script_file="$tmpdir/installer.sh"

		_lgtm_ci_build_curl_args 120 || exit 1

		log_verbose "Downloading installer from: $url"
		if ! curl "${_LGTM_CI_CURL_ARGS[@]}" "$url" -o "$script_file"; then
			log_error "Failed to download installer script"
			exit 1
		fi

		# Verify checksum if provided
		if [[ -n "$expected_checksum" ]]; then
			if declare -f verify_checksum &>/dev/null; then
				if ! verify_checksum "$script_file" "$expected_checksum" sha256; then
					log_error "Checksum verification failed for installer script"
					exit 1
				fi
				log_verbose "Installer checksum verified"
			else
				log_warn "verify_checksum not available, skipping integrity check"
			fi
		fi

		# Basic validation - check it's a shell script (bash or sh)
		if ! head -1 "$script_file" | grep -qE '^#!/.*(ba)?sh'; then
			log_warn "Downloaded file may not be a shell script"
		fi

		chmod +x "$script_file"
		log_verbose "Executing installer with args: ${args[*]:-none}"

		if [[ ${#args[@]} -gt 0 ]]; then
			"$script_file" "${args[@]}"
		else
			"$script_file"
		fi
	)
}

# Download a file with an explicit pinned public key (fails closed).
# Unlike download_with_retries (where pinning is an env opt-in), this
# function requires a pin: it errors out rather than silently downloading
# unpinned. Intended for high-value artifacts (installers, signing keys).
# Usage: download_with_pinning "url" "output_file" [pinned_key] [ca_bundle]
#   pinned_key  curl --pinnedpubkey value ("sha256//BASE64" or key file path);
#               falls back to $LGTM_CI_PINNED_PUBKEY when omitted
#   ca_bundle   optional custom CA bundle path (curl --cacert);
#               falls back to $LGTM_CI_CA_BUNDLE when omitted
download_with_pinning() {
	local url="$1"
	local out="$2"
	local pinned_key="${3:-${LGTM_CI_PINNED_PUBKEY:-}}"
	local ca_bundle="${4:-${LGTM_CI_CA_BUNDLE:-}}"

	if [[ -z "$pinned_key" ]]; then
		log_error "download_with_pinning: no pinned public key provided" \
			"(argument or LGTM_CI_PINNED_PUBKEY); refusing unpinned download"
		return 1
	fi
	# A pin that is a file path must exist; hash pins use the sha256// prefix
	if [[ "$pinned_key" != sha256//* && ! -r "$pinned_key" ]]; then
		log_error "download_with_pinning: pinned key file not readable: $pinned_key"
		return 1
	fi

	LGTM_CI_PINNED_PUBKEY="$pinned_key" LGTM_CI_CA_BUNDLE="$ca_bundle" \
		download_with_retries "$url" "$out"
}

# =============================================================================
# Export functions
# =============================================================================
export -f _lgtm_ci_build_curl_args _lgtm_ci_download_final_headers \
	_lgtm_ci_download_retryable _lgtm_ci_download_retry_after \
	_lgtm_ci_download_int _lgtm_ci_download_now download_with_retries \
	download_and_run_installer download_with_pinning
