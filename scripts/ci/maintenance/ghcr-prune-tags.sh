#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Prune aged tagged GHCR versions while preserving release tags
#
# Ported from lgtm-hq/Rustume's `prune-tagged` job
# (.github/workflows/ghcr-cleanup.yml + scripts/ci/maintenance/ghcr-prune-tags.sh),
# which proved this policy in production before it was generalised here (#759).
# Once this lands, Rustume can drop its inline job and script.
#
# Retention policy (see scripts/ci/lib/ghcr/retention.sh):
#   latest, semver              keep forever
#   main, sha-*                 delete past MAIN_RETENTION_DAYS
#   alpha/beta/rc/pre/dev/snapshot
#                               delete past PRERELEASE_RETENTION_DAYS
#   anything else               keep forever (fail safe)
#
# A version is deleted only when EVERY tag on it is deletable. That is what
# makes a release's immutable `sha-<commit>` pin survive: the release manifest
# also carries `latest` and semver, which never expire.
#
# Environment variables:
#   PACKAGE_NAME              - GHCR package name to prune (required)
#   GITHUB_ORG                - GitHub org or user owning the package (required)
#   GH_TOKEN                  - GitHub token with packages:write scope (required)
#   MAIN_RETENTION_DAYS       - Retention for main/sha-* tags (default: 30)
#   PRERELEASE_RETENTION_DAYS - Retention for pre-release tags (default: 90)
#   DRY_RUN                   - Log only, no deletions (default: true)

set -euo pipefail

: "${PACKAGE_NAME:?PACKAGE_NAME is required}"
: "${GITHUB_ORG:?GITHUB_ORG is required}"
: "${GH_TOKEN:?GH_TOKEN is required (needs packages:write)}"
: "${MAIN_RETENTION_DAYS:=30}"
: "${PRERELEASE_RETENTION_DAYS:=90}"
: "${DRY_RUN:=true}"

# Anything other than a literal `true` would otherwise mean "delete for real",
# so `DRY_RUN=True` or `DRY_RUN=yes` would quietly arm a destructive run. This
# script deletes container images: fail closed on anything unrecognised.
case "$DRY_RUN" in
true | false) ;;
*)
	echo "ERROR: DRY_RUN must be 'true' or 'false', got: '$DRY_RUN'" >&2
	exit 1
	;;
esac

[[ "$MAIN_RETENTION_DAYS" =~ ^[0-9]+$ ]] || {
	echo "ERROR: MAIN_RETENTION_DAYS must be a non-negative integer, got: '$MAIN_RETENTION_DAYS'" >&2
	exit 1
}
[[ "$PRERELEASE_RETENTION_DAYS" =~ ^[0-9]+$ ]] || {
	echo "ERROR: PRERELEASE_RETENTION_DAYS must be a non-negative integer, got: '$PRERELEASE_RETENTION_DAYS'" >&2
	exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/ghcr/retention.sh
source "$SCRIPT_DIR/../lib/ghcr/retention.sh"

# GitHub Packages REST API encodes nested path slashes; registry v2 paths do not.
PACKAGE_NAME_API="${PACKAGE_NAME//\//%2F}"

# Populated by ghcr_fetch_versions and read by the classification block below.
all_versions='[]'

# Packages live under /orgs for org-owned repos and /users for user-owned ones,
# and there is no cheap way to tell which without asking. Try org, fall back to
# user, and report BOTH errors when neither works -- a bare "failed to fetch"
# sends the reader hunting for a permissions problem that may not exist.
ghcr_fetch_versions() {
	local err_file org_err user_err
	err_file=$(mktemp)
	# Covers the die path and any interrupt, not just the explicit returns.
	trap 'rm -f "$err_file"' RETURN

	if all_versions=$(gh api --paginate \
		"/orgs/${GITHUB_ORG}/packages/container/${PACKAGE_NAME_API}/versions" \
		2>"$err_file" | jq -s 'add // []'); then
		return 0
	fi
	org_err=$(<"$err_file")

	if all_versions=$(gh api --paginate \
		"/users/${GITHUB_ORG}/packages/container/${PACKAGE_NAME_API}/versions" \
		2>"$err_file" | jq -s 'add // []'); then
		return 0
	fi
	user_err=$(<"$err_file")

	die "Failed to fetch package versions (orgs: ${org_err:-none}; users: ${user_err:-none})"
}

ghcr_delete_version() {
	local version_id="$1"

	# Belt-and-braces: the main loop already skips this call under dry run, but
	# this script deletes container images, so the guard stays for any future
	# caller that forgets. Deliberately unreachable today.
	if [[ "$DRY_RUN" == "true" ]]; then
		return 0
	fi

	# Same org-then-user probe as ghcr_fetch_versions, and the same reason to
	# keep both errors: the org attempt's message is usually the informative
	# one, and overwriting it with the user 404 hides why the delete failed.
	local org_err user_err
	if org_err=$(gh api --method DELETE \
		"/orgs/${GITHUB_ORG}/packages/container/${PACKAGE_NAME_API}/versions/${version_id}" \
		2>&1); then
		return 0
	fi

	if user_err=$(gh api --method DELETE \
		"/users/${GITHUB_ORG}/packages/container/${PACKAGE_NAME_API}/versions/${version_id}" \
		2>&1); then
		return 0
	fi

	log_error "Failed to delete version ${version_id} (orgs: ${org_err:-none}; users: ${user_err:-none})"
	return 1
}

emit_summary() {
	add_github_summary "## GHCR Tagged Retention"
	add_github_summary ""
	add_github_summary "| Property | Value |"
	add_github_summary "| -------- | ----- |"
	add_github_summary "| Package | \`${GITHUB_ORG}/${PACKAGE_NAME}\` |"
	add_github_summary "| Tagged versions | $tagged_count |"
	add_github_summary "| Retained | $retained |"
	add_github_summary "| Main/sha retention | ${MAIN_RETENTION_DAYS}d |"
	add_github_summary "| Pre-release retention | ${PRERELEASE_RETENTION_DAYS}d |"

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
}

# =============================================================================
# Cutoffs. GNU date first, BSD `date -v` second: the runner image is Linux but
# the fallback keeps this runnable (and testable) on macOS.
# =============================================================================
main_cutoff=$(date -u -d "${MAIN_RETENTION_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
	date -u -v-"${MAIN_RETENTION_DAYS}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
	die "Could not compute main cutoff date")
prerelease_cutoff=$(date -u -d "${PRERELEASE_RETENTION_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
	date -u -v-"${PRERELEASE_RETENTION_DAYS}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
	die "Could not compute prerelease cutoff date")

log_info "Fetching versions for package: ${GITHUB_ORG}/${PACKAGE_NAME}"
log_info "main/sha-* cutoff: $main_cutoff (${MAIN_RETENTION_DAYS} days)"
log_info "pre-release cutoff: $prerelease_cutoff (${PRERELEASE_RETENTION_DAYS} days)"

ghcr_fetch_versions

# =============================================================================
# Classify tagged versions. Age uses updated_at when present (consistent with
# the untagged pruner) so a recently refreshed manifest is never treated as old.
# =============================================================================
tagged_versions=$(jq '
	[ .[]
	  | select((.metadata.container.tags // []) | length > 0)
	  | { id, name,
	      tags: (.metadata.container.tags // []),
	      t: (.updated_at // .created_at // "") }
	]
' <<<"$all_versions")
tagged_count=$(jq 'length' <<<"$tagged_versions")
log_info "Found $tagged_count tagged version(s)"

deleted=0
failed=0
retained=0

if [[ "$tagged_count" -eq 0 ]]; then
	log_info "No tagged versions to prune for ${PACKAGE_NAME}"
	emit_summary
	exit 0
fi

# Materialised rather than read from a process substitution: `pipefail` does not
# cover process substitution, so a jq failure there would look identical to "no
# versions" and the script would report a clean run having done nothing.
rows=$(jq -r '.[] | [.id, .t, (.tags | @json)] | @tsv' <<<"$tagged_versions") ||
	die "Failed to serialise tagged versions"

while IFS=$'\t' read -r version_id version_time tags_json; do
	[[ -z "$version_id" ]] && continue

	tags_csv=$(jq -r 'join(",")' <<<"$tags_json")

	if ! ghcr_all_tags_deletable \
		"$tags_json" \
		"$version_time" \
		"$main_cutoff" \
		"$prerelease_cutoff"; then
		retained=$((retained + 1))
		continue
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "[dry-run] Would delete version ${version_id} (tags: ${tags_csv}, ${version_time})"
		deleted=$((deleted + 1))
		continue
	fi

	if ghcr_delete_version "$version_id"; then
		log_success "Deleted version ${version_id} (tags: ${tags_csv}, ${version_time})"
		deleted=$((deleted + 1))
	else
		failed=$((failed + 1))
	fi
done <<<"$rows"

if [[ "$DRY_RUN" == "true" ]]; then
	log_info "Dry run complete: $deleted version(s) would be deleted, $retained retained"
else
	log_success "Tagged prune complete: $deleted deleted, $retained retained, $failed failed"
fi

emit_summary

if [[ $failed -gt 0 ]]; then
	exit 1
fi
