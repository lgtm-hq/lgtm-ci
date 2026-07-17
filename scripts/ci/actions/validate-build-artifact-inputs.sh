#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Validate reusable-build-artifact inputs and emit a versions CSV.
#
# Exactly one of NODE_VERSION or NODE_VERSION_MATRIX must be set (XOR).
# NODE_VERSION_MATRIX is a JSON array of strings, e.g. ["20","22"].
#
# Required environment variables:
#   BUILD_COMMAND   - Non-empty shell command to build
#   ARTIFACT_PATH   - Non-empty path to upload after the build
#   NODE_VERSION    - Single Node.js version (mutually exclusive with matrix)
#   NODE_VERSION_MATRIX - JSON list of Node.js versions (mutually exclusive)
#
# Optional:
#   GITHUB_OUTPUT   - When set, writes versions= and matrix-mode=

set -euo pipefail

: "${BUILD_COMMAND:=}"
: "${ARTIFACT_PATH:=}"
: "${NODE_VERSION:=}"
: "${NODE_VERSION_MATRIX:=}"

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

build_command="$(trim "$BUILD_COMMAND")"
artifact_path="$(trim "$ARTIFACT_PATH")"
node_version="$(trim "$NODE_VERSION")"
node_version_matrix="$(trim "$NODE_VERSION_MATRIX")"

if [[ -z "$build_command" ]]; then
	echo "::error::build-command is required" >&2
	exit 1
fi

if [[ -z "$artifact_path" ]]; then
	echo "::error::artifact-path is required" >&2
	exit 1
fi

if [[ -n "$node_version" && -n "$node_version_matrix" ]]; then
	echo "::error::Set exactly one of node-version or node-version-matrix (not both)" >&2
	exit 1
fi

if [[ -z "$node_version" && -z "$node_version_matrix" ]]; then
	echo "::error::Set exactly one of node-version or node-version-matrix" >&2
	exit 1
fi

versions=""
matrix_mode="false"

if [[ -n "$node_version_matrix" ]]; then
	matrix_mode="true"
	versions="$(
		NODE_VERSION_MATRIX="$node_version_matrix" python3 - <<'PY'
import json
import os
import sys

raw = os.environ["NODE_VERSION_MATRIX"]
try:
    parsed = json.loads(raw)
except json.JSONDecodeError as exc:
    print(f"node-version-matrix must be a JSON array: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(parsed, list) or not parsed:
    print("node-version-matrix must be a non-empty JSON array of strings", file=sys.stderr)
    sys.exit(1)

versions: list[str] = []
for item in parsed:
    if not isinstance(item, str) or not item.strip():
        print(
            "node-version-matrix entries must be non-empty strings",
            file=sys.stderr,
        )
        sys.exit(1)
    versions.append(item.strip())

# Preserve order while deduplicating.
print(",".join(dict.fromkeys(versions)))
PY
	)"
else
	versions="$node_version"
fi

if [[ -z "$versions" ]]; then
	echo "::error::Resolved Node.js version list is empty" >&2
	exit 1
fi

echo "Resolved Node.js versions: ${versions}"
echo "Matrix mode: ${matrix_mode}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	{
		echo "versions=${versions}"
		echo "matrix-mode=${matrix_mode}"
	} >>"$GITHUB_OUTPUT"
fi
