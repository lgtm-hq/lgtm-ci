#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Sign release artifacts using Sigstore/Cosign keyless signing
#
# Required environment variables:
#   STEP - Which step to run: sign, upload-release, summary
#   FILES - Glob pattern(s) for files to sign (space-separated)

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

case "$STEP" in
sign)
	: "${FILES:?FILES is required}"
	: "${SIGNATURES_DIR:=${RUNNER_TEMP:-/tmp}/cosign-signatures}"

	if ! command -v cosign >/dev/null 2>&1; then
		die "cosign not found. Install via sigstore/cosign-installer action."
	fi

	mkdir -p "$SIGNATURES_DIR"

	# Expand glob patterns into file list
	file_list=()
	for pattern in $FILES; do
		# shellcheck disable=SC2206
		matched=($pattern)
		for f in "${matched[@]}"; do
			if [[ -f "$f" ]]; then
				file_list+=("$f")
			fi
		done
	done

	if [[ ${#file_list[@]} -eq 0 ]]; then
		die "No files matched pattern(s): $FILES"
	fi

	log_info "Signing ${#file_list[@]} file(s) with Cosign keyless signing"

	signatures=""
	certificate=""
	signed_count=0

	for file in "${file_list[@]}"; do
		# Use full path with separators replaced to avoid collisions
		# when different directories contain files with the same basename
		sanitized="$(echo "$file" | sed 's|^/||; s|/|__|g')"
		sig_file="${SIGNATURES_DIR}/${sanitized}.sig"
		cert_file="${SIGNATURES_DIR}/${sanitized}.pem"

		log_info "Signing: $file"

		cosign sign-blob --yes \
			--output-signature "$sig_file" \
			--output-certificate "$cert_file" \
			"$file"

		if [[ -f "$sig_file" ]]; then
			signed_count=$((signed_count + 1))
			if [[ -n "$signatures" ]]; then
				signatures="${signatures}"$'\n'"${sig_file}"
			else
				signatures="$sig_file"
			fi
			certificate="$cert_file"
			log_success "Signed: $(basename "$file")"
		else
			log_error "Failed to sign: $file"
		fi
	done

	if [[ $signed_count -eq 0 ]]; then
		die "No files were successfully signed"
	fi

	log_success "Successfully signed $signed_count file(s)"

	# Set outputs
	set_github_output_multiline "signatures" "$signatures"
	set_github_output "certificate" "$certificate"
	set_github_output "signatures-dir" "$SIGNATURES_DIR"
	set_github_output "signed-count" "$signed_count"
	;;

upload-release)
	: "${RELEASE_TAG:?RELEASE_TAG is required}"
	: "${SIGNATURES_DIR:=${RUNNER_TEMP:-/tmp}/cosign-signatures}"

	if [[ ! -d "$SIGNATURES_DIR" ]]; then
		die "Signatures directory not found: $SIGNATURES_DIR"
	fi

	log_info "Uploading signatures to release: $RELEASE_TAG"

	# Upload .sig and .pem files to the release
	# shellcheck disable=SC2086
	gh release upload "$RELEASE_TAG" \
		"${SIGNATURES_DIR}"/*.sig \
		"${SIGNATURES_DIR}"/*.pem \
		--clobber

	log_success "Signatures uploaded to release $RELEASE_TAG"
	;;

summary)
	: "${SIGNED_COUNT:=0}"
	: "${FILES:=}"
	: "${CERTIFICATE:=}"
	: "${SIGNATURES:=}"

	add_github_summary "## Artifact Signing Summary"
	add_github_summary ""

	if [[ "$SIGNED_COUNT" -gt 0 ]]; then
		add_github_summary ":white_check_mark: **$SIGNED_COUNT artifact(s) signed**"
	else
		add_github_summary ":x: **No artifacts signed**"
	fi

	add_github_summary ""
	add_github_summary "| Property | Value |"
	add_github_summary "|----------|-------|"
	add_github_summary "| **Signed Count** | $SIGNED_COUNT |"
	add_github_summary "| **File Pattern(s)** | \`$FILES\` |"

	if [[ -n "$CERTIFICATE" ]]; then
		add_github_summary "| **Certificate** | \`$(basename "$CERTIFICATE")\` |"
	fi

	if [[ -n "$SIGNATURES" ]]; then
		sig_list=""
		while IFS= read -r sig; do
			if [[ -n "$sig" ]]; then
				sig_list="${sig_list}- \`$(basename "$sig")\`"$'\n'
			fi
		done <<<"$SIGNATURES"

		add_github_summary_details "Signature Files" "$sig_list"
	fi

	add_github_summary ""
	add_github_summary "> Signed using [Sigstore Cosign](https://github.com/sigstore/cosign) keyless signing"
	add_github_summary ""
	add_github_summary "**Verify with:**"
	# shellcheck disable=SC1003
	add_github_summary '```bash'
	# shellcheck disable=SC1003
	add_github_summary 'cosign verify-blob --certificate <file>.pem --signature <file>.sig \'
	# shellcheck disable=SC1003
	add_github_summary '  --certificate-identity <workflow-url> \'
	# shellcheck disable=SC1003
	add_github_summary '  --certificate-oidc-issuer https://token.actions.githubusercontent.com \'
	add_github_summary '  <file>'
	add_github_summary '```'
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
