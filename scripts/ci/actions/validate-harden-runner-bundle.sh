#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Verify harden-runner bundle matches canonical scripts/ci egress assets
#
# Usage:
#   bash scripts/ci/actions/validate-harden-runner-bundle.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUNDLE_LIB=".github/actions/harden-runner/lib"
BUNDLE_RESOLVE=".github/actions/harden-runner/resolve-egress-endpoints.sh"

bash "$SCRIPT_DIR/sync-harden-runner-bundle.sh" >/dev/null

if ! git -C "$REPO_ROOT" diff --exit-code -- \
	"$BUNDLE_LIB" \
	"$BUNDLE_RESOLVE"; then
	echo "harden-runner bundle is out of sync (run sync-harden-runner-bundle.sh)" >&2
	git -C "$REPO_ROOT" diff -- "$BUNDLE_LIB" "$BUNDLE_RESOLVE"
	exit 1
fi

if [[ -n "$(git -C "$REPO_ROOT" status --porcelain -- "$BUNDLE_LIB" "$BUNDLE_RESOLVE")" ]]; then
	echo "harden-runner bundle has untracked drift (run sync-harden-runner-bundle.sh)" >&2
	git -C "$REPO_ROOT" status --porcelain -- "$BUNDLE_LIB" "$BUNDLE_RESOLVE"
	exit 1
fi

echo "harden-runner bundle matches canonical egress lib"
