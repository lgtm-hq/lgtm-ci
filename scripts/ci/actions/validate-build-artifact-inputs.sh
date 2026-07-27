#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Validate reusable-build-artifact inputs and resolve toolchain data.
#
# The workflow is toolchain-agnostic (#760): TOOLCHAIN selects a vetted setup
# action inside lgtm-ci, and MATRIX generalises the legacy Node-only
# NODE_VERSION_MATRIX. Legacy Node callers that set nothing new keep the exact
# behaviour they had before: exactly one of NODE_VERSION or NODE_VERSION_MATRIX
# (XOR), a versions CSV, and matrix-mode.
#
# Required environment variables:
#   BUILD_COMMAND   - Non-empty shell command to build
#   ARTIFACT_PATH   - Non-empty path to upload after the build
#
# Optional:
#   TOOLCHAIN           - node (default) | rust | python | none
#   TOOLCHAIN_VERSION   - Toolchain version for non-Node ecosystems; for node it
#                         is an alias of NODE_VERSION
#   NODE_VERSION        - Single Node.js version (toolchain node only)
#   NODE_VERSION_MATRIX - Deprecated JSON list of Node.js versions
#   MATRIX              - Arbitrary JSON matrix; mutually exclusive with the
#                         node-version inputs
#   GITHUB_OUTPUT       - When set, writes toolchain=, version-key=,
#                         toolchain-version=, versions= and matrix-mode=

set -euo pipefail

: "${BUILD_COMMAND:=}"
: "${ARTIFACT_PATH:=}"
: "${TOOLCHAIN:=node}"
: "${TOOLCHAIN_VERSION:=}"
: "${NODE_VERSION:=}"
: "${NODE_VERSION_MATRIX:=}"
: "${MATRIX:=}"

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

build_command="$(trim "$BUILD_COMMAND")"
artifact_path="$(trim "$ARTIFACT_PATH")"
toolchain="$(trim "$TOOLCHAIN")"
toolchain_version="$(trim "$TOOLCHAIN_VERSION")"
node_version="$(trim "$NODE_VERSION")"
node_version_matrix="$(trim "$NODE_VERSION_MATRIX")"
matrix="$(trim "$MATRIX")"

if [[ -z "$build_command" ]]; then
	echo "::error::build-command is required" >&2
	exit 1
fi

if [[ -z "$artifact_path" ]]; then
	echo "::error::artifact-path is required" >&2
	exit 1
fi

if [[ -z "$toolchain" ]]; then
	toolchain="node"
fi

version_key=""
toolchain_label=""
default_version=""
case "$toolchain" in
node)
	version_key="node-version"
	toolchain_label="Node.js"
	;;
rust)
	version_key="rust-toolchain"
	toolchain_label="Rust"
	default_version="stable"
	;;
python)
	version_key="python-version"
	toolchain_label="Python"
	default_version="3.12"
	;;
none)
	version_key=""
	toolchain_label="toolchain"
	;;
*)
	echo "::error::toolchain must be one of: node, rust, python, none (got '${toolchain}')" >&2
	exit 1
	;;
esac

if [[ -n "$node_version_matrix" ]]; then
	echo "::warning::node-version-matrix is deprecated; use matrix instead," \
		"e.g. matrix: '[{\"node-version\":\"20\"},{\"node-version\":\"22\"}]'"
fi

if [[ "$toolchain" != "node" ]] && [[ -n "$node_version" || -n "$node_version_matrix" ]]; then
	echo "::error::node-version and node-version-matrix require toolchain: node" \
		"(got '${toolchain}'); use toolchain-version or matrix instead" >&2
	exit 1
fi

if [[ -n "$node_version" && -n "$toolchain_version" ]]; then
	echo "::error::Set node-version or toolchain-version, not both" >&2
	exit 1
fi

# node-version and toolchain-version are aliases when toolchain is node. With a
# matrix, toolchain-version keeps its cross-toolchain meaning instead: the
# default version for legs that omit the version field.
if [[ "$toolchain" == "node" && -z "$node_version" && -z "$matrix" ]]; then
	node_version="$toolchain_version"
fi

versions=""
matrix_mode="false"

if [[ -n "$matrix" ]]; then
	if [[ -n "$node_version" || -n "$node_version_matrix" ]]; then
		echo "::error::matrix is mutually exclusive with node-version" \
			"and node-version-matrix" >&2
		exit 1
	fi
	matrix_mode="true"
elif [[ -n "$node_version" && -n "$node_version_matrix" ]]; then
	echo "::error::Set exactly one of node-version or node-version-matrix (not both)" >&2
	exit 1
elif [[ -n "$node_version_matrix" ]]; then
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
elif [[ "$toolchain" == "node" ]]; then
	if [[ -z "$node_version" ]]; then
		echo "::error::Set exactly one of node-version or node-version-matrix" \
			"(or toolchain-version, or matrix)" >&2
		exit 1
	fi
	versions="$node_version"
else
	versions="${toolchain_version:-$default_version}"
fi

if [[ -z "$matrix" && -n "$version_key" && -z "$versions" ]]; then
	echo "::error::Resolved ${toolchain_label} version list is empty" >&2
	exit 1
fi

echo "Toolchain: ${toolchain}"
if [[ -n "$version_key" ]]; then
	if [[ -n "$matrix" ]]; then
		echo "Resolved ${toolchain_label} versions: (from matrix)"
	else
		echo "Resolved ${toolchain_label} versions: ${versions}"
	fi
fi
echo "Matrix mode: ${matrix_mode}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	{
		echo "toolchain=${toolchain}"
		echo "version-key=${version_key}"
		echo "toolchain-version=${toolchain_version:-$default_version}"
		echo "versions=${versions}"
		echo "matrix-mode=${matrix_mode}"
	} >>"$GITHUB_OUTPUT"
fi
