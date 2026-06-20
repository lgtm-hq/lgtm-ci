#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Clean untagged and ephemeral build-cache images from GHCR
#
# Environment variables:
#   PACKAGE_NAME          - GHCR package name to clean (required)
#   GITHUB_ORG            - GitHub org or user owning the package (required)
#   MIN_AGE_DAYS          - Minimum age in days before untagged deletion (default: 7)
#   KEEP_LATEST           - Always keep N most recent untagged versions (default: 0)
#   BUILD_CACHE_PR_AGE_DAYS - Minimum age before ephemeral tag deletion (default: 14)
#   PROTECT_REFERENCED    - Skip prune when referenced-digest collection fails (default: true)
#   PRUNE_BUILDCACHE      - Delete aged pr-*/mq-*/dispatch-* tags (default: true)
#   DRY_RUN               - Log only, no deletions (default: false)
#   GH_TOKEN              - GitHub token with packages:write scope

set -euo pipefail

: "${PACKAGE_NAME:?PACKAGE_NAME is required}"
: "${GITHUB_ORG:?GITHUB_ORG is required}"
: "${MIN_AGE_DAYS:=7}"
: "${KEEP_LATEST:=0}"
: "${BUILD_CACHE_PR_AGE_DAYS:=14}"
: "${PROTECT_REFERENCED:=true}"
: "${PRUNE_BUILDCACHE:=true}"
: "${DRY_RUN:=false}"

[[ "$MIN_AGE_DAYS" =~ ^[0-9]+$ ]] || {
	echo "ERROR: MIN_AGE_DAYS must be a non-negative integer, got: '$MIN_AGE_DAYS'" >&2
	exit 1
}
[[ "$KEEP_LATEST" =~ ^[0-9]+$ ]] || {
	echo "ERROR: KEEP_LATEST must be a non-negative integer, got: '$KEEP_LATEST'" >&2
	exit 1
}
[[ "$BUILD_CACHE_PR_AGE_DAYS" =~ ^[0-9]+$ ]] || {
	echo "ERROR: BUILD_CACHE_PR_AGE_DAYS must be a non-negative integer, got: '$BUILD_CACHE_PR_AGE_DAYS'" >&2
	exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/ghcr/registry.sh
source "$SCRIPT_DIR/../lib/ghcr/registry.sh"
# shellcheck source=../lib/ghcr/tags.sh
source "$SCRIPT_DIR/../lib/ghcr/tags.sh"

ghcr_fetch_versions() {
	all_versions=$(gh api --paginate \
		"/orgs/${GITHUB_ORG}/packages/container/${PACKAGE_NAME}/versions" \
		2>/dev/null | jq -s 'add // []') || {
		all_versions=$(gh api --paginate \
			"/users/${GITHUB_ORG}/packages/container/${PACKAGE_NAME}/versions" \
			2>/dev/null | jq -s 'add // []') || die "Failed to fetch package versions"
	}
}

ghcr_delete_version() {
	local version_id="$1"

	if [[ "$DRY_RUN" == "true" ]]; then
		return 0
	fi

	local err=""
	if err=$(gh api --method DELETE \
		"/orgs/${GITHUB_ORG}/packages/container/${PACKAGE_NAME}/versions/${version_id}" \
		2>&1); then
		return 0
	fi

	if err=$(gh api --method DELETE \
		"/users/${GITHUB_ORG}/packages/container/${PACKAGE_NAME}/versions/${version_id}" \
		2>&1); then
		return 0
	fi

	log_error "Failed to delete version ${version_id}: ${err}"
	return 1
}

# =============================================================================
# Fetch all package versions
# =============================================================================
log_info "Fetching versions for package: ${GITHUB_ORG}/${PACKAGE_NAME}"

ghcr_fetch_versions

total_count=$(echo "$all_versions" | jq 'length')
log_info "Found $total_count total version(s)"

# =============================================================================
# Referenced-digest protection
# =============================================================================
referenced_digests=()
referenced_complete=true

if [[ "$PROTECT_REFERENCED" == "true" && "$total_count" -gt 0 ]]; then
	registry_token=""
	if ! registry_token=$(ghcr_exchange_registry_token \
		"$GITHUB_ORG" \
		"$PACKAGE_NAME" \
		"${GH_TOKEN:-}"); then
		log_warning "Skipping prune for ${PACKAGE_NAME} (registry auth failed; cannot compute reference protection)"
		add_github_summary "## GHCR Cleanup"
		add_github_summary ""
		add_github_summary "| Property | Value |"
		add_github_summary "| -------- | ----- |"
		add_github_summary "| Package | \`${GITHUB_ORG}/${PACKAGE_NAME}\` |"
		add_github_summary "| Status | :warning: Skipped (registry auth failed) |"
		exit 0
	fi

	referenced_digests_text=""
	ghcr_collect_referenced_digests \
		"$GITHUB_ORG" \
		"$PACKAGE_NAME" \
		"$all_versions" \
		"$registry_token" \
		referenced_complete \
		referenced_digests_text

	if [[ "$referenced_complete" != "true" ]]; then
		log_warning "Skipping prune for ${PACKAGE_NAME} (referenced-digest collection incomplete)"
		add_github_summary "## GHCR Cleanup"
		add_github_summary ""
		add_github_summary "| Property | Value |"
		add_github_summary "| -------- | ----- |"
		add_github_summary "| Package | \`${GITHUB_ORG}/${PACKAGE_NAME}\` |"
		add_github_summary "| Status | :warning: Skipped (incomplete reference protection) |"
		exit 0
	fi

	if [[ -n "$referenced_digests_text" ]]; then
		while IFS= read -r digest; do
			[[ -n "$digest" ]] && referenced_digests+=("$digest")
		done <<<"$referenced_digests_text"
		log_info "Collected ${#referenced_digests[@]} referenced digest(s) for protection"
	fi
fi

# =============================================================================
# Filter to untagged versions eligible for deletion
# Uses updated_at for age comparison to avoid deleting recently refreshed
# versions whose created_at predates the cutoff.
# =============================================================================
cutoff_date=$(date -u -v-"${MIN_AGE_DAYS}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
	date -u -d "${MIN_AGE_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
	die "Could not compute cutoff date")

log_info "Cutoff date: $cutoff_date (older than $MIN_AGE_DAYS days)"

if ((${#referenced_digests[@]} > 0)); then
	refs_json=$(printf '%s\n' "${referenced_digests[@]}" | jq -R . | jq -s .)
else
	refs_json='[]'
fi

eligible_versions=$(echo "$all_versions" | jq --arg cutoff "$cutoff_date" --argjson refs "$refs_json" '
	def version_time: .updated_at // .created_at // "";
	[ .[] |
	  select((.metadata.container.tags | length) == 0) |
	  select(version_time < $cutoff) |
	  select(.name as $n | ($refs | index($n) | not))
	] | sort_by(.updated_at // .created_at) | reverse
')

eligible_count=$(echo "$eligible_versions" | jq 'length')
log_info "Found $eligible_count untagged version(s) older than $MIN_AGE_DAYS days"

# =============================================================================
# Apply keep-latest threshold
# =============================================================================
if [[ "$eligible_count" -le "$KEEP_LATEST" ]]; then
	to_delete=$(echo '[]' | jq '.')
	delete_count=0
else
	to_delete=$(echo "$eligible_versions" | jq --argjson skip "$KEEP_LATEST" '.[$skip:]')
	delete_count=$(echo "$to_delete" | jq 'length')
	actual_kept=$((eligible_count - delete_count))
	log_info "Will delete $delete_count untagged version(s) (keeping $actual_kept most recent untagged)"
fi

# =============================================================================
# Build-cache ephemeral tag pruning
# Uses updated_at for age comparison to avoid deleting recently refreshed
# cache entries whose created_at predates the cutoff.
# =============================================================================
buildcache_delete_count=0
buildcache_to_delete='[]'

if [[ "$PRUNE_BUILDCACHE" == "true" ]]; then
	buildcache_cutoff=$(date -u -v-"${BUILD_CACHE_PR_AGE_DAYS}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		date -u -d "${BUILD_CACHE_PR_AGE_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		die "Could not compute buildcache cutoff date")

	buildcache_candidates=$(echo "$all_versions" | jq --arg cutoff "$buildcache_cutoff" --argjson refs "$refs_json" '
		def version_time: .updated_at // .created_at // "";
		[ .[] |
		  select((.metadata.container.tags | length) > 0) |
		  select(version_time < $cutoff) |
		  select(.name as $n | ($refs | index($n) | not))
		]
	')

	buildcache_ids=()
	while IFS=$'\t' read -r version_id tags_json version_name updated_at; do
		if ghcr_is_ephemeral_only_tagged "$tags_json"; then
			buildcache_ids+=("$version_id")
			log_info "Buildcache eligible: version $version_id ($version_name, tags=$(jq -r 'join(",")' <<<"$tags_json"), updated $updated_at)"
		fi
	done < <(
		echo "$buildcache_candidates" | jq -r '.[] | [.id, (.metadata.container.tags | @json), .name, (.updated_at // .created_at)] | @tsv'
	)

	if ((${#buildcache_ids[@]} > 0)); then
		buildcache_to_delete=$(printf '%s\n' "${buildcache_ids[@]}" | jq -R . | jq -s .)
		buildcache_delete_count=${#buildcache_ids[@]}
		log_info "Will delete $buildcache_delete_count ephemeral build-cache version(s)"
	fi
fi

if [[ "$delete_count" -eq 0 && "$buildcache_delete_count" -eq 0 ]]; then
	log_info "nothing to delete for ${PACKAGE_NAME}"
	add_github_summary "## GHCR Cleanup"
	add_github_summary ""
	add_github_summary "| Property | Value |"
	add_github_summary "| -------- | ----- |"
	add_github_summary "| Package | \`${GITHUB_ORG}/${PACKAGE_NAME}\` |"
	add_github_summary "| Total versions | $total_count |"
	add_github_summary "| Eligible untagged | $eligible_count |"
	add_github_summary "| Eligible build-cache | $buildcache_delete_count |"
	add_github_summary "| Deleted | 0 |"
	add_github_summary "| Status | :white_check_mark: Nothing to clean |"
	exit 0
fi

# =============================================================================
# Delete versions
# =============================================================================
deleted=0
failed=0

while IFS=$'\t' read -r version_id version_name updated_at; do
	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "[dry-run] Would delete untagged version $version_id ($version_name, updated $updated_at)"
		deleted=$((deleted + 1))
		continue
	fi

	if ghcr_delete_version "$version_id"; then
		log_success "Deleted untagged version $version_id ($version_name, updated $updated_at)"
		deleted=$((deleted + 1))
	else
		failed=$((failed + 1))
	fi
done < <(echo "$to_delete" | jq -r '.[] | [.id, .name, (.updated_at // .created_at)] | @tsv')

while IFS= read -r version_id; do
	[[ -z "$version_id" ]] && continue
	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "[dry-run] Would delete build-cache version $version_id"
		deleted=$((deleted + 1))
		continue
	fi

	if ghcr_delete_version "$version_id"; then
		log_success "Deleted build-cache version $version_id"
		deleted=$((deleted + 1))
	else
		failed=$((failed + 1))
	fi
done < <(echo "$buildcache_to_delete" | jq -r '.[]')

# =============================================================================
# Summary
# =============================================================================
if [[ "$DRY_RUN" == "true" ]]; then
	log_info "Dry run complete: $deleted version(s) would be deleted"
else
	log_success "Cleanup complete: $deleted deleted, $failed failed"
fi

actual_kept=$((eligible_count < KEEP_LATEST ? eligible_count : KEEP_LATEST))

add_github_summary "## GHCR Cleanup"
add_github_summary ""
add_github_summary "| Property | Value |"
add_github_summary "| -------- | ----- |"
add_github_summary "| Package | \`${GITHUB_ORG}/${PACKAGE_NAME}\` |"
add_github_summary "| Total versions | $total_count |"
add_github_summary "| Eligible untagged | $eligible_count |"
add_github_summary "| Eligible build-cache | $buildcache_delete_count |"
add_github_summary "| Kept (most recent untagged) | $actual_kept |"
add_github_summary "| Referenced digests protected | ${#referenced_digests[@]} |"

if [[ "$DRY_RUN" == "true" ]]; then
	add_github_summary "| Would delete | $deleted |"
	add_github_summary "| Status | :construction: Dry Run |"
else
	add_github_summary "| Deleted | $deleted |"
	if [[ $failed -gt 0 ]]; then
		add_github_summary "| Failed | $failed |"
		add_github_summary "| Status | :warning: Completed with errors |"
	else
		add_github_summary "| Status | :white_check_mark: Complete |"
	fi
fi

if [[ $failed -gt 0 ]]; then
	exit 1
fi
