#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run build-command, optional post-build-test-command, validate artifact path.
#
# Environment:
#   BUILD_COMMAND            (required) Shell command to build artifacts
#   POST_BUILD_TEST_COMMAND  (optional) Shell command after a successful build
#   ARTIFACT_PATH            (required) File or directory that must exist after build
#   WORKING_DIRECTORY        (optional) Directory to run commands in (default: .)
#   MATRIX_JSON              (optional) toJson(matrix) for the current leg; each
#                            field is exported to the build command as
#                            MATRIX_<FIELD>, e.g. matrix.target -> MATRIX_TARGET

set -euo pipefail

: "${BUILD_COMMAND:?BUILD_COMMAND is required}"
: "${ARTIFACT_PATH:?ARTIFACT_PATH is required}"
: "${POST_BUILD_TEST_COMMAND:=}"
: "${WORKING_DIRECTORY:=.}"
: "${MATRIX_JSON:=}"

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

build_command="$(trim "$BUILD_COMMAND")"
post_build_test_command="$(trim "$POST_BUILD_TEST_COMMAND")"
artifact_path="$(trim "$ARTIFACT_PATH")"
working_directory="$(trim "$WORKING_DIRECTORY")"

if [[ -z "$build_command" ]]; then
	echo "::error::BUILD_COMMAND must not be empty" >&2
	exit 1
fi

if [[ -z "$artifact_path" ]]; then
	echo "::error::ARTIFACT_PATH must not be empty" >&2
	exit 1
fi

if [[ ! -d "$working_directory" ]]; then
	echo "::error::Working directory does not exist: ${working_directory}" >&2
	exit 1
fi

# Export the matrix leg so build commands can branch on it (a cross-compile
# matrix needs matrix.target as `cargo build --target "$MATRIX_TARGET"`).
if [[ -n "$(trim "$MATRIX_JSON")" ]]; then
	matrix_env_file="$(mktemp)"
	export MATRIX_JSON
	# Not a process substitution: a parser failure must fail the build step.
	python3 - >"$matrix_env_file" <<'PY'
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

for key, value in entry.items():
    name = "MATRIX_" + re.sub(r"[^A-Za-z0-9]+", "_", str(key)).upper()
    if not re.fullmatch(r"MATRIX_[A-Za-z_][A-Za-z0-9_]*", name):
        continue
    sys.stdout.write(f"{name}\0{value}\0")
PY
	while IFS= read -r -d '' name && IFS= read -r -d '' value; do
		export "${name}=${value}"
		echo "Matrix field exported: ${name}"
	done <"$matrix_env_file"
	rm -f "$matrix_env_file"
fi

cd "$working_directory"
echo "Running build command in ${working_directory}"
# env -u BASH_ENV: kcov instruments nested bash via BASH_ENV; its injected
# script trips `set -u` inside user commands, which are not coverage targets.
env -u BASH_ENV bash -e -u -o pipefail -c "$build_command"

if [[ -n "$post_build_test_command" ]]; then
	echo "Running post-build test command"
	env -u BASH_ENV bash -e -u -o pipefail -c "$post_build_test_command"
else
	echo "No post-build-test-command set; skipping"
fi

if [[ ! -e "$artifact_path" ]]; then
	echo "::error::artifact-path does not exist after build: ${artifact_path}" >&2
	exit 1
fi

echo "Artifact path ready: ${artifact_path}"
