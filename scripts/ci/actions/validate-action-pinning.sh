#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Validate that GitHub Actions references are pinned to commit SHAs
#
# Environment variables:
#   INPUT_ENFORCE           - Fail if non-pinned actions are found (true/false)
#   INPUT_ALLOW_ORG_VERSIONS - Comma-separated org/repo prefixes allowed to use version tags
#   INPUT_SCAN_PATHS        - Space-separated paths to scan for workflow files

set -euo pipefail

: "${INPUT_ENFORCE:=true}"
: "${INPUT_ALLOW_ORG_VERSIONS:=}"
: "${INPUT_SCAN_PATHS:=.github/workflows .github/actions}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

# =============================================================================
# Parse allowed org prefixes
# =============================================================================
ALLOWED_PREFIXES=()
if [[ -n "$INPUT_ALLOW_ORG_VERSIONS" ]]; then
	IFS=',' read -ra ALLOWED_PREFIXES <<<"$INPUT_ALLOW_ORG_VERSIONS"
	# Trim whitespace from each prefix
	for i in "${!ALLOWED_PREFIXES[@]}"; do
		ALLOWED_PREFIXES[i]="$(echo "${ALLOWED_PREFIXES[i]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
	done
fi

# =============================================================================
# Check if an action reference is allowed to use version tags
# =============================================================================
is_allowed_prefix() {
	local action_ref="$1"
	for prefix in "${ALLOWED_PREFIXES[@]}"; do
		if [[ -z "$prefix" ]]; then
			continue
		fi
		if [[ "$action_ref" == "$prefix" || "$action_ref" == "$prefix"/* ]]; then
			return 0
		fi
	done
	return 1
}

# =============================================================================
# Check if a version ref is a valid SHA (40-char hex)
# =============================================================================
is_valid_sha() {
	local ref="$1"
	[[ "$ref" =~ ^[0-9a-fA-F]{40}$ ]]
}

# =============================================================================
# Scan workflow files for unpinned action references
# =============================================================================
offender_count=0
offender_details=()

log_info "Scanning for unpinned action references..."
log_info "Scan paths: $INPUT_SCAN_PATHS"
if [[ ${#ALLOWED_PREFIXES[@]} -gt 0 ]]; then
	log_info "Allowed org prefixes: ${ALLOWED_PREFIXES[*]}"
fi

# Collect YAML files from all scan paths
yaml_files=()
# Split space-separated paths into array for safe iteration
read -ra scan_paths <<<"$INPUT_SCAN_PATHS"
for scan_path in "${scan_paths[@]}"; do
	if [[ ! -d "$scan_path" ]]; then
		log_warn "Scan path does not exist: $scan_path"
		continue
	fi
	while IFS= read -r -d '' file; do
		yaml_files+=("$file")
	done < <(find "$scan_path" -type f \( -name "*.yml" -o -name "*.yaml" \) -print0 2>/dev/null)
done

if [[ ${#yaml_files[@]} -eq 0 ]]; then
	log_warn "No workflow files found in scan paths"
	set_github_output "offenders" "0"
	exit 0
fi

log_info "Found ${#yaml_files[@]} workflow file(s) to scan"

for file in "${yaml_files[@]}"; do
	line_number=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		line_number=$((line_number + 1))

		# Match lines containing "uses:" (with optional leading whitespace/dash)
		if ! [[ "$line" =~ ^[[:space:]]*-?[[:space:]]*uses:[[:space:]]* ]]; then
			continue
		fi

		# Extract the action reference (remove "uses:" prefix and inline comments)
		action_ref="$(echo "$line" | sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//' | sed 's/#.*//' | sed 's/[[:space:]]*$//')"

		# Remove surrounding quotes if present
		action_ref="$(echo "$action_ref" | sed -E "s/^['\"]//;s/['\"]$//")"

		# Skip empty references
		if [[ -z "$action_ref" ]]; then
			continue
		fi

		# Skip local action references (./)
		if [[ "$action_ref" == ./* ]]; then
			continue
		fi

		# Skip docker:// references
		if [[ "$action_ref" == docker://* ]]; then
			continue
		fi

		# Skip template expressions (${{ }}) — single quotes are intentional
		# shellcheck disable=SC2016
		if [[ "$action_ref" == *'${'* ]]; then
			continue
		fi

		# Parse action and version: org/repo@version or org/repo/path@version
		if [[ "$action_ref" != *@* ]]; then
			# No @ sign means no version pinning at all
			offender_count=$((offender_count + 1))
			offender_details+=("  ${file}:${line_number}: ${action_ref} (no version specified)")
			continue
		fi

		action_name="${action_ref%@*}"
		version_ref="${action_ref##*@}"

		# Check if the version ref is a valid 40-char SHA
		if is_valid_sha "$version_ref"; then
			continue
		fi

		# Check if the action is from an allowed org prefix
		if [[ ${#ALLOWED_PREFIXES[@]} -gt 0 ]] && is_allowed_prefix "$action_name"; then
			continue
		fi

		# Not pinned to SHA and not in allow list
		offender_count=$((offender_count + 1))
		offender_details+=("  ${file}:${line_number}: ${action_ref}")
	done <"$file"
done

# =============================================================================
# Report results
# =============================================================================
set_github_output "offenders" "$offender_count"

if [[ $offender_count -gt 0 ]]; then
	log_error "Found $offender_count unpinned action reference(s):"
	for detail in "${offender_details[@]}"; do
		echo "$detail" >&2
	done
	echo "" >&2
	log_info "Pin actions to full commit SHAs for security."
	log_info "Example: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29 # v4"

	if [[ "$INPUT_ENFORCE" == "true" ]]; then
		exit 1
	fi
else
	log_success "All action references are properly pinned"
fi
