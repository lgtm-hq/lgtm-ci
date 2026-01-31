#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Create build attestations using GitHub attestations
#
# Required environment variables:
#   STEP - Which step to run: prepare, summary
#   SUBJECT_PATH - Path to the artifact to attest
#   SUBJECT_NAME - Name of the subject (optional)
#   SUBJECT_DIGEST - Digest of the subject (optional)
#   PUSH_TO_REGISTRY - Whether to push attestation to registry

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
prepare)
	: "${SUBJECT_PATH:?SUBJECT_PATH is required}"
	: "${SUBJECT_NAME:=}"
	: "${SUBJECT_DIGEST:=}"

	# Validate subject exists
	if [[ ! -e "$SUBJECT_PATH" ]]; then
		log_error "Subject not found: $SUBJECT_PATH"
		exit 1
	fi

	# Calculate digest if not provided
	if [[ -z "$SUBJECT_DIGEST" ]]; then
		if [[ -f "$SUBJECT_PATH" ]]; then
			SUBJECT_DIGEST="sha256:$(sha256sum "$SUBJECT_PATH" | cut -d' ' -f1)"
			log_info "Calculated digest: $SUBJECT_DIGEST"
		else
			log_warn "Cannot calculate digest for non-file subject"
		fi
	fi

	# Determine subject name if not provided
	if [[ -z "$SUBJECT_NAME" ]]; then
		SUBJECT_NAME=$(basename "$SUBJECT_PATH")
	fi

	log_info "Subject: $SUBJECT_NAME"
	log_info "Path: $SUBJECT_PATH"
	log_info "Digest: ${SUBJECT_DIGEST:-not calculated}"

	# Set outputs for the attestation action
	set_github_output "subject-path" "$SUBJECT_PATH"
	set_github_output "subject-name" "$SUBJECT_NAME"
	[[ -n "$SUBJECT_DIGEST" ]] && set_github_output "subject-digest" "$SUBJECT_DIGEST"
	;;

summary)
	: "${ATTESTATION_ID:=}"
	: "${ATTESTATION_URL:=}"
	: "${BUNDLE_PATH:=}"
	: "${SUBJECT_NAME:=}"

	add_github_summary "## Build Attestation Summary"
	add_github_summary ""
	add_github_summary "| Property | Value |"
	add_github_summary "|----------|-------|"

	if [[ -n "$SUBJECT_NAME" ]]; then
		add_github_summary "| **Subject** | \`$SUBJECT_NAME\` |"
	fi

	if [[ -n "$ATTESTATION_ID" ]]; then
		add_github_summary "| **Attestation ID** | \`$ATTESTATION_ID\` |"
	fi

	if [[ -n "$ATTESTATION_URL" ]]; then
		add_github_summary "| **Attestation URL** | [$ATTESTATION_URL]($ATTESTATION_URL) |"
	fi

	if [[ -n "$BUNDLE_PATH" ]]; then
		add_github_summary "| **Bundle Path** | \`$BUNDLE_PATH\` |"
	fi

	add_github_summary ""
	add_github_summary "> Attestation created using [actions/attest-build-provenance](https://github.com/actions/attest-build-provenance)"
	add_github_summary ""
	add_github_summary "### Verification"
	add_github_summary ""
	add_github_summary "To verify the attestation, use:"
	add_github_summary ""
	add_github_summary '```bash'
	if [[ -n "$SUBJECT_NAME" ]]; then
		add_github_summary "gh attestation verify $SUBJECT_NAME --owner \$GITHUB_REPOSITORY_OWNER"
	else
		add_github_summary "gh attestation verify <artifact> --owner \$GITHUB_REPOSITORY_OWNER"
	fi
	add_github_summary '```'
	;;

*)
	echo "Unknown step: $STEP"
	exit 1
	;;
esac
