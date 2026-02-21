#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Clean untagged container images from GitHub Container Registry
#
# Environment variables:
#   PACKAGE_NAME  - GHCR package name to clean (required)
#   GITHUB_ORG    - GitHub org or user owning the package (required)
#   MIN_AGE_DAYS  - Minimum age in days before deletion (default: 7)
#   KEEP_LATEST   - Always keep N most recent untagged versions (default: 5)
#   DRY_RUN       - Log only, no deletions (default: false)
#   GH_TOKEN      - GitHub token with packages:write scope

set -euo pipefail

: "${PACKAGE_NAME:?PACKAGE_NAME is required}"
: "${GITHUB_ORG:?GITHUB_ORG is required}"
: "${MIN_AGE_DAYS:=7}"
: "${KEEP_LATEST:=5}"
: "${DRY_RUN:=false}"

[[ "$MIN_AGE_DAYS" =~ ^[0-9]+$ ]] || {
	echo "ERROR: MIN_AGE_DAYS must be a non-negative integer, got: '$MIN_AGE_DAYS'" >&2
	exit 1
}
[[ "$KEEP_LATEST" =~ ^[0-9]+$ ]] || {
	echo "ERROR: KEEP_LATEST must be a non-negative integer, got: '$KEEP_LATEST'" >&2
	exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

# =============================================================================
# Fetch all package versions
# =============================================================================
log_info "Fetching versions for package: ${GITHUB_ORG}/${PACKAGE_NAME}"

all_versions=$(gh api --paginate \
	"/orgs/${GITHUB_ORG}/packages/container/${PACKAGE_NAME}/versions" \
	2>/dev/null) || {
	# Try user endpoint if org endpoint fails
	all_versions=$(gh api --paginate \
		"/users/${GITHUB_ORG}/packages/container/${PACKAGE_NAME}/versions" \
		2>/dev/null) || die "Failed to fetch package versions"
}

total_count=$(echo "$all_versions" | jq 'length')
log_info "Found $total_count total version(s)"

# =============================================================================
# Filter to untagged versions
# =============================================================================
cutoff_date=$(date -u -v-"${MIN_AGE_DAYS}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
	date -u -d "${MIN_AGE_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
	die "Could not compute cutoff date")

log_info "Cutoff date: $cutoff_date (older than $MIN_AGE_DAYS days)"

# Get untagged versions older than cutoff, sorted newest first
eligible_versions=$(echo "$all_versions" | jq --arg cutoff "$cutoff_date" '
	[ .[] |
	  select(
	    (.metadata.container.tags | length) == 0 and
	    .updated_at < $cutoff
	  )
	] | sort_by(.updated_at) | reverse
')

eligible_count=$(echo "$eligible_versions" | jq 'length')
log_info "Found $eligible_count untagged version(s) older than $MIN_AGE_DAYS days"

# =============================================================================
# Apply keep-latest threshold
# =============================================================================
if [[ "$eligible_count" -le "$KEEP_LATEST" ]]; then
	log_info "All $eligible_count eligible version(s) fall within keep-latest=$KEEP_LATEST — nothing to delete"
	add_github_summary "## GHCR Cleanup"
	add_github_summary ""
	add_github_summary "| Property | Value |"
	add_github_summary "| -------- | ----- |"
	add_github_summary "| Package | \`${GITHUB_ORG}/${PACKAGE_NAME}\` |"
	add_github_summary "| Total versions | $total_count |"
	add_github_summary "| Eligible for deletion | $eligible_count |"
	add_github_summary "| Deleted | 0 |"
	add_github_summary "| Status | :white_check_mark: Nothing to clean |"
	exit 0
fi

# Skip the first KEEP_LATEST entries (they're the newest untagged)
to_delete=$(echo "$eligible_versions" | jq --argjson skip "$KEEP_LATEST" '.[$skip:]')
delete_count=$(echo "$to_delete" | jq 'length')

log_info "Will delete $delete_count version(s) (keeping $KEEP_LATEST most recent untagged)"

# =============================================================================
# Delete versions
# =============================================================================
deleted=0
failed=0

for i in $(seq 0 $((delete_count - 1))); do
	version_id=$(echo "$to_delete" | jq -r ".[$i].id")
	version_name=$(echo "$to_delete" | jq -r ".[$i].name")
	updated_at=$(echo "$to_delete" | jq -r ".[$i].updated_at")

	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "[dry-run] Would delete version $version_id ($version_name, updated $updated_at)"
		deleted=$((deleted + 1))
		continue
	fi

	if gh api --method DELETE \
		"/orgs/${GITHUB_ORG}/packages/container/${PACKAGE_NAME}/versions/${version_id}" \
		2>/dev/null; then
		log_success "Deleted version $version_id ($version_name, updated $updated_at)"
		deleted=$((deleted + 1))
	else
		# Try user endpoint
		if gh api --method DELETE \
			"/users/${GITHUB_ORG}/packages/container/${PACKAGE_NAME}/versions/${version_id}" \
			2>/dev/null; then
			log_success "Deleted version $version_id ($version_name, updated $updated_at)"
			deleted=$((deleted + 1))
		else
			log_error "Failed to delete version $version_id ($version_name)"
			failed=$((failed + 1))
		fi
	fi
done

# =============================================================================
# Summary
# =============================================================================
if [[ "$DRY_RUN" == "true" ]]; then
	log_info "Dry run complete: $deleted version(s) would be deleted"
else
	log_success "Cleanup complete: $deleted deleted, $failed failed"
fi

add_github_summary "## GHCR Cleanup"
add_github_summary ""
add_github_summary "| Property | Value |"
add_github_summary "| -------- | ----- |"
add_github_summary "| Package | \`${GITHUB_ORG}/${PACKAGE_NAME}\` |"
add_github_summary "| Total versions | $total_count |"
add_github_summary "| Eligible for deletion | $eligible_count |"
add_github_summary "| Kept (most recent) | $KEEP_LATEST |"

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
