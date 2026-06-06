#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Verify digest-pinned container images still resolve in their registries
#
# Environment variables:
#   INPUT_SCAN_PATHS - Space-separated paths to scan (default: .github)

set -euo pipefail

: "${INPUT_SCAN_PATHS:=.github}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"

readonly DIGEST_PATTERN='@sha256:[0-9a-fA-F]{64}'
readonly MANIFEST_INSPECT_TIMEOUT_SECONDS="${MANIFEST_INSPECT_TIMEOUT_SECONDS:-30}"

failure_count=0
failure_details=()
checked_images=()

record_failure() {
	local detail="$1"
	failure_count=$((failure_count + 1))
	failure_details+=("  ${detail}")
}

image_already_checked() {
	local image="$1"
	local seen

	if [[ ${#checked_images[@]} -eq 0 ]]; then
		return 1
	fi

	for seen in "${checked_images[@]}"; do
		if [[ "$seen" == "$image" ]]; then
			return 0
		fi
	done
	return 1
}

normalize_extracted_image() {
	local image="$1"

	image="${image#docker://}"
	if [[ -z "$image" || ! "$image" =~ ${DIGEST_PATTERN}$ ]]; then
		return 1
	fi

	printf '%s' "$image"
}

queue_image_check() {
	local image="$1"

	if image_already_checked "$image"; then
		return 0
	fi
	checked_images+=("$image")
}

extract_images_from_file() {
	local file="$1"
	local match
	local image

	while IFS= read -r match; do
		[[ -z "$match" ]] && continue
		image="$(normalize_extracted_image "$match" || true)"
		[[ -z "$image" ]] && continue
		queue_image_check "$image"
	done < <(
		grep -vE '^[[:space:]]*#' "$file" 2>/dev/null |
			grep -oE "[A-Za-z0-9._:/-]+${DIGEST_PATTERN}" 2>/dev/null || true
	)
}

log_info "Scanning for digest-pinned container images..."
log_info "Scan paths: $INPUT_SCAN_PATHS"

read -ra scan_paths <<<"$INPUT_SCAN_PATHS"
for scan_path in "${scan_paths[@]}"; do
	if [[ ! -e "$scan_path" ]]; then
		log_warn "Scan path does not exist: $scan_path"
		continue
	fi

	if [[ -f "$scan_path" ]]; then
		extract_images_from_file "$scan_path"
		continue
	fi

	while IFS= read -r -d '' file; do
		extract_images_from_file "$file"
	done < <(
		find "$scan_path" -type f \( -name "*.yml" -o -name "*.yaml" \) -print0 2>/dev/null
	)
done

if [[ ${#checked_images[@]} -eq 0 ]]; then
	log_warn "No digest-pinned container images found"
	exit 0
fi

log_info "Found ${#checked_images[@]} unique digest-pinned image(s) to verify"

run_manifest_inspect() {
	local image="$1"

	if command -v timeout >/dev/null 2>&1; then
		timeout "$MANIFEST_INSPECT_TIMEOUT_SECONDS" docker manifest inspect "$image"
	else
		docker manifest inspect "$image"
	fi
}

verify_digest() {
	local image="$1"
	local attempt

	for attempt in 1 2 3; do
		if run_manifest_inspect "$image" >/dev/null 2>&1; then
			return 0
		fi
		if [[ $attempt -lt 3 ]]; then
			sleep 2
		fi
	done

	return 1
}

for image in "${checked_images[@]}"; do
	log_info "Checking ${image}"
	if verify_digest "$image"; then
		log_success "Digest resolves: ${image}"
	else
		record_failure "${image} (digest unreachable after 3 manifest inspect attempts)"
	fi
done

if [[ $failure_count -gt 0 ]]; then
	log_error "Found $failure_count unreachable digest pin(s):"
	for detail in "${failure_details[@]}"; do
		echo "$detail" >&2
	done
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf 'digest-failure=true\n' >>"$GITHUB_OUTPUT"
	fi
	exit 1
fi

log_success "All digest-pinned container images resolve in their registries"
