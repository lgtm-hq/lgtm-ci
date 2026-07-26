#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve the upload artifact name for reusable-build-artifact.
#
# Single-version mode keeps the caller artifact-name verbatim. Matrix mode
# appends the matrix leg's values so parallel legs do not collide. For the
# legacy Node matrix that suffix is the node version (js-dist-20), which is
# exactly what MATRIX_JSON yields for a {"node-version":"20"} leg.
#
# Environment:
#   ARTIFACT_NAME   (required) Base artifact name from the workflow input
#   MATRIX_MODE     (required) true when the build runs a multi-leg matrix
#   MATRIX_JSON     (optional) toJson(matrix) for the current leg; preferred
#                   source of the suffix. The injected "runner" field is
#                   excluded so runner-map does not change artifact names.
#   NODE_VERSION    (optional) Legacy suffix source when MATRIX_JSON is unset
#   GITHUB_OUTPUT   (required) Writes artifact-name=

set -euo pipefail

: "${ARTIFACT_NAME:?ARTIFACT_NAME is required}"
: "${MATRIX_MODE:?MATRIX_MODE is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${MATRIX_JSON:=}"
: "${NODE_VERSION:=}"

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

artifact_name="$(trim "$ARTIFACT_NAME")"
node_version="$(trim "$NODE_VERSION")"
matrix_mode="$(trim "$MATRIX_MODE")"
matrix_json="$(trim "$MATRIX_JSON")"

if [[ -z "$artifact_name" ]]; then
	echo "::error::ARTIFACT_NAME must not be empty" >&2
	exit 1
fi

suffix=""
if [[ "$matrix_mode" == "true" ]]; then
	if [[ -n "$matrix_json" ]]; then
		suffix="$(
			MATRIX_JSON="$matrix_json" python3 - <<'PY'
import json
import os
import re
import sys

raw = os.environ["MATRIX_JSON"]
try:
    entry = json.loads(raw)
except json.JSONDecodeError as exc:
    print(f"MATRIX_JSON must be valid JSON: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(entry, dict):
    print("MATRIX_JSON must be a JSON object", file=sys.stderr)
    sys.exit(1)

# "runner" is injected by generate-build-matrix.sh for runner-map routing and
# is deliberately not part of the artifact identity.
parts = [
    str(value)
    for key, value in entry.items()
    if key != "runner" and str(value).strip()
]
print(re.sub(r"[^A-Za-z0-9._-]+", "-", "-".join(parts)).strip("-"))
PY
		)"
	fi
	if [[ -z "$suffix" ]]; then
		suffix="$node_version"
	fi
	if [[ -z "$suffix" ]]; then
		echo "::error::Matrix mode needs MATRIX_JSON or NODE_VERSION to build a suffix" >&2
		exit 1
	fi
fi

resolved="$artifact_name"
if [[ -n "$suffix" ]]; then
	resolved="${artifact_name}-${suffix}"
fi

echo "Resolved artifact name: ${resolved}"
echo "artifact-name=${resolved}" >>"$GITHUB_OUTPUT"
