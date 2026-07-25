#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Sign a pushed image manifest with Cosign keyless signing
#          (build-docker STEP: sign-image)
#
# Required environment variables:
#   DIGEST     - Image digest (sha256:...)
#   REGISTRY   - Container registry URL
#   IMAGE_NAME - Registry-relative image name
#
# Optional environment variables:
#   COSIGN_SIGN_MAX_ATTEMPTS - Max signing attempts (default: 3, minimum 1)
#   COSIGN_SIGN_MAX_DELAY    - Cap for the exponential backoff, seconds
#                              (default: 30)

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/docker.sh
source "$SCRIPT_DIR/../../lib/docker.sh"

: "${DIGEST:?DIGEST is required}"
: "${REGISTRY:?REGISTRY is required}"
: "${IMAGE_NAME:?IMAGE_NAME is required}"
: "${COSIGN_SIGN_MAX_ATTEMPTS:=3}"
: "${COSIGN_SIGN_MAX_DELAY:=30}"

# Ambient-OIDC token fetches flake on Sigstore/GitHub hiccups and are the only
# signing failure class safe to retry: nothing has been signed yet, so a retry
# cannot mask a rejected signature. Fixed strings, matched case-insensitively.
#
# NOTE: this list is intentionally local to this script. Sharing it with the
# auto-rerun matcher signatures in scripts/ci/actions/rerun-on-infra-failure.sh
# is deliberately out of scope here and tracked in issue #719.
COSIGN_OIDC_TRANSIENT_MARKERS=(
	"fetching ambient OIDC credentials"
	"retrieving ID token"
	"reading ID token"
)

if ! [[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
	die "DIGEST is not a valid sha256 digest: ${DIGEST}"
fi

# Both knobs feed arithmetic comparisons; reject anything that is not a
# non-negative integer up front so typos fail loudly instead of raising an
# arithmetic error under set -e.
#
# Zero-padded values ("08") pass the digit-only check but are invalid octal in
# Bash arithmetic, so normalise to base 10 before any (( )) evaluation instead
# of letting set -e abort the signing step on a raw arithmetic error.
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

if ! command -v cosign >/dev/null 2>&1; then
	die "cosign not found. Install via sigstore/cosign-installer action."
fi

# Print the first transient OIDC marker present in the given cosign output;
# return 1 when none match (i.e. the failure is real and must stay fatal).
match_transient_oidc_marker() {
	local output="$1" marker
	for marker in "${COSIGN_OIDC_TRANSIENT_MARKERS[@]}"; do
		if grep -qiF -- "$marker" <<<"$output"; then
			printf '%s\n' "$marker"
			return 0
		fi
	done
	return 1
}

# Sign the given image ref, retrying only transient ambient-OIDC failures with
# exponential backoff capped at COSIGN_SIGN_MAX_DELAY seconds.
sign_image_with_retry() {
	local image_ref="$1"
	local attempt=1 delay=1 output status marker

	# Honour COSIGN_SIGN_MAX_DELAY=0 as "retry without waiting".
	if ((delay > COSIGN_SIGN_MAX_DELAY)); then
		delay="$COSIGN_SIGN_MAX_DELAY"
	fi

	while :; do
		status=0
		output="$(cosign sign --yes "$image_ref" 2>&1)" || status=$?

		# Never swallow cosign output: it is the only record of what happened.
		if [[ -n "$output" ]]; then
			printf '%s\n' "$output" >&2
		fi

		if ((status == 0)); then
			return 0
		fi

		if ! marker="$(match_transient_oidc_marker "$output")"; then
			die "cosign sign failed for ${image_ref} on attempt ${attempt} (exit ${status}); failure is not a transient OIDC token fetch, not retrying"
		fi

		if ((attempt >= COSIGN_SIGN_MAX_ATTEMPTS)); then
			die "cosign sign failed for ${image_ref} after ${attempt} attempt(s): transient OIDC failure persisted (matched '${marker}')"
		fi

		log_warning "Transient OIDC failure signing ${image_ref} (attempt ${attempt}/${COSIGN_SIGN_MAX_ATTEMPTS}, matched '${marker}'); retrying in ${delay}s"
		sleep "$delay"

		delay=$((delay * 2))
		if ((delay > COSIGN_SIGN_MAX_DELAY)); then
			delay="$COSIGN_SIGN_MAX_DELAY"
		fi
		((attempt++))
	done
}

image_ref="${REGISTRY}/${IMAGE_NAME}@${DIGEST}"
log_info "Signing image: ${image_ref}"
sign_image_with_retry "$image_ref"
log_success "Signed image: ${image_ref}"
