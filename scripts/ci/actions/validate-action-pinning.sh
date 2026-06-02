#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Validate GitHub Actions SHA pinning with Renovate version comments
#
# Environment variables:
#   INPUT_ENFORCE              - Fail if violations are found (true/false)
#   INPUT_ALLOW_TAG_EXCEPTIONS - Comma-separated action names allowed to use tag refs
#   INPUT_ALLOW_ORG_VERSIONS   - Deprecated alias for INPUT_ALLOW_TAG_EXCEPTIONS
#   INPUT_SCAN_PATHS           - Space-separated paths to scan for workflow files

set -euo pipefail

: "${INPUT_ENFORCE:=true}"
: "${INPUT_ALLOW_TAG_EXCEPTIONS:=}"
: "${INPUT_ALLOW_ORG_VERSIONS:=}"
: "${INPUT_SCAN_PATHS:=.github/workflows .github/actions}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

readonly VERSION_COMMENT_PATTERN='#[[:space:]]*v[0-9]+(\.[0-9]+)*'
readonly LGTM_CI_REPOSITORY_PATTERN='repository:[[:space:]]*['\''"]?lgtm-hq/lgtm-ci['\''"]?'
readonly LGTM_CI_RELEASE_COMMIT_SHA='d3736367191ddaf56c41804d2dd5174732ed2d2b'

# =============================================================================
# Parse allowed tag exceptions (exact action names)
# =============================================================================
TAG_EXCEPTIONS=()
if [[ -n "$INPUT_ALLOW_TAG_EXCEPTIONS" ]]; then
	IFS=',' read -ra TAG_EXCEPTIONS <<<"$INPUT_ALLOW_TAG_EXCEPTIONS"
elif [[ -n "$INPUT_ALLOW_ORG_VERSIONS" ]]; then
	log_warn "INPUT_ALLOW_ORG_VERSIONS is deprecated; use INPUT_ALLOW_TAG_EXCEPTIONS instead"
	IFS=',' read -ra TAG_EXCEPTIONS <<<"$INPUT_ALLOW_ORG_VERSIONS"
fi

for i in "${!TAG_EXCEPTIONS[@]}"; do
	TAG_EXCEPTIONS[i]="$(echo "${TAG_EXCEPTIONS[i]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
done

# =============================================================================
# Validation helpers
# =============================================================================
is_valid_sha() {
	local ref="$1"
	[[ "$ref" =~ ^[0-9a-fA-F]{40}$ ]]
}

readonly LGTM_CI_HARDEN_RUNNER_ACTION='lgtm-hq/lgtm-ci/.github/actions/harden-runner'
readonly LGTM_CI_HARDEN_RUNNER_COMMENT_PATTERN='# lgtm-ci harden-runner'

has_renovate_version_comment() {
	local line="$1"
	[[ "$line" =~ $VERSION_COMMENT_PATTERN ]]
}

has_lgtm_ci_harden_runner_pin_comment() {
	local line="$1"
	[[ "$line" =~ $LGTM_CI_HARDEN_RUNNER_COMMENT_PATTERN ]]
}

has_acceptable_pin_comment() {
	local action_name="$1"
	local line="$2"

	if has_renovate_version_comment "$line"; then
		return 0
	fi

	if [[ "$action_name" == "$LGTM_CI_HARDEN_RUNNER_ACTION" ]] &&
		has_lgtm_ci_harden_runner_pin_comment "$line"; then
		return 0
	fi

	return 1
}

is_tag_exception() {
	local action_name="$1"
	local exception

	if [[ ${#TAG_EXCEPTIONS[@]} -eq 0 ]]; then
		return 1
	fi

	for exception in "${TAG_EXCEPTIONS[@]}"; do
		if [[ -z "$exception" ]]; then
			continue
		fi
		if [[ "$action_name" == "$exception" ]]; then
			return 0
		fi
	done
	return 1
}

contains_template_expression() {
	local value="$1"
	# shellcheck disable=SC2016
	[[ "$value" == *'${{'* ]]
}

extract_literal_ref() {
	local line="$1"
	local key="$2"
	local value=""
	local field_pattern="^[[:space:]]*${key}:[[:space:]]*(.*)$"

	if [[ ! "$line" =~ $field_pattern ]]; then
		return 1
	fi

	value="${BASH_REMATCH[1]}"
	value="${value%%#*}"
	value="${value%"${value##*[![:space:]]}"}"
	value="${value#\"}"
	value="${value%\"}"
	value="${value#\'}"
	value="${value%\'}"

	if contains_template_expression "$value"; then
		return 1
	fi

	if ! is_valid_sha "$value"; then
		return 1
	fi

	printf '%s' "$value"
}

# =============================================================================
# Scan workflow files
# =============================================================================
offender_count=0
offender_details=()

record_offender() {
	local file="$1"
	local line_number="$2"
	local detail="$3"
	offender_count=$((offender_count + 1))
	offender_details+=("  ${file}:${line_number}: ${detail}")
}

log_info "Scanning for action pinning policy violations..."
log_info "Scan paths: $INPUT_SCAN_PATHS"
if [[ ${#TAG_EXCEPTIONS[@]} -gt 0 ]]; then
	log_info "Tag pin exceptions: ${TAG_EXCEPTIONS[*]}"
fi

yaml_files=()
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

scan_uses_line() {
	local file="$1"
	local line_number="$2"
	local line="$3"

	if ! [[ "$line" =~ ^[[:space:]]*-?[[:space:]]*uses:[[:space:]]* ]]; then
		return 0
	fi

	local action_ref
	action_ref="$(echo "$line" | sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//' | sed 's/#.*//' | sed 's/[[:space:]]*$//')"
	action_ref="$(echo "$action_ref" | sed -E "s/^['\"]//;s/['\"]$//")"

	if [[ -z "$action_ref" || "$action_ref" == ./* || "$action_ref" == docker://* ]]; then
		return 0
	fi

	# shellcheck disable=SC2016
	if contains_template_expression "$action_ref"; then
		return 0
	fi

	if [[ "$action_ref" != *@* ]]; then
		record_offender "$file" "$line_number" "${action_ref} (no version specified)"
		return 0
	fi

	local action_name="${action_ref%@*}"
	local version_ref="${action_ref##*@}"

	if is_valid_sha "$version_ref"; then
		if ! has_acceptable_pin_comment "$action_name" "$line"; then
			local hint="# vX.Y.Z"
			if [[ "$action_name" == "$LGTM_CI_HARDEN_RUNNER_ACTION" ]]; then
				hint="# vX.Y.Z\" or \"# lgtm-ci harden-runner"
			fi
			record_offender "$file" "$line_number" \
				"${action_ref} (SHA pin missing version comment; add \"${hint}\")"
		fi
		return 0
	fi

	if is_tag_exception "$action_name"; then
		return 0
	fi

	record_offender "$file" "$line_number" \
		"${action_ref} (tag pin not allowed; pin to SHA with \"# vX.Y.Z\" comment)"
}

scan_literal_sha_field() {
	local file="$1"
	local line_number="$2"
	local line="$3"
	local field_name="$4"
	local sha_ref

	if ! sha_ref="$(extract_literal_ref "$line" "$field_name")"; then
		return 0
	fi

	if has_renovate_version_comment "$line"; then
		return 0
	fi

	record_offender "$file" "$line_number" \
		"${field_name}: ${sha_ref} (SHA pin missing Renovate version comment; add \"# vX.Y.Z\")"
}

scan_file() {
	local file="$1"
	local line_number=0
	local in_lgtm_ci_checkout=false

	# shellcheck disable=SC2094
	while IFS= read -r line || [[ -n "$line" ]]; do
		line_number=$((line_number + 1))

		if [[ "$line" =~ ^jobs:[[:space:]]*$ ]] ||
			[[ "$line" =~ ^[[:space:]]{2}[a-zA-Z_][a-zA-Z0-9_-]*:[[:space:]]*($|[[:space:]]*#) ]]; then
			in_lgtm_ci_checkout=false
		fi

		if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(uses|name):[[:space:]]* ]]; then
			in_lgtm_ci_checkout=false
		fi

		if [[ "$line" =~ $LGTM_CI_REPOSITORY_PATTERN ]]; then
			in_lgtm_ci_checkout=true
		fi

		scan_uses_line "$file" "$line_number" "$line"
		scan_literal_sha_field "$file" "$line_number" "$line" "tooling-ref"

		if [[ "$in_lgtm_ci_checkout" == true ]]; then
			scan_literal_sha_field "$file" "$line_number" "$line" "ref"
		fi
	done <"$file"
}

for file in "${yaml_files[@]}"; do
	scan_file "$file"
done

# =============================================================================
# Report results
# =============================================================================
set_github_output "offenders" "$offender_count"

if [[ $offender_count -gt 0 ]]; then
	log_error "Found $offender_count action pinning violation(s):"
	for detail in "${offender_details[@]}"; do
		echo "$detail" >&2
	done
	echo "" >&2
	log_info "LGTM HQ policy: SHA-only pins with a trailing Renovate version comment."
	log_info "Example uses: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29 # v4"
	log_info "Example tooling-ref: '${LGTM_CI_RELEASE_COMMIT_SHA}' # v0.18.4"

	if [[ "$INPUT_ENFORCE" == "true" ]]; then
		exit 1
	fi
else
	log_success "All action references follow SHA pinning with Renovate version comments"
fi
