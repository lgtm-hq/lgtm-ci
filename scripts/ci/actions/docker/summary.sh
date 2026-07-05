#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Write the Docker build results to the GitHub step summary
#          (build-docker STEP: summary)
#
# Optional environment variables:
#   REGISTRY - Registry URL (default: ghcr.io)
#   IMAGE_NAME - Image name
#   TAGS - Newline-separated image tags
#   PLATFORMS - Target platforms
#   PUSH - Whether images were pushed (default: false)
#   DIGEST - Image digest
#   COSIGN_SIGNED - Whether the image was Cosign-signed (default: false)
#   SCAN_ENABLED - Whether a Trivy scan ran (default: false)
#   VALIDATE_ON_PR - Whether PR validation was enabled (default: false)
#   MATRIX - JSON matrix from classify step
#   HEALTH_CHECK_ENABLED - Whether a health check ran (default: false)

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/docker.sh
source "$SCRIPT_DIR/../../lib/docker.sh"

: "${REGISTRY:=ghcr.io}"
: "${IMAGE_NAME:=}"
: "${TAGS:=}"
: "${PLATFORMS:=}"
: "${PUSH:=false}"
: "${DIGEST:=}"
: "${COSIGN_SIGNED:=false}"
: "${SCAN_ENABLED:=false}"
: "${VALIDATE_ON_PR:=false}"
: "${MATRIX:=}"
: "${HEALTH_CHECK_ENABLED:=false}"

full_image="${REGISTRY}/${IMAGE_NAME}"

add_github_summary "## Docker Build Results"
add_github_summary ""

add_github_summary "| Property | Value |"
add_github_summary "|----------|-------|"
add_github_summary "| Image | \`${full_image}\` |"
add_github_summary "| Platforms | \`${PLATFORMS}\` |"
add_github_summary "| Pushed | ${PUSH} |"
if [[ "$VALIDATE_ON_PR" == "true" ]]; then
	add_github_summary "| PR validation | enabled |"
fi
add_github_summary ""

if [[ -n "$DIGEST" ]]; then
	add_github_summary "### Digest"
	add_github_summary ""
	add_github_summary "\`${DIGEST}\`"
	add_github_summary ""
fi

if [[ -n "$MATRIX" && "$MATRIX" != "[]" ]]; then
	add_github_summary "### Per-platform build matrix"
	add_github_summary ""
	while IFS= read -r platform; do
		[[ -n "$platform" ]] && add_github_summary "- \`${platform}\`"
	done < <(echo "$MATRIX" | jq -r '.[].platform')
	add_github_summary ""
fi

if [[ -n "$TAGS" ]]; then
	add_github_summary "### Tags"
	add_github_summary ""
	readarray -t tag_array <<<"$TAGS"
	for tag in "${tag_array[@]}"; do
		tag=$(echo "$tag" | xargs)
		if [[ -n "$tag" ]]; then
			add_github_summary "- \`$tag\`"
		fi
	done
	add_github_summary ""
fi

if [[ "$COSIGN_SIGNED" == "true" && -n "$DIGEST" ]]; then
	# Default identity matches the signing repo; callers may tighten further.
	: "${GITHUB_REPOSITORY:=ORG/REPO}"
	cosign_identity="https://github.com/${GITHUB_REPOSITORY}/.*"

	add_github_summary "### Image signature"
	add_github_summary ""
	add_github_summary "Verify with:"
	add_github_summary ""
	add_github_summary "\`\`\`bash"
	add_github_summary "cosign verify ${full_image}@${DIGEST} \\"
	add_github_summary "  --certificate-identity-regexp='${cosign_identity}' \\"
	add_github_summary "  --certificate-oidc-issuer='https://token.actions.githubusercontent.com'"
	add_github_summary "\`\`\`"
	add_github_summary ""
fi

if [[ "$SCAN_ENABLED" == "true" ]]; then
	add_github_summary "### Vulnerability scan"
	add_github_summary ""
	add_github_summary "Trivy scanned CRITICAL/HIGH findings. Review the Security tab for SARIF results."
	add_github_summary ""
fi

if [[ "$HEALTH_CHECK_ENABLED" == "true" ]]; then
	add_github_summary "### Health check"
	add_github_summary ""
	add_github_summary "Detached-container health check passed before publish."
	add_github_summary ""
fi

add_github_summary ""
