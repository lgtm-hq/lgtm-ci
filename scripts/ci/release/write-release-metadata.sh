#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Write release-metadata.json for the version-update hook (#849).
#
# The hook runs in a job with no token, so anything it legitimately needs
# from the GitHub API is fetched here, by lgtm-ci code in the privileged
# job, and handed over as a read-only file. Lookups are best-effort: a
# missing release or an unreadable package yields `null` plus a warning,
# never a failed release.
#
# Shape (schema 1):
#   {
#     "schema": 1,
#     "repository": "owner/name",
#     "next_version": "1.2.3",
#     "tag_prefix": "v",
#     "latest_release": {"tag": "v1.2.2", "version": "1.2.2",
#                        "published_at": "...", "url": "..."} | null,
#     "container": {"package": "name", "version": "1.2.2",
#                   "digest": "sha256:..."} | null
#   }
#
# `container` is the newest release-tagged (major.minor.patch) version of the
# GitHub Packages container CONTAINER_PACKAGE, resolved through
# api.github.com so no registry egress is needed. The App token must hold
# Packages: read for this; otherwise the field is null.
#
# Environment variables:
#   GH_TOKEN          - App installation token
#   REPO              - owner/name
#   OWNER             - repository owner login
#   OWNER_TYPE        - Organization or User (selects the packages endpoint)
#   NEXT_VERSION      - Version the hook is preparing
#   TAG_PREFIX        - Tag prefix (default v)
#   CONTAINER_PACKAGE - Optional container package name; empty skips lookup
#   OUTPUT_PATH       - Destination file

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required}"
: "${OWNER:?OWNER is required}"
: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${OUTPUT_PATH:?OUTPUT_PATH is required}"
OWNER_TYPE="${OWNER_TYPE:-Organization}"
TAG_PREFIX="${TAG_PREFIX:-v}"
CONTAINER_PACKAGE="${CONTAINER_PACKAGE:-}"

# The package may carry thousands of sha-/ci- tags. Pages are ordered by
# creation, not by version, so a backport pushed after a newer release would
# hide the newer one on a later page: walk every page up to the cap and pick
# the highest release tag among them.
PER_PAGE=100
MAX_PAGES=20

latest_release_json() {
	local payload
	if ! payload="$(gh api -X GET "repos/${REPO}/releases/latest" 2>/dev/null)"; then
		log_warn "no latest release for ${REPO}; latest_release=null"
		printf 'null'
		return 0
	fi
	jq -c --arg prefix "$TAG_PREFIX" '{
		tag: .tag_name,
		version: (.tag_name | ltrimstr($prefix)),
		published_at: .published_at,
		url: .html_url
	}' <<<"$payload"
}

container_json() {
	local scope versions page records
	if [[ -z "$CONTAINER_PACKAGE" ]]; then
		printf 'null'
		return 0
	fi
	case "$OWNER_TYPE" in
	Organization) scope="orgs/${OWNER}" ;;
	*) scope="users/${OWNER}" ;;
	esac

	# Pages go to files: a page of 100 versions with many tags can exceed the
	# single-argument limit, so nothing is passed through --argjson.
	local pages
	pages="$(mktemp -d)"
	for ((page = 1; page <= MAX_PAGES; page++)); do
		if ! gh api -X GET \
			"${scope}/packages/container/${CONTAINER_PACKAGE}/versions?per_page=${PER_PAGE}&page=${page}" \
			>"${pages}/$(printf '%03d' "$page").json" 2>/dev/null; then
			log_warn "packages API refused ${CONTAINER_PACKAGE} (needs Packages: read on the App); container=null"
			rm -rf "$pages"
			printf 'null'
			return 0
		fi
		# A short page is the last one.
		if [[ "$(jq 'length' "${pages}/$(printf '%03d' "$page").json" 2>/dev/null || echo 0)" -lt "$PER_PAGE" ]]; then
			break
		fi
		if [[ "$page" -eq "$MAX_PAGES" ]]; then
			log_warn "stopped after ${MAX_PAGES} pages of ${CONTAINER_PACKAGE} versions; container may be based on an incomplete list"
		fi
	done

	# Best-effort: an unparseable payload yields null, never a failed release.
	local result
	if ! result="$(jq -s -c --arg package "$CONTAINER_PACKAGE" '
		[ add[]?
		  | select(.name | startswith("sha256:"))
		  | {digest: .name, tag: .metadata.container.tags[]?}
		  | select(.tag | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
		  | {digest, version: .tag, key: (.tag | split(".") | map(tonumber))}
		]
		| sort_by(.key)
		| last
		| if . == null then null
		  else {package: $package, version: .version, digest: .digest} end
	' "${pages}"/*.json 2>/dev/null)"; then
		log_warn "could not parse ${CONTAINER_PACKAGE} package versions; container=null"
		result='null'
	fi
	rm -rf "$pages"
	printf '%s' "$result"
}

latest_release="$(latest_release_json)"
container="$(container_json)"

mkdir -p -- "$(dirname -- "$OUTPUT_PATH")"
jq -n \
	--arg repo "$REPO" \
	--arg next "$NEXT_VERSION" \
	--arg prefix "$TAG_PREFIX" \
	--argjson latest "$latest_release" \
	--argjson container "$container" \
	'{schema: 1, repository: $repo, next_version: $next, tag_prefix: $prefix,
	  latest_release: $latest, container: $container}' >"$OUTPUT_PATH"

log_info "Wrote release metadata to ${OUTPUT_PATH}"
jq . "$OUTPUT_PATH" >&2
