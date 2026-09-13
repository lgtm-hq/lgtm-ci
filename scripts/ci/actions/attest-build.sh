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

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

case "$STEP" in
prepare)
	: "${SUBJECT_PATH:?SUBJECT_PATH is required}"
	: "${SUBJECT_NAME:=}"
	: "${SUBJECT_DIGEST:=}"

	# Validate subject exists. A glob (dist/*) is expanded by
	# attest-build-provenance itself; here it only has to match something.
	IS_GLOB=false
	if [[ "$SUBJECT_PATH" == *[\*\?\[]* ]]; then
		IS_GLOB=true
		if ! compgen -G "$SUBJECT_PATH" >/dev/null; then
			log_error "Subject glob matches nothing: $SUBJECT_PATH"
			exit 1
		fi
	elif [[ ! -e "$SUBJECT_PATH" ]]; then
		log_error "Subject not found: $SUBJECT_PATH"
		exit 1
	fi

	USE_DIGEST=false
	if [[ -n "$SUBJECT_DIGEST" ]]; then
		if [[ "$IS_GLOB" == "true" ]]; then
			log_error "subject-digest cannot be combined with a subject-path glob"
			exit 1
		fi
		USE_DIGEST=true
	elif [[ "$IS_GLOB" == "false" && ! -f "$SUBJECT_PATH" ]]; then
		log_warn "Non-file subject; passing subject-path to attest-build-provenance"
	fi

	# Determine subject name if not provided
	if [[ -z "$SUBJECT_NAME" ]]; then
		if [[ "$IS_GLOB" == "true" ]]; then
			SUBJECT_NAME="$SUBJECT_PATH"
		else
			SUBJECT_NAME=$(basename "$SUBJECT_PATH")
		fi
	fi

	log_info "Subject: $SUBJECT_NAME"
	log_info "Path: $SUBJECT_PATH"
	if [[ "$USE_DIGEST" == "true" ]]; then
		log_info "Digest: $SUBJECT_DIGEST"
	else
		log_info "Attestation input: subject-path (digest computed by attest-build-provenance)"
	fi

	# actions/attest-build-provenance v4+ accepts only one subject parameter.
	set_github_output "subject-name" "$SUBJECT_NAME"
	if [[ "$USE_DIGEST" == "true" ]]; then
		set_github_output "subject-digest" "$SUBJECT_DIGEST"
	else
		set_github_output "subject-path" "$SUBJECT_PATH"
	fi
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
	die_unknown_step "$STEP"
	;;
esac
