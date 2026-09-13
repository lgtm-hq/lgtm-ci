#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve-stage gate for the release recovery workflow (#966).
#
# A recovery run publishes against an ORIGINAL immutable tag and the ORIGINAL
# attested artifacts. Before anything runs, this gate refuses:
#   - prerelease tags (aN/bN/rcN): abandoned by policy — cut a new version;
#   - a tag that does not exist;
#   - a tag whose commit differs from the original run's head SHA: recovering
#     against a moved tag would publish bytes under the wrong version;
#   - a mutable-tag configuration: the tag must point at the same commit the
#     original run built, so "same commit" IS the immutability check the
#     workflow can make (tag-protection rules live in repo settings and are
#     documented in docs/release-recovery.md).
#
# Environment:
#   TAG               Tag to recover (required)
#   EXPECTED_SHA      Head SHA of the original publish run (required)
#   GITHUB_REPOSITORY owner/repo (required)
#   GH_TOKEN          Token with repo read (contents: read)
#   GH_CMD            gh binary name (overridable in tests; default gh)

set -euo pipefail

: "${TAG:?TAG is required}"
: "${EXPECTED_SHA:?EXPECTED_SHA is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
GH="${GH_CMD:-gh}"

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

# Prereleases are out of scope by policy: a partial prerelease is abandoned
# and a new one is cut (the tag itself is the version; republishing the same
# npm/PyPI version is impossible anyway).
if [[ "$TAG" =~ [0-9]-(a|b|rc)[0-9]+$ ]]; then
	fail "refusing to recover prerelease tag '$TAG': prereleases are abandoned by policy — cut a new prerelease version instead"
fi

tag_sha="$("$GH" api "repos/${GITHUB_REPOSITORY}/commits/${TAG}" --jq '.sha' 2>/dev/null)" ||
	fail "tag '${TAG}' not found in ${GITHUB_REPOSITORY}; nothing to recover against"

# The tag must point at the exact commit the original run built. A moved tag
# means the "original artifacts" are for a different version than the tag now
# names — publishing them would violate same-bytes-same-version.
if [[ "$tag_sha" != "$EXPECTED_SHA" ]]; then
	fail "tag '${TAG}' points at ${tag_sha}, but the original run built ${EXPECTED_SHA}; the tag moved — recovery refused (tier three: cut a new patch version)"
fi

# Reaching here proves the tag is present, unambiguous, and pinned to the
# original run's commit.
echo "Tag '${TAG}' resolved to ${tag_sha} (matches the original run's head SHA)."
