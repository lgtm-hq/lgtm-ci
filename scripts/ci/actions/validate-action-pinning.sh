#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Validate GitHub Actions SHA pinning with Renovate version comments
#
# Environment variables:
#   INPUT_ENFORCE              - Fail if violations are found (true/false)
#   INPUT_ALLOW_TAG_EXCEPTIONS - Comma-separated action names allowed to use tag refs
#   INPUT_ALLOW_ORG_VERSIONS   - Deprecated alias for INPUT_ALLOW_TAG_EXCEPTIONS
#   INPUT_SCAN_PATHS           - Space-separated paths to scan for workflow files
#   INPUT_VERIFY_TAGS          - Verify Renovate version comments match pinned SHAs
#   INPUT_AUDIT_TRANSITIVE     - Warn on mutable tag refs in nested composite actions

set -euo pipefail

: "${INPUT_ENFORCE:=true}"
: "${INPUT_ALLOW_TAG_EXCEPTIONS:=}"
: "${INPUT_ALLOW_ORG_VERSIONS:=}"
: "${INPUT_SCAN_PATHS:=.github/workflows .github/actions}"
: "${INPUT_VERIFY_TAGS:=false}"
: "${INPUT_AUDIT_TRANSITIVE:=false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

readonly VERSION_COMMENT_PATTERN='#[[:space:]]*v[0-9]+(\.[0-9]+)*([-.][a-zA-Z0-9.]+)*'
readonly LGTM_CI_REPOSITORY_PATTERN='repository:[[:space:]]*['\''"]?lgtm-hq/lgtm-ci['\''"]?'
readonly LGTM_CI_REPO_SLUG='lgtm-hq/lgtm-ci'
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

normalize_sha() {
	local sha="$1"
	printf '%s' "$sha" | tr '[:upper:]' '[:lower:]'
}

extract_version_tag_from_line() {
	local line="$1"
	local tag=""

	if [[ ! "$line" =~ $VERSION_COMMENT_PATTERN ]]; then
		return 1
	fi

	tag="$(echo "$line" | sed -E 's/.*#[[:space:]]*(v[0-9]+(\.[0-9]+)*([-.][a-zA-Z0-9.]+)*).*/\1/')"
	if [[ -z "$tag" ]]; then
		return 1
	fi

	printf '%s' "$tag"
}

parse_action_repo() {
	local action_name="$1"
	local org repo subpath remainder

	org="${action_name%%/*}"
	remainder="${action_name#*/}"
	repo="${remainder%%/*}"
	subpath=""

	if [[ "$remainder" == */* ]]; then
		subpath="${remainder#*/}"
	fi

	printf '%s %s %s' "$org" "$repo" "$subpath"
}

cache_get() {
	local key="$1"
	local i

	for i in "${!TAG_SHA_CACHE_KEYS[@]}"; do
		if [[ "${TAG_SHA_CACHE_KEYS[i]}" == "$key" ]]; then
			printf '%s' "${TAG_SHA_CACHE_VALUES[i]}"
			return 0
		fi
	done
	return 1
}

cache_set() {
	local key="$1"
	local value="$2"

	TAG_SHA_CACHE_KEYS+=("$key")
	TAG_SHA_CACHE_VALUES+=("$value")
}

transitive_audit_seen() {
	local cache_key="$1"
	local seen

	if [[ ${#TRANSITIVE_AUDIT_KEYS[@]} -eq 0 ]]; then
		return 1
	fi

	for seen in "${TRANSITIVE_AUDIT_KEYS[@]}"; do
		if [[ "$seen" == "$cache_key" ]]; then
			return 0
		fi
	done
	return 1
}

# =============================================================================
# Scan workflow files
# =============================================================================
TAG_SHA_CACHE_KEYS=()
TAG_SHA_CACHE_VALUES=()
RESOLVED_TAG_SHA=""
TRANSITIVE_AUDIT_KEYS=()

offender_count=0
offender_details=()
warn_count=0
warn_details=()
PIN_VERIFY_QUEUE=()
TRANSITIVE_AUDIT_QUEUE=()

record_offender() {
	local file="$1"
	local line_number="$2"
	local detail="$3"
	offender_count=$((offender_count + 1))
	offender_details+=("  ${file}:${line_number}: ${detail}")
}

record_warning() {
	local detail="$1"
	warn_count=$((warn_count + 1))
	warn_details+=("  ${detail}")
}

queue_pin_verification() {
	local file="$1"
	local line_number="$2"
	local action_name="$3"
	local pinned_sha="$4"
	local line="$5"
	local tag

	if ! tag="$(extract_version_tag_from_line "$line")"; then
		return 0
	fi

	PIN_VERIFY_QUEUE+=("${file}|${line_number}|${action_name}|${pinned_sha}|${tag}")
}

queue_transitive_audit() {
	local action_name="$1"
	local pinned_sha="$2"
	local cache_key="${action_name}@${pinned_sha}"

	if transitive_audit_seen "$cache_key"; then
		return 0
	fi

	TRANSITIVE_AUDIT_KEYS+=("$cache_key")
	TRANSITIVE_AUDIT_QUEUE+=("${action_name}|${pinned_sha}")
}

resolve_tag_to_sha() {
	local org="$1"
	local repo="$2"
	local tag="$3"
	local cache_key="${org}/${repo}@${tag}"
	local sha

	if sha="$(cache_get "$cache_key")"; then
		RESOLVED_TAG_SHA="$sha"
		return 0
	fi

	if ! sha="$(gh api "repos/${org}/${repo}/commits/${tag}" --jq '.sha' 2>/dev/null)"; then
		RESOLVED_TAG_SHA=""
		return 1
	fi

	if [[ -z "$sha" || "$sha" == "null" ]]; then
		RESOLVED_TAG_SHA=""
		return 1
	fi

	sha="$(normalize_sha "$sha")"
	cache_set "$cache_key" "$sha"
	RESOLVED_TAG_SHA="$sha"
	return 0
}

verify_queued_pins() {
	local entry file line_number action_name pinned_sha tag org repo _subpath resolved_sha

	for entry in "${PIN_VERIFY_QUEUE[@]}"; do
		IFS='|' read -r file line_number action_name pinned_sha tag <<<"$entry"
		read -r org repo _subpath <<<"$(parse_action_repo "$action_name")"

		if ! resolve_tag_to_sha "$org" "$repo" "$tag"; then
			record_warning \
				"${file}:${line_number}: ${action_name}@${pinned_sha} (could not resolve ${tag} via GitHub API)"
			continue
		fi

		resolved_sha="$RESOLVED_TAG_SHA"

		if [[ "$(normalize_sha "$pinned_sha")" != "$resolved_sha" ]]; then
			record_offender "$file" "$line_number" \
				"${action_name}@${pinned_sha} (pinned SHA does not match ${tag}; resolved ${resolved_sha})"
		fi
	done
}

fetch_action_yaml_content_at_path() {
	local org="$1"
	local repo="$2"
	local sha="$3"
	local api_path="$4"
	local content

	if ! content="$(gh api "repos/${org}/${repo}/contents/${api_path}?ref=${sha}" --jq '.content' 2>/dev/null)"; then
		return 1
	fi

	if [[ -z "$content" || "$content" == "null" ]]; then
		return 1
	fi

	printf '%s' "$content" | base64 -d
}

fetch_action_yaml_at_sha() {
	local org="$1"
	local repo="$2"
	local sha="$3"
	local subpath="$4"
	local manifest_name manifest_path

	for manifest_name in action.yml action.yaml; do
		manifest_path="$manifest_name"
		if [[ -n "$subpath" ]]; then
			manifest_path="${subpath}/${manifest_name}"
		fi

		if fetch_action_yaml_content_at_path "$org" "$repo" "$sha" "$manifest_path"; then
			return 0
		fi
	done

	return 1
}

is_reusable_workflow_ref() {
	local subpath="$1"

	[[ "$subpath" == *".github/workflows/"* ]] ||
		[[ "$subpath" == *.yml ]] ||
		[[ "$subpath" == *.yaml ]]
}

audit_nested_uses_line() {
	local parent_action="$1"
	local nested_line="$2"
	local action_ref action_name version_ref

	if ! [[ "$nested_line" =~ ^[[:space:]]*-?[[:space:]]*uses:[[:space:]]* ]]; then
		return 0
	fi

	action_ref="$(echo "$nested_line" | sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//' | sed 's/#.*//' | sed 's/[[:space:]]*$//')"
	action_ref="$(echo "$action_ref" | sed -E "s/^['\"]//;s/['\"]$//")"

	if [[ -z "$action_ref" || "$action_ref" == ./* || "$action_ref" == docker://* ]]; then
		return 0
	fi

	if contains_template_expression "$action_ref"; then
		return 0
	fi

	if [[ "$action_ref" != *@* ]]; then
		record_warning "${parent_action}: nested ${action_ref} (no version specified)"
		return 0
	fi

	action_name="${action_ref%@*}"
	version_ref="${action_ref##*@}"

	if is_valid_sha "$version_ref"; then
		return 0
	fi

	if is_tag_exception "$action_name"; then
		return 0
	fi

	record_warning \
		"${parent_action}: nested ${action_ref} uses mutable tag ref (upstream tag deletion risk)"
}

audit_transitive_dependencies() {
	local entry action_name pinned_sha org repo subpath action_yaml line_number line

	for entry in "${TRANSITIVE_AUDIT_QUEUE[@]}"; do
		IFS='|' read -r action_name pinned_sha <<<"$entry"
		read -r org repo subpath <<<"$(parse_action_repo "$action_name")"

		if is_reusable_workflow_ref "$subpath"; then
			continue
		fi

		if ! action_yaml="$(fetch_action_yaml_at_sha "$org" "$repo" "$pinned_sha" "$subpath")"; then
			record_warning \
				"${action_name}@${pinned_sha}: could not fetch composite action manifest for transitive audit"
			continue
		fi

		if ! grep -qE 'using:[[:space:]]*("composite"|'\''composite'\''|composite)' <<<"$action_yaml"; then
			continue
		fi

		line_number=0
		while IFS= read -r line || [[ -n "$line" ]]; do
			line_number=$((line_number + 1))
			audit_nested_uses_line "${action_name}@${pinned_sha}" "$line"
		done <<<"$action_yaml"
	done
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
	set_github_output "warnings" "0"
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
		else
			if [[ "$INPUT_VERIFY_TAGS" == "true" ]] && has_renovate_version_comment "$line"; then
				queue_pin_verification "$file" "$line_number" "$action_name" "$version_ref" "$line"
			fi
			if [[ "$INPUT_AUDIT_TRANSITIVE" == "true" ]]; then
				queue_transitive_audit "$action_name" "$version_ref"
			fi
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
		if [[ "$INPUT_VERIFY_TAGS" == "true" ]]; then
			# tooling-ref/ref SHAs always target the lgtm-ci repository itself.
			queue_pin_verification "$file" "$line_number" "$LGTM_CI_REPO_SLUG" "$sha_ref" "$line"
		fi
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

if [[ "$INPUT_VERIFY_TAGS" == "true" && ${#PIN_VERIFY_QUEUE[@]} -gt 0 ]]; then
	log_info "Verifying ${#PIN_VERIFY_QUEUE[@]} Renovate version comment(s) against pinned SHAs..."
	verify_queued_pins
fi

if [[ "$INPUT_AUDIT_TRANSITIVE" == "true" && ${#TRANSITIVE_AUDIT_QUEUE[@]} -gt 0 ]]; then
	log_info "Auditing transitive action references in ${#TRANSITIVE_AUDIT_QUEUE[@]} composite action(s)..."
	audit_transitive_dependencies
fi

# =============================================================================
# Report results
# =============================================================================
set_github_output "offenders" "$offender_count"
set_github_output "warnings" "$warn_count"

if [[ $offender_count -gt 0 ]]; then
	log_error "Found $offender_count action pinning violation(s):"
	for detail in "${offender_details[@]}"; do
		echo "$detail" >&2
	done
	echo "" >&2
	log_info "LGTM HQ policy: SHA-only pins with a trailing Renovate version comment."
	log_info "Example uses: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29 # v4"
	log_info "Example tooling-ref: '${LGTM_CI_RELEASE_COMMIT_SHA}' # v0.18.4"

elif [[ $warn_count -eq 0 ]]; then
	log_success "All action references follow SHA pinning with Renovate version comments"
fi

if [[ $warn_count -gt 0 ]]; then
	log_warn "Found $warn_count verification warning(s):"
	for detail in "${warn_details[@]}"; do
		echo "$detail" >&2
	done
fi

if [[ $offender_count -gt 0 && "$INPUT_ENFORCE" == "true" ]]; then
	exit 1
fi
