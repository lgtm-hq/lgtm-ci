#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve the upload artifact name for reusable-build-artifact.
#
# Single-version mode keeps the caller artifact-name verbatim. Matrix mode
# appends -<node-version> so parallel legs do not collide.
#
# Environment:
#   ARTIFACT_NAME   (required) Base artifact name from the workflow input
#   NODE_VERSION    (required) Current matrix node-version
#   MATRIX_MODE     (required) true when node-version-matrix was used
#   GITHUB_OUTPUT   (required) Writes artifact-name=

set -euo pipefail

: "${ARTIFACT_NAME:?ARTIFACT_NAME is required}"
: "${NODE_VERSION:?NODE_VERSION is required}"
: "${MATRIX_MODE:?MATRIX_MODE is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

artifact_name="$(trim "$ARTIFACT_NAME")"
node_version="$(trim "$NODE_VERSION")"
matrix_mode="$(trim "$MATRIX_MODE")"

if [[ -z "$artifact_name" ]]; then
	echo "::error::ARTIFACT_NAME must not be empty" >&2
	exit 1
fi

if [[ -z "$node_version" ]]; then
	echo "::error::NODE_VERSION must not be empty" >&2
	exit 1
fi

resolved="$artifact_name"
if [[ "$matrix_mode" == "true" ]]; then
	resolved="${artifact_name}-${node_version}"
fi

echo "Resolved artifact name: ${resolved}"
echo "artifact-name=${resolved}" >>"$GITHUB_OUTPUT"
