#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Convert comma-separated tags to metadata-action format (build-docker STEP: parse-tags)
#
# Optional environment variables:
#   INPUT_TAGS - Comma-separated tags for docker/metadata-action
#
# Outputs:
#   tags - Newline-separated `type=raw,value=<tag>` entries

set -euo pipefail

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/docker.sh
source "$SCRIPT_DIR/../../lib/docker.sh"

# Convert comma-separated tags to metadata-action format for docker/metadata-action
: "${INPUT_TAGS:=}"

if [[ -z "$INPUT_TAGS" ]]; then
	set_github_output "tags" ""
	exit 0
fi

# Convert comma-separated tags to metadata-action format
# Trim whitespace and filter empty entries
tags_list=""
IFS=',' read -ra tag_array <<<"$INPUT_TAGS"
for tag in "${tag_array[@]}"; do
	tag=$(echo "$tag" | xargs) # Trim whitespace
	if [[ -n "$tag" ]]; then
		tags_list="${tags_list}type=raw,value=${tag}"$'\n'
	fi
done

# Output using heredoc for multiline
set_github_output_multiline "tags" "$tags_list"

log_info "Parsed tags for metadata-action"
