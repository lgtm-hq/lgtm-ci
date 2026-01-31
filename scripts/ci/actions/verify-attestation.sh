#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Verify build attestations using gh attestation verify
#
# Required environment variables:
#   STEP - Which step to run: verify, parse, summary
#   TARGET - Target to verify (file path or image reference)
#   TARGET_TYPE - Type of target (file, image)
#   OWNER - Repository owner for attestation lookup

set -euo pipefail

: "${STEP:?STEP is required}"

# Source library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
[[ -f "$LIB_DIR/log.sh" ]] && source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
[[ -f "$LIB_DIR/github.sh" ]] && source "$LIB_DIR/github.sh"

case "$STEP" in
verify)
	: "${TARGET:?TARGET is required}"
	: "${TARGET_TYPE:=file}"
	: "${OWNER:=${GITHUB_REPOSITORY_OWNER:-}}"
	: "${REPO:=}"
	: "${VERIFICATION_OUTPUT:=${RUNNER_TEMP:-/tmp}/attestation-verification.json}"

	if [[ -z "$OWNER" ]]; then
		log_error "OWNER is required (set OWNER or GITHUB_REPOSITORY_OWNER)"
		exit 1
	fi

	# Build gh attestation verify command
	GH_ARGS=(attestation verify)

	case "$TARGET_TYPE" in
	file)
		if [[ ! -f "$TARGET" ]]; then
			log_error "File not found: $TARGET"
			exit 1
		fi
		GH_ARGS+=("$TARGET")
		;;
	image | container)
		GH_ARGS+=("$TARGET")
		;;
	*)
		log_error "Unsupported target type: $TARGET_TYPE"
		exit 1
		;;
	esac

	GH_ARGS+=(--owner "$OWNER")

	if [[ -n "$REPO" ]]; then
		GH_ARGS+=(--repo "$REPO")
	fi

	GH_ARGS+=(--format json)

	log_info "Verifying attestation for: $TARGET"
	log_info "Owner: $OWNER"

	# Run verification
	set +e
	gh "${GH_ARGS[@]}" >"$VERIFICATION_OUTPUT" 2>&1
	verify_exit_code=$?
	set -e

	verified="false"
	signer_identity=""

	if [[ $verify_exit_code -eq 0 ]]; then
		verified="true"
		log_success "Attestation verified successfully"

		# Parse signer identity from output
		if command -v jq >/dev/null 2>&1 && [[ -f "$VERIFICATION_OUTPUT" ]]; then
			signer_identity=$(jq -r '.[0].verificationResult.signature.certificate.subjectAlternativeName // ""' "$VERIFICATION_OUTPUT" 2>/dev/null || echo "")
		fi
	else
		log_error "Attestation verification failed"
		if [[ -f "$VERIFICATION_OUTPUT" ]]; then
			cat "$VERIFICATION_OUTPUT" >&2
		fi
	fi

	# Set outputs
	set_github_output "verified" "$verified"
	set_github_output "signer-identity" "$signer_identity"
	set_github_output "verification-output" "$VERIFICATION_OUTPUT"

	exit $verify_exit_code
	;;

parse)
	: "${VERIFICATION_OUTPUT:=${RUNNER_TEMP:-/tmp}/attestation-verification.json}"

	if [[ ! -f "$VERIFICATION_OUTPUT" ]]; then
		log_warn "Verification output not found: $VERIFICATION_OUTPUT"
		exit 0
	fi

	if ! command -v jq >/dev/null 2>&1; then
		log_warn "jq not available, skipping parse"
		cat "$VERIFICATION_OUTPUT"
		exit 0
	fi

	log_info "Attestation Details:"
	jq -r '
		.[0] |
		"Subject: \(.verificationResult.statement.subject[0].name // "unknown")",
		"Digest: \(.verificationResult.statement.subject[0].digest.sha256 // "unknown")",
		"Build Type: \(.verificationResult.statement.predicateType // "unknown")",
		"Signer: \(.verificationResult.signature.certificate.subjectAlternativeName // "unknown")"
	' "$VERIFICATION_OUTPUT" 2>/dev/null || cat "$VERIFICATION_OUTPUT"
	;;

summary)
	: "${VERIFIED:=false}"
	: "${SIGNER_IDENTITY:=}"
	: "${TARGET:=}"
	: "${TARGET_TYPE:=file}"

	add_github_summary "## Attestation Verification Summary"
	add_github_summary ""

	if [[ "$VERIFIED" == "true" ]]; then
		add_github_summary ":white_check_mark: **Attestation Verified**"
	else
		add_github_summary ":x: **Attestation Verification Failed**"
	fi

	add_github_summary ""
	add_github_summary "| Property | Value |"
	add_github_summary "|----------|-------|"
	add_github_summary "| **Target** | \`$TARGET\` |"
	add_github_summary "| **Type** | $TARGET_TYPE |"
	add_github_summary "| **Verified** | $VERIFIED |"

	if [[ -n "$SIGNER_IDENTITY" ]]; then
		add_github_summary "| **Signer** | \`$SIGNER_IDENTITY\` |"
	fi

	add_github_summary ""
	add_github_summary "> Verified using \`gh attestation verify\`"
	;;

*)
	echo "Unknown step: $STEP"
	exit 1
	;;
esac
