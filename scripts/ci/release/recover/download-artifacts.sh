#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Download the ORIGINAL publish run's artifacts for a recovery run
#          (#966). The artifacts are the recovery source: nothing is rebuilt.
#
# A download that fails because the artifact expired (the 90-day retention
# window) or never existed is the tier-three boundary: without the attested
# original bytes the only remaining copies are the published ones.
#
# Environment:
#   SOURCE_RUN_ID      Original publish run id (required)
#   GITHUB_REPOSITORY  owner/repo (required)
#   NPM_ARTIFACT       Artifact holding the npm package set (empty: skip)
#   RELEASE_ARTIFACT   Artifact holding the GitHub Release assets (empty: skip)
#   TARGET_DIR         Download root (default recovery-artifacts)
#   GH_CMD             gh binary override (default gh)

set -euo pipefail

: "${SOURCE_RUN_ID:?SOURCE_RUN_ID is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
NPM_ARTIFACT="${NPM_ARTIFACT:-}"
RELEASE_ARTIFACT="${RELEASE_ARTIFACT:-}"
TARGET_DIR="${TARGET_DIR:-recovery-artifacts}"
GH="${GH_CMD:-gh}"

if [[ -z "$NPM_ARTIFACT" && -z "$RELEASE_ARTIFACT" ]]; then
	echo "No artifacts configured; nothing to download."
	exit 0
fi

download() {
	local name="$1" dest="$2"
	echo "==> Downloading artifact '$name' from run $SOURCE_RUN_ID into $dest"
	mkdir -p "$dest"
	if ! "$GH" run download "$SOURCE_RUN_ID" --repo "$GITHUB_REPOSITORY" --name "$name" --dir "$dest"; then
		echo "ERROR: could not download artifact '$name' from run $SOURCE_RUN_ID." >&2
		echo "ERROR: the original artifacts are the only recovery source; if they expired (90-day retention) the release cannot be resumed — tier three: cut a new patch version." >&2
		exit 1
	fi
	local count
	count="$(find "$dest" -type f | wc -l | tr -d ' ')"
	if [[ "$count" -eq 0 ]]; then
		echo "ERROR: artifact '$name' downloaded no files; refusing to resume from an empty source" >&2
		exit 1
	fi
	echo "    $count file(s)"
}

[[ -z "$NPM_ARTIFACT" ]] || download "$NPM_ARTIFACT" "$TARGET_DIR/npm"
[[ -z "$RELEASE_ARTIFACT" ]] || download "$RELEASE_ARTIFACT" "$TARGET_DIR/release"
