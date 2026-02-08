#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Verify Sigstore/Cosign signatures on artifacts
#
# Required environment variables:
#   STEP - Which step to run: verify, summary
#   FILE - File to verify
#   SIGNATURE - Path to the signature file (.sig)
#   CERTIFICATE - Path to the certificate file (.pem)
#   CERTIFICATE_IDENTITY - Expected signer identity (workflow URL)
#   CERTIFICATE_OIDC_ISSUER - Expected OIDC issuer

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

case "$STEP" in
verify)
	: "${FILE:?FILE is required}"
	: "${SIGNATURE:?SIGNATURE is required}"
	: "${CERTIFICATE:?CERTIFICATE is required}"
	: "${CERTIFICATE_IDENTITY:?CERTIFICATE_IDENTITY is required}"
	: "${CERTIFICATE_OIDC_ISSUER:?CERTIFICATE_OIDC_ISSUER is required}"

	if ! command -v cosign >/dev/null 2>&1; then
		die "cosign not found. Install via sigstore/cosign-installer action."
	fi

	if [[ ! -f "$FILE" ]]; then
		die "File not found: $FILE"
	fi

	if [[ ! -f "$SIGNATURE" ]]; then
		die "Signature file not found: $SIGNATURE"
	fi

	if [[ ! -f "$CERTIFICATE" ]]; then
		die "Certificate file not found: $CERTIFICATE"
	fi

	log_info "Verifying signature for: $FILE"
	log_info "Signature: $SIGNATURE"
	log_info "Certificate: $CERTIFICATE"
	log_info "Expected identity: $CERTIFICATE_IDENTITY"
	log_info "Expected issuer: $CERTIFICATE_OIDC_ISSUER"

	set +e
	cosign verify-blob \
		--signature "$SIGNATURE" \
		--certificate "$CERTIFICATE" \
		--certificate-identity "$CERTIFICATE_IDENTITY" \
		--certificate-oidc-issuer "$CERTIFICATE_OIDC_ISSUER" \
		"$FILE" 2>&1
	verify_exit_code=$?
	set -e

	verified="false"
	if [[ $verify_exit_code -eq 0 ]]; then
		verified="true"
		log_success "Signature verified successfully"
	else
		log_error "Signature verification failed"
	fi

	# Set outputs
	set_github_output "verified" "$verified"

	exit $verify_exit_code
	;;

summary)
	: "${VERIFIED:=false}"
	: "${FILE:=}"
	: "${SIGNATURE:=}"
	: "${CERTIFICATE_IDENTITY:=}"

	add_github_summary "## Signature Verification Summary"
	add_github_summary ""

	if [[ "$VERIFIED" == "true" ]]; then
		add_github_summary ":white_check_mark: **Signature Verified**"
	else
		add_github_summary ":x: **Signature Verification Failed**"
	fi

	add_github_summary ""
	add_github_summary "| Property | Value |"
	add_github_summary "|----------|-------|"
	add_github_summary "| **File** | \`$FILE\` |"

	if [[ -n "$SIGNATURE" ]]; then
		add_github_summary "| **Signature** | \`$(basename "$SIGNATURE")\` |"
	fi

	add_github_summary "| **Verified** | $VERIFIED |"

	if [[ -n "$CERTIFICATE_IDENTITY" ]]; then
		add_github_summary "| **Signer Identity** | \`$CERTIFICATE_IDENTITY\` |"
	fi

	add_github_summary ""
	add_github_summary "> Verified using [Sigstore Cosign](https://github.com/sigstore/cosign)"
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
