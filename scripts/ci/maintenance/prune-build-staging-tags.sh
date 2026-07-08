#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Safely prune stale per-platform build-<run_id>-<slug> staging tags
#          from a GHCR package without ever orphaning a live multi-arch index.
#
# Background (#433/#434): the multi-arch publish retains the per-platform
# staging manifests because they are the merged release index's own children.
# Deleting a staging manifest that a published index still points at reproduces
# the #433 dangling-index bug (children 404). This pruner therefore deletes a
# build-* staging tag only when BOTH hold:
#   1. its run is older than THRESHOLD_DAYS (and not among KEEP_RECENT newest), and
#   2. its manifest digest is NOT referenced by any current tagged, non-build-*
#      image index in the package (the referenced-digest safety gate).
# When the referenced-digest set cannot be collected completely, the whole
# prune is skipped (fail-closed) so a transient registry error can never lead
# to an unprotected deletion.
#
# Environment variables:
#   PACKAGE_NAME       - GHCR package name to prune (required)
#   GITHUB_ORG         - GitHub org or user owning the package (required)
#   GH_TOKEN           - GitHub token with packages:write scope (required)
#   THRESHOLD_DAYS     - Minimum staging-tag age in days before deletion (default: 30)
#   KEEP_RECENT        - Always keep N most recent staging tags regardless of age (default: 0)
#   PROTECT_REFERENCED - Skip prune when referenced-digest collection fails (default: true)
#   DRY_RUN            - Log only, no deletions (default: true)

set -euo pipefail

: "${PACKAGE_NAME:?PACKAGE_NAME is required}"
: "${GITHUB_ORG:?GITHUB_ORG is required}"
: "${THRESHOLD_DAYS:=30}"
: "${KEEP_RECENT:=0}"
: "${PROTECT_REFERENCED:=true}"
: "${DRY_RUN:=true}"

[[ "$THRESHOLD_DAYS" =~ ^[0-9]+$ ]] || {
	echo "ERROR: THRESHOLD_DAYS must be a non-negative integer, got: '$THRESHOLD_DAYS'" >&2
	exit 1
}
[[ "$KEEP_RECENT" =~ ^[0-9]+$ ]] || {
	echo "ERROR: KEEP_RECENT must be a non-negative integer, got: '$KEEP_RECENT'" >&2
	exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/ghcr/registry.sh
source "$SCRIPT_DIR/../lib/ghcr/registry.sh"
# shellcheck source=../lib/ghcr/tags.sh
source "$SCRIPT_DIR/../lib/ghcr/tags.sh"

# GitHub Packages REST API encodes nested path slashes; registry v2 paths do not.
PACKAGE_NAME_API="${PACKAGE_NAME//\//%2F}"

# jq snippet: a version is a build staging version when it carries at least one
# tag and every tag matches build-<run_id>-<slug>. Single-quoted on purpose so
# jq (not the shell) evaluates the expression.
# shellcheck disable=SC2016
readonly BUILD_STAGING_FILTER='
	def is_build_staging_only:
		(.metadata.container.tags // []) as $tags
		| ($tags | length) > 0
			and (all($tags[]; test("^build-[0-9]+-[a-zA-Z0-9._-]+$")));
'

ghcr_fetch_versions() {
	all_versions=$(gh api --paginate \
		"/orgs/${GITHUB_ORG}/packages/container/${PACKAGE_NAME_API}/versions" \
		2>/dev/null | jq -s 'add // []') || {
		all_versions=$(gh api --paginate \
			"/users/${GITHUB_ORG}/packages/container/${PACKAGE_NAME_API}/versions" \
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
		"/orgs/${GITHUB_ORG}/packages/container/${PACKAGE_NAME_API}/versions/${version_id}" \
		2>&1); then
		return 0
	fi

	if err=$(gh api --method DELETE \
		"/users/${GITHUB_ORG}/packages/container/${PACKAGE_NAME_API}/versions/${version_id}" \
		2>&1); then
		return 0
	fi

	log_error "Failed to delete version ${version_id}: ${err}"
	return 1
}

emit_skip_summary() {
	local status="$1"
	add_github_summary "## Prune Build Staging Tags"
	add_github_summary ""
	add_github_summary "| Property | Value |"
	add_github_summary "| -------- | ----- |"
	add_github_summary "| Package | \`${GITHUB_ORG}/${PACKAGE_NAME}\` |"
	add_github_summary "| Status | ${status} |"
}

# =============================================================================
# Fetch all package versions
# =============================================================================
log_info "Fetching versions for package: ${GITHUB_ORG}/${PACKAGE_NAME}"

ghcr_fetch_versions

total_count=$(echo "$all_versions" | jq 'length')
log_info "Found $total_count total version(s)"

# =============================================================================
# Identify build-<run_id>-<slug> staging candidates
# =============================================================================
staging_versions=$(echo "$all_versions" | jq "
	$BUILD_STAGING_FILTER
	[ .[]
	  | select(is_build_staging_only)
	  | { id, name, tags: (.metadata.container.tags // []), t: (.updated_at // .created_at // \"\") }
	]
	| sort_by(.t) | reverse
")
staging_count=$(echo "$staging_versions" | jq 'length')
log_info "Found $staging_count build-* staging tag(s)"

if [[ "$staging_count" -eq 0 ]]; then
	log_info "No build-* staging tags to prune for ${PACKAGE_NAME}"
	emit_skip_summary ":white_check_mark: Nothing to prune"
	exit 0
fi

# =============================================================================
# Referenced-digest safety gate (#433 regression guard)
# Collect the digests referenced by every tagged NON-build-* index. A staging
# manifest is only prunable when it is absent from this set. Build staging
# versions are excluded from the collection input so their own root digests do
# not falsely protect them; a staging digest lands in the set only when it is a
# child (or subject/referrer) of a live release index.
# =============================================================================
referenced_digests=()

if [[ "$PROTECT_REFERENCED" == "true" ]]; then
	non_build_versions=$(echo "$all_versions" | jq "
		$BUILD_STAGING_FILTER
		[ .[] | select(is_build_staging_only | not) ]
	")

	registry_token=""
	if ! registry_token=$(ghcr_exchange_registry_token \
		"$GITHUB_ORG" \
		"$PACKAGE_NAME" \
		"${GH_TOKEN:-}"); then
		log_warning "Skipping prune for ${PACKAGE_NAME} (registry auth failed; cannot compute reference protection)"
		emit_skip_summary ":warning: Skipped (registry auth failed)"
		exit 0
	fi

	referenced_complete=true
	referenced_digests_text=""
	ghcr_collect_referenced_digests \
		"$GITHUB_ORG" \
		"$PACKAGE_NAME" \
		"$non_build_versions" \
		"$registry_token" \
		referenced_complete \
		referenced_digests_text

	if [[ "$referenced_complete" != "true" ]]; then
		log_warning "Skipping prune for ${PACKAGE_NAME} (referenced-digest collection incomplete)"
		emit_skip_summary ":warning: Skipped (incomplete reference protection)"
		exit 0
	fi

	if [[ -n "$referenced_digests_text" ]]; then
		while IFS= read -r digest; do
			[[ -n "$digest" ]] && referenced_digests+=("$digest")
		done <<<"$referenced_digests_text"
	fi
	log_info "Collected ${#referenced_digests[@]} referenced digest(s) for protection"
else
	log_warning "PROTECT_REFERENCED=false: referenced-digest safety gate disabled"
fi

if ((${#referenced_digests[@]} > 0)); then
	refs_json=$(printf '%s\n' "${referenced_digests[@]}" | jq -R . | jq -s .)
else
	refs_json='[]'
fi

# =============================================================================
# Select prunable staging tags: older than the cutoff, not among the newest
# KEEP_RECENT, and not referenced by any live release index.
# =============================================================================
cutoff_date=$(date -u -v-"${THRESHOLD_DAYS}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
	date -u -d "${THRESHOLD_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
	die "Could not compute cutoff date")

log_info "Cutoff date: $cutoff_date (older than $THRESHOLD_DAYS days); keeping $KEEP_RECENT most recent"

aged_versions=$(echo "$staging_versions" | jq --arg cutoff "$cutoff_date" --argjson keep "$KEEP_RECENT" '
	.[$keep:] | [ .[] | select(.t != "" and .t < $cutoff) ]
')
aged_count=$(echo "$aged_versions" | jq 'length')
log_info "Found $aged_count staging tag(s) older than the cutoff"

to_delete=$(echo "$aged_versions" | jq --argjson refs "$refs_json" '
	[ .[] | select(.name as $n | ($refs | index($n) | not)) ]
')
protected=$(echo "$aged_versions" | jq --argjson refs "$refs_json" '
	[ .[] | select(.name as $n | ($refs | index($n))) ]
')
delete_count=$(echo "$to_delete" | jq 'length')
protected_count=$(echo "$protected" | jq 'length')

# Log every staging tag skipped because it is still an index child.
while IFS=$'\t' read -r version_name tags_csv; do
	[[ -z "$version_name" ]] && continue
	log_info "Skipping $version_name ($tags_csv): still referenced by a live release"
done < <(echo "$protected" | jq -r '.[] | [.name, (.tags | join(","))] | @tsv')

# =============================================================================
# Delete prunable staging tags
# =============================================================================
deleted=0
failed=0

while IFS=$'\t' read -r version_id version_name tags_csv version_time; do
	[[ -z "$version_id" ]] && continue
	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "[dry-run] Would prune staging version $version_id ($tags_csv, $version_name, updated $version_time)"
		deleted=$((deleted + 1))
		continue
	fi

	if ghcr_delete_version "$version_id"; then
		log_success "Pruned staging version $version_id ($tags_csv, $version_name)"
		deleted=$((deleted + 1))
	else
		failed=$((failed + 1))
	fi
done < <(echo "$to_delete" | jq -r '.[] | [.id, .name, (.tags | join(",")), .t] | @tsv')

# =============================================================================
# Summary
# =============================================================================
if [[ "$DRY_RUN" == "true" ]]; then
	log_info "Dry run complete: $deleted staging tag(s) would be pruned, $protected_count protected"
else
	log_success "Prune complete: $deleted pruned, $protected_count protected, $failed failed"
fi

add_github_summary "## Prune Build Staging Tags"
add_github_summary ""
add_github_summary "| Property | Value |"
add_github_summary "| -------- | ----- |"
add_github_summary "| Package | \`${GITHUB_ORG}/${PACKAGE_NAME}\` |"
add_github_summary "| Total versions | $total_count |"
add_github_summary "| Build staging tags | $staging_count |"
add_github_summary "| Older than ${THRESHOLD_DAYS}d (kept ${KEEP_RECENT} newest) | $aged_count |"
add_github_summary "| Protected (still referenced) | $protected_count |"
add_github_summary "| Referenced digests scanned | ${#referenced_digests[@]} |"

if [[ "$DRY_RUN" == "true" ]]; then
	add_github_summary "| Would prune | $deleted |"
	add_github_summary "| Status | :construction: Dry Run |"
else
	add_github_summary "| Pruned | $deleted |"
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
