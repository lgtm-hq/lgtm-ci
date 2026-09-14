#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve-stage gate for the release recovery workflow (#966).
#
# A recovery run publishes against an ORIGINAL immutable tag and the ORIGINAL
# attested artifacts. Before anything runs, this gate refuses:
#   - prerelease tags, in PEP 440 (1.2.3a1, 1.2.3b1, 1.2.3rc1) and SemVer
#     (1.2.3-rc.1, 1.2.3-beta.1, 1.2.3-alpha1) spellings: abandoned by
#     policy — cut a new version;
#   - a tag that does not exist;
#   - a source run that is not THIS repository's publish workflow: the run id
#     is caller-supplied, and artifacts from any other run of any workflow
#     would otherwise be published under the tag;
#   - a source run whose head SHA differs from the tag's commit: recovering
#     against a moved tag (or a run of another commit) would publish bytes
#     under the wrong version. "Same commit" IS the immutability check the
#     workflow can make (tag-protection rules live in repo settings and are
#     documented in docs/release-recovery.md).
# The run's identity (repository, workflow path, head SHA) is read from the
# API, never trusted from inputs.
#
# Environment:
#   TAG               Tag to recover (required)
#   SOURCE_RUN_ID     Original publish run id (required)
#   SOURCE_WORKFLOW   Path of the publish workflow that run must belong to,
#                     e.g. .github/workflows/publish-pypi-on-tag.yml (required)
#   GITHUB_REPOSITORY owner/repo (required)
#   GH_TOKEN          Token with repo + actions read
#   GH_CMD            gh binary name (overridable in tests; default gh)
#   GITHUB_OUTPUT     head_sha=<sha> written when set

set -euo pipefail

: "${TAG:?TAG is required}"
: "${SOURCE_RUN_ID:?SOURCE_RUN_ID is required}"
: "${SOURCE_WORKFLOW:?SOURCE_WORKFLOW is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
GH="${GH_CMD:-gh}"

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

# Prereleases are out of scope by policy: a partial prerelease is abandoned
# and a new one is cut (the tag itself is the version; republishing the same
# npm/PyPI version is impossible anyway).
# PEP 440 attaches the marker directly (1.2.3rc1); SemVer separates it with
# a hyphen and may dot the number (1.2.3-rc.1, 1.2.3-beta.1). Both spellings
# and the spelled-out names are prereleases.
if [[ "$TAG" =~ [0-9][-._]?(a|b|c|rc|alpha|beta|pre|preview|dev)[-._]?[0-9]*$ ]]; then
	fail "refusing to recover prerelease tag '$TAG': prereleases are abandoned by policy — cut a new prerelease version instead"
fi

tag_sha="$("$GH" api "repos/${GITHUB_REPOSITORY}/commits/${TAG}" --jq '.sha' 2>/dev/null)" ||
	fail "tag '${TAG}' not found in ${GITHUB_REPOSITORY}; nothing to recover against"

# The source run's identity comes from the API. It must be a run of THIS
# repository's publish workflow (the artifacts' provenance is that workflow)
# and it must have built the tag's commit.
run_meta="$("$GH" api "repos/${GITHUB_REPOSITORY}/actions/runs/${SOURCE_RUN_ID}" \
	--jq '[(.repository.full_name // ""), (.path // ""), (.head_sha // "")] | @tsv' 2>/dev/null)" ||
	fail "source run ${SOURCE_RUN_ID} not found in ${GITHUB_REPOSITORY}; recovery needs the original publish run"
IFS=$'\t' read -r run_repo run_path run_sha <<<"$run_meta"

if [[ "$run_repo" != "$GITHUB_REPOSITORY" ]]; then
	fail "source run ${SOURCE_RUN_ID} belongs to '${run_repo:-unknown}', not ${GITHUB_REPOSITORY}; recovery refused"
fi
# The API reports the workflow path as it lives in the repo
# (.github/workflows/<file>.yml); compare the normalized paths exactly.
expected_path="${SOURCE_WORKFLOW#./}"
if [[ "$run_path" != "$expected_path" ]]; then
	fail "source run ${SOURCE_RUN_ID} is a run of '${run_path:-unknown}', not the publish workflow '${expected_path}'; its artifacts are not this release's — recovery refused"
fi
if [[ -z "$run_sha" ]]; then
	fail "source run ${SOURCE_RUN_ID} reports no head SHA; recovery refused"
fi

# The tag must point at the exact commit the original run built. A moved tag
# (or a run of another commit) means the "original artifacts" are for a
# different version than the tag now names — publishing them would violate
# same-bytes-same-version.
if [[ "$tag_sha" != "$run_sha" ]]; then
	fail "tag '${TAG}' points at ${tag_sha}, but source run ${SOURCE_RUN_ID} built ${run_sha}; the tag moved or the run is not this release's — recovery refused (tier three: cut a new patch version)"
fi

# Reaching here proves the tag is present, unambiguous, and pinned to the
# commit the publish workflow's run built.
echo "Tag '${TAG}' resolved to ${tag_sha}; source run ${SOURCE_RUN_ID} (${run_path}) built the same commit."
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	echo "head_sha=${tag_sha}" >>"${GITHUB_OUTPUT}"
fi
