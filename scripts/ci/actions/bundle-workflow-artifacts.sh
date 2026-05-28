#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Bundle workflow artifacts into a GitHub Pages site root
#
# Required environment variables:
#   COMMIT_SHA - Git commit SHA to resolve workflow runs
#   SITE_ROOT - Directory to copy bundled reports into
#   BUNDLE_MANIFEST - Inline JSON manifest or path to .json/.yaml/.yml file
#   GITHUB_REPOSITORY - owner/repo for GitHub API calls
#
# Optional environment variables:
#   FALLBACK_REF - Branch ref for fallback workflow lookup (e.g. main)
#   STRICT - Fail when any bundle entry is missing (default: false)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/bundle/workflow_artifacts.sh
source "$SCRIPT_DIR/../lib/bundle/workflow_artifacts.sh"

: "${COMMIT_SHA:?COMMIT_SHA is required}"
: "${SITE_ROOT:?SITE_ROOT is required}"
: "${BUNDLE_MANIFEST:?BUNDLE_MANIFEST is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

: "${FALLBACK_REF:=}"
: "${STRICT:=false}"

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
	gh auth status >/dev/null 2>&1 || echo "${GITHUB_TOKEN}" | gh auth login --with-token 2>/dev/null || true
fi

bundle_load_manifest "$BUNDLE_MANIFEST"
bundle_run_manifest
