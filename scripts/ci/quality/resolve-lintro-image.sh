#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve the canonical lintro image reference from repository CI files
#
# Reads digest-pinned ghcr.io/lgtm-hq/py-lintro references from the workflow and
# composite action defaults that must stay in sync with pyproject.toml.
#
# Optional environment variables:
#   INPUT_LINTRO_IMAGE   - Use this image instead of resolving from CI files
#   LINTRO_IMAGE_SOURCES - Space-separated files to scan (default below)
#   GITHUB_OUTPUT        - When set, writes image=<value> for workflow steps

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"

readonly DIGEST_PATTERN='ghcr\.io/lgtm-hq/py-lintro@sha256:[0-9a-fA-F]{64}'

if [[ -n "${INPUT_LINTRO_IMAGE:-}" ]]; then
	if [[ ! "$INPUT_LINTRO_IMAGE" =~ ^${DIGEST_PATTERN}$ ]]; then
		log_error "INPUT_LINTRO_IMAGE must be a digest-pinned ghcr.io/lgtm-hq/py-lintro reference"
		exit 1
	fi
	log_info "Using provided lintro image override"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf 'image=%s\n' "$INPUT_LINTRO_IMAGE" >>"$GITHUB_OUTPUT"
	else
		printf '%s' "$INPUT_LINTRO_IMAGE"
	fi
	exit 0
fi
readonly DEFAULT_SOURCES=(
	".github/workflows/reusable-quality-lint.yml"
	".github/actions/run-quality/action.yml"
)

extract_image_from_file() {
	local file="$1"
	local image=""

	if [[ ! -f "$file" ]]; then
		log_error "Lintro image source file not found: $file"
		return 1
	fi

	image="$(awk -v pattern="$DIGEST_PATTERN" '
		function emit() {
			print substr($0, RSTART, RLENGTH)
			exit
		}
		/^[[:space:]]*#/ {
			next
		}
		/lintro-image:/ {
			capture = 1
			default_capture = 0
			match($0, /^[[:space:]]*/)
			lintro_indent = RLENGTH
			if (match($0, pattern)) {
				emit()
			}
			next
		}
		capture {
			match($0, /^[[:space:]]*/)
			if (RLENGTH <= lintro_indent && $0 ~ /^[[:space:]]*[a-z0-9-]+:/ && $0 !~ /lintro-image:/) {
				capture = 0
				default_capture = 0
				next
			}
			if ($0 ~ /default:/) {
				match($0, /^[[:space:]]*/)
				default_indent = RLENGTH
				if (match($0, pattern)) {
					emit()
				} else {
					default_capture = 1
				}
				next
			}
			if (default_capture) {
				match($0, /^[[:space:]]*/)
				if (RLENGTH <= default_indent && $0 ~ /:/ && $0 !~ /^[[:space:]]*#/) {
					default_capture = 0
					next
				}
				if (match($0, pattern)) {
					emit()
				}
			}
		}
	' "$file")"

	if [[ -z "$image" ]]; then
		log_error "No digest-pinned lintro image found in: $file"
		return 1
	fi

	printf '%s' "$image"
}

sources=()
if [[ -n "${LINTRO_IMAGE_SOURCES:-}" ]]; then
	read -ra sources <<<"$LINTRO_IMAGE_SOURCES"
else
	sources=("${DEFAULT_SOURCES[@]}")
fi

if [[ ${#sources[@]} -eq 0 ]]; then
	log_error "No lintro image sources specified in LINTRO_IMAGE_SOURCES"
	exit 1
fi

canonical_image=""
for source in "${sources[@]}"; do
	image="$(extract_image_from_file "$source")" || exit 1
	if [[ -z "$canonical_image" ]]; then
		canonical_image="$image"
	elif [[ "$canonical_image" != "$image" ]]; then
		log_error "Lintro image definitions disagree between CI files"
		log_error "Expected a single digest pin across: ${sources[*]}"
		exit 1
	fi
done

log_info "Resolved lintro image: $canonical_image"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	printf 'image=%s\n' "$canonical_image" >>"$GITHUB_OUTPUT"
else
	printf '%s' "$canonical_image"
fi
