#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run build-command, optional post-build-test-command, validate artifact path.
#
# Environment:
#   BUILD_COMMAND            (required) Shell command to build artifacts
#   POST_BUILD_TEST_COMMAND  (optional) Shell command after a successful build
#   ARTIFACT_PATH            (required) File or directory that must exist after build
#   WORKING_DIRECTORY        (optional) Directory to run commands in (default: .)

set -euo pipefail

: "${BUILD_COMMAND:?BUILD_COMMAND is required}"
: "${ARTIFACT_PATH:?ARTIFACT_PATH is required}"
: "${POST_BUILD_TEST_COMMAND:=}"
: "${WORKING_DIRECTORY:=.}"

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
