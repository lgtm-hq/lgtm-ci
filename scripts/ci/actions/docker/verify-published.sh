#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Verify a just-published multi-arch image is complete in the registry
#          (build-docker STEP: verify-published)
#
# Pulls the published index back FROM THE REGISTRY and asserts that every
# expected per-platform child manifest resolves. This is the non-skippable gate
# that prevents a dangling index (child manifests 404) from publishing as green.
#
# Required environment variables:
#   REGISTRY    - Container registry URL (e.g. ghcr.io)
#   IMAGE_NAME  - Registry-relative image name (e.g. org/repo)
#   MATRIX      - JSON matrix from classify (array of {platform, slug, ...})
#   TARGET_TAGS - Newline-separated final image refs (docker metadata output);
#                 the first non-empty ref is inspected.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/docker.sh
source "$SCRIPT_DIR/../../lib/docker.sh"

: "${REGISTRY:?REGISTRY is required}"
: "${IMAGE_NAME:?IMAGE_NAME is required}"
: "${MATRIX:?MATRIX is required}"
: "${TARGET_TAGS:?TARGET_TAGS is required}"

# Resolve the ref to inspect: first non-empty target tag. Trim in pure shell
# (image refs contain no whitespace; avoids xargs quote/backslash surprises).
ref=""
while IFS= read -r tag; do
	tag="${tag#"${tag%%[![:space:]]*}"}"
	tag="${tag%"${tag##*[![:space:]]}"}"
	if [[ -n "$tag" ]]; then
		ref="$tag"
		break
	fi
done <<<"$TARGET_TAGS"

if [[ -z "$ref" ]]; then
	die "No target tag found in TARGET_TAGS — cannot verify published image"
fi

log_info "Verifying published manifest: ${ref}"

# Pull the index manifest back from the registry (authoritative — not a local image).
index_json=""
inspect_err="$(mktemp)"
if ! index_json=$(docker buildx imagetools inspect --raw "$ref" 2>"$inspect_err"); then
	die "Published manifest not resolvable in registry: ${ref}: $(cat "$inspect_err")"
fi
rm -f "$inspect_err"

# A complete multi-arch publish is an image index / manifest list with children.
child_count=$(echo "$index_json" | jq '(.manifests // []) | length')
if [[ "$child_count" -eq 0 ]]; then
	die "Published ref ${ref} is not a multi-arch index (no child manifests)"
fi

# Assert every expected platform has a child manifest whose digest resolves in
# the registry. Iterating expected platforms (not the index's own list) catches
# both missing children and children that 404 when pulled by digest.
missing=0
while IFS= read -r platform; do
	[[ -z "$platform" ]] && continue
	os="${platform%%/*}"
	arch="${platform#*/}"

	digest=$(echo "$index_json" | jq -r \
		--arg os "$os" --arg arch "$arch" \
		'(.manifests // [])[]
		 | select(.platform.os == $os and .platform.architecture == $arch)
		 | .digest' | head -1)

	if [[ -z "$digest" || "$digest" == "null" ]]; then
		log_error "Index ${ref} has no child manifest for platform ${platform}"
		missing=$((missing + 1))
		continue
	fi

	# Registry pull-back by digest: a dangling child 404s here.
	if docker buildx imagetools inspect "${REGISTRY}/${IMAGE_NAME}@${digest}" >/dev/null 2>&1; then
		log_success "Child manifest resolves: ${platform} -> ${digest}"
	else
		log_error "Child manifest for ${platform} does not resolve in registry (dangling): ${digest}"
		missing=$((missing + 1))
	fi
done < <(echo "$MATRIX" | jq -r '.[].platform')

if [[ "$missing" -gt 0 ]]; then
	die "Published image ${ref} is incomplete: ${missing} platform child manifest(s) missing or unresolvable"
fi

log_success "Published image verified: all platform children resolve in the registry"
