#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Cosign keyless-signing helpers: transient ambient-OIDC
#          classification plus a bounded, transient-only retry shared by every
#          cosign signing path (image manifests and blobs alike). Also the
#          single source of the transient ambient-OIDC marker strings, consumed
#          by the auto-rerun safety net in
#          scripts/ci/actions/rerun-on-infra-failure.sh.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/cosign.sh"
#   cosign_validate_retry_bounds
#   cosign_sign_with_retry "cosign sign-blob" "$file" \
#       cosign sign-blob --yes --bundle="$bundle" "$file"
#
# Optional environment variables (read by cosign_validate_retry_bounds and
# cosign_sign_with_retry):
#   COSIGN_SIGN_MAX_ATTEMPTS - Max signing attempts (default: 3, minimum 1)
#   COSIGN_SIGN_MAX_DELAY    - Cap for the exponential backoff, seconds
#                              (default: 30; 0 means retry without waiting)

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_COSIGN_LOADED:-}" ]] && return 0
readonly _LGTM_CI_COSIGN_LOADED=1

# Source logging if available (provides log_warning/die)
_LGTM_CI_COSIGN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)" || {
	echo "cosign.sh: cannot resolve library directory" >&2
	return 1
}
if [[ -f "$_LGTM_CI_COSIGN_LIB_DIR/log.sh" ]]; then
	# shellcheck source=log.sh
	source "$_LGTM_CI_COSIGN_LIB_DIR/log.sh"
fi

# Fallbacks when log.sh was unavailable
if ! declare -f die &>/dev/null; then
	die() {
		echo "[ERROR] $*" >&2
		exit 1
	}
fi
if ! declare -f log_warning &>/dev/null; then
	log_warning() {
		echo "[WARN] $*" >&2
	}
fi

# =============================================================================
# Transient failure classification
# =============================================================================

# Ambient-OIDC token fetches flake on Sigstore/GitHub hiccups and are the only
# signing failure class safe to retry: nothing has been signed yet, so a retry
# cannot mask a rejected signature. Fixed strings, one per line, transcribed in
# the exact case cosign emits (Go error strings are lower-case by convention;
# only the "OIDC" and "ID token" acronyms are capitalised).
#
# This is the single source for the cosign OIDC marker list. Besides the signing
# paths in this repo it is also consumed by the after-the-fact auto-rerun safety
# net (scripts/ci/actions/rerun-on-infra-failure.sh, #719), which matches the
# same flake class in failed-job logs once the in-step retry is exhausted. Add a
# marker here and both the fast path and the slow path pick it up.
#
# A newline-delimited string rather than an array (#719): the public helpers are
# exported with `export -f` like every other lib in scripts/ci/lib, and bash
# cannot export an array — an exported function invoked in a child shell would
# hit an unbound-variable error under `set -u`. A scalar can be exported, so the
# exported functions stay usable without re-sourcing the lib. It also lets the
# auto-rerun matcher append the markers straight onto its newline-delimited
# signature list.
COSIGN_OIDC_TRANSIENT_MARKERS="fetching ambient OIDC credentials
retrieving ID token
reading ID token"
export COSIGN_OIDC_TRANSIENT_MARKERS
readonly COSIGN_OIDC_TRANSIENT_MARKERS

readonly COSIGN_SIGN_DEFAULT_MAX_ATTEMPTS=3
readonly COSIGN_SIGN_DEFAULT_MAX_DELAY=30

# Print the first transient OIDC marker present in the given cosign output;
# return 1 when none match (i.e. the failure is real and must stay fatal).
#
# Deliberately case-insensitive, unlike the case-sensitive matcher in
# scripts/ci/actions/rerun-on-infra-failure.sh (#719). The blast radius differs:
# here the input is the output of one cosign invocation that has already failed
# with nothing signed yet, so a lenient match costs at most a few retried
# seconds while a missed match costs a whole failed publish. The safety net
# instead decides whether to re-run an entire workflow that may have failed for
# real, so it stays strict.
cosign_transient_oidc_marker() {
	local output="$1" marker
	while IFS= read -r marker; do
		[[ -z "$marker" ]] && continue
		if grep -qiF -- "$marker" <<<"$output"; then
			printf '%s\n' "$marker"
			return 0
		fi
	done <<<"$COSIGN_OIDC_TRANSIENT_MARKERS"
	return 1
}

# =============================================================================
# Retry bounds
# =============================================================================

# Validate and normalise COSIGN_SIGN_MAX_ATTEMPTS / COSIGN_SIGN_MAX_DELAY,
# applying defaults when unset. Dies on anything that is not a valid bound.
#
# Both knobs feed arithmetic comparisons; reject anything that is not a
# non-negative integer up front so typos fail loudly instead of raising an
# arithmetic error under set -e.
#
# Zero-padded values ("08") pass the digit-only check but are invalid octal in
# Bash arithmetic, so normalise to base 10 before any (( )) evaluation instead
# of letting set -e abort the signing step on a raw arithmetic error.
cosign_validate_retry_bounds() {
	: "${COSIGN_SIGN_MAX_ATTEMPTS:=$COSIGN_SIGN_DEFAULT_MAX_ATTEMPTS}"
	: "${COSIGN_SIGN_MAX_DELAY:=$COSIGN_SIGN_DEFAULT_MAX_DELAY}"

	if [[ ! "$COSIGN_SIGN_MAX_ATTEMPTS" =~ ^[0-9]+$ ]]; then
		die "COSIGN_SIGN_MAX_ATTEMPTS must be a non-negative integer (got '${COSIGN_SIGN_MAX_ATTEMPTS}')"
	fi
	COSIGN_SIGN_MAX_ATTEMPTS=$((10#$COSIGN_SIGN_MAX_ATTEMPTS))
	if ((COSIGN_SIGN_MAX_ATTEMPTS < 1)); then
		die "COSIGN_SIGN_MAX_ATTEMPTS must be at least 1 (got '${COSIGN_SIGN_MAX_ATTEMPTS}')"
	fi

	if [[ ! "$COSIGN_SIGN_MAX_DELAY" =~ ^[0-9]+$ ]]; then
		die "COSIGN_SIGN_MAX_DELAY must be a non-negative integer (got '${COSIGN_SIGN_MAX_DELAY}')"
	fi
	COSIGN_SIGN_MAX_DELAY=$((10#$COSIGN_SIGN_MAX_DELAY))
}

# =============================================================================
# Bounded, transient-only signing retry
# =============================================================================

# Run a cosign signing command, retrying only transient ambient-OIDC failures
# with exponential backoff capped at COSIGN_SIGN_MAX_DELAY seconds.
#
# Usage: cosign_sign_with_retry <operation> <target> <command> [args...]
#   operation - Human-readable operation label used in messages
#               (e.g. "cosign sign", "cosign sign-blob")
#   target    - What is being signed (image ref or file path), for messages
#   command   - The command to run, passed through verbatim; keeps this helper
#               generic over `cosign sign` vs `cosign sign-blob` argument shapes
#
# Retry contract:
#   - combined stdout+stderr is captured per attempt and echoed (never swallowed)
#   - retried ONLY when the output matches a COSIGN_OIDC_TRANSIENT_MARKERS entry
#   - every other failure (rejected signature, policy failure, registry/upload
#     error, empty output) is fatal on attempt 1
cosign_sign_with_retry() {
	local operation="$1" target="$2"
	shift 2

	if (($# == 0)); then
		die "cosign_sign_with_retry: no command given for ${operation} of ${target}"
	fi

	# Self-validate so direct callers get the same defaults, base-10
	# normalisation, and loud rejection of bad knobs as the action scripts that
	# call cosign_validate_retry_bounds up front. Idempotent: once normalised
	# the values are plain decimal digits, so re-validating is a no-op.
	cosign_validate_retry_bounds

	local max_attempts="$COSIGN_SIGN_MAX_ATTEMPTS"
	local max_delay="$COSIGN_SIGN_MAX_DELAY"
	local attempt=1 delay=1 output status marker

	# Honour COSIGN_SIGN_MAX_DELAY=0 as "retry without waiting".
	if ((delay > max_delay)); then
		delay="$max_delay"
	fi

	while :; do
		status=0
		output="$("$@" 2>&1)" || status=$?

		# Never swallow cosign output: it is the only record of what happened.
		if [[ -n "$output" ]]; then
			printf '%s\n' "$output" >&2
		fi

		if ((status == 0)); then
			return 0
		fi

		if ! marker="$(cosign_transient_oidc_marker "$output")"; then
			die "${operation} failed for ${target} on attempt ${attempt} (exit ${status}); failure is not a transient OIDC token fetch, not retrying"
		fi

		if ((attempt >= max_attempts)); then
			die "${operation} failed for ${target} after ${attempt} attempt(s): transient OIDC failure persisted (matched '${marker}')"
		fi

		log_warning "Transient OIDC failure signing ${target} (attempt ${attempt}/${max_attempts}, matched '${marker}'); retrying in ${delay}s"
		sleep "$delay"

		delay=$((delay * 2))
		if ((delay > max_delay)); then
			delay="$max_delay"
		fi
		((attempt++))
	done
}

export -f cosign_transient_oidc_marker cosign_validate_retry_bounds
export -f cosign_sign_with_retry
