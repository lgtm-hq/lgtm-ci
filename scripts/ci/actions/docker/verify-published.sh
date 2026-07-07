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

# Registry reads are not guaranteed read-after-write consistent, so a manifest
# can lag its push briefly. Retry registry inspects before failing — a genuine
# dangling child never resolves, so retries only absorb propagation delay.
VERIFY_ATTEMPTS="${VERIFY_ATTEMPTS:-5}"
VERIFY_DELAY="${VERIFY_DELAY:-3}"

# _inspect_ref <ref> — succeed if the ref resolves in the registry (with retry).
_inspect_ref() {
	local target="$1" i
	for ((i = 1; i <= VERIFY_ATTEMPTS; i++)); do
		if docker buildx imagetools inspect "$target" >/dev/null 2>&1; then
			return 0
		fi
		[[ "$i" -lt "$VERIFY_ATTEMPTS" ]] && sleep "$VERIFY_DELAY"
	done
	return 1
}

# Pull the index manifest back from the registry (authoritative — not a local
# image), retrying to absorb read-after-write lag.
# Parse the expected platforms up front and fail CLOSED on a malformed MATRIX:
# a bad matrix must never let the loop run zero times and pass vacuously (this
# is a release gate).
if ! echo "$MATRIX" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
	die "MATRIX must be a non-empty JSON array of platform objects: ${MATRIX}"
fi
mapfile -t expected_platforms < <(echo "$MATRIX" | jq -r '.[].platform // empty')
if [[ "${#expected_platforms[@]}" -eq 0 ]]; then
	die "MATRIX entries expose no .platform values: ${MATRIX}"
fi

index_json=""
inspect_err="$(mktemp)"
trap 'rm -f "$inspect_err"' EXIT
for ((attempt = 1; attempt <= VERIFY_ATTEMPTS; attempt++)); do
	if index_json=$(docker buildx imagetools inspect --raw "$ref" 2>"$inspect_err"); then
		break
	fi
	index_json=""
	[[ "$attempt" -lt "$VERIFY_ATTEMPTS" ]] && sleep "$VERIFY_DELAY"
done
if [[ -z "$index_json" ]]; then
	die "Published manifest not resolvable in registry: ${ref}: $(cat "$inspect_err")"
fi

# A complete multi-arch publish is an image index / manifest list with children.
child_count=$(echo "$index_json" | jq '(.manifests // []) | length')
if [[ "$child_count" -eq 0 ]]; then
	die "Published ref ${ref} is not a multi-arch index (no child manifests)"
fi

# Assert every expected platform has a child manifest whose digest resolves in
# the registry. Iterating expected platforms (not the index's own list) catches
# both missing children and children that 404 when pulled by digest.
missing=0
for platform in "${expected_platforms[@]}"; do
	[[ -z "$platform" ]] && continue
	# platform is os/arch or os/arch/variant (e.g. linux/amd64, linux/arm/v7).
	# OCI stores the variant separately (architecture: "arm", variant: "v7").
	os="${platform%%/*}"
	rest="${platform#*/}"
	arch="${rest%%/*}"
	variant=""
	[[ "$rest" == */* ]] && variant="${rest#*/}"

	digest=$(echo "$index_json" | jq -r \
		--arg os "$os" --arg arch "$arch" --arg variant "$variant" \
		'(.manifests // [])[]
		 | select(.platform.os == $os
		          and .platform.architecture == $arch
		          and ((.platform.variant // "") == $variant))
		 | .digest' | head -1)

	if [[ -z "$digest" || "$digest" == "null" ]]; then
		log_error "Index ${ref} has no child manifest for platform ${platform}"
		missing=$((missing + 1))
		continue
	fi

	# Registry pull-back by digest: a dangling child never resolves (even after
	# retries); a lagging-but-present child resolves once propagation catches up.
	if _inspect_ref "${REGISTRY}/${IMAGE_NAME}@${digest}"; then
		log_success "Child manifest resolves: ${platform} -> ${digest}"
	else
		log_error "Child manifest for ${platform} does not resolve in registry (dangling): ${digest}"
		missing=$((missing + 1))
	fi
done

if [[ "$missing" -gt 0 ]]; then
	die "Published image ${ref} is incomplete: ${missing} platform child manifest(s) missing or unresolvable"
fi

log_success "Published image verified: all platform children resolve in the registry"
