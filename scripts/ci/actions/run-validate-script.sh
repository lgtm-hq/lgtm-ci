#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Validate and run a caller-owned CI script.
#
# The failure comment inserts the validation name and script path (caller
# inputs) and the script's output through the shared sanitiser (#1676,
# docs/comment-sanitize.md).

set -euo pipefail

# shellcheck source=../lib/github/comment_sanitize.sh
source "$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)/../lib/github/comment_sanitize.sh"

: "${SCRIPT_PATH:?SCRIPT_PATH is required}"
: "${VALIDATION_NAME:=Validation}"
: "${WORKING_DIRECTORY:=.}"
: "${COMMENT_OUTPUT:=validation-report.md}"
: "${OUTPUT_FILE:=validation-output.txt}"

if [[ -z "${GITHUB_OUTPUT:-}" || ! -w "$GITHUB_OUTPUT" ]]; then
	echo "GITHUB_OUTPUT must be set to a writable file" >&2
	exit 1
fi

if [[ "$SCRIPT_PATH" = /* || "$SCRIPT_PATH" == *".."* ]]; then
	echo "SCRIPT_PATH must be a relative path inside the repository" >&2
	exit 1
fi

resolved_path="$WORKING_DIRECTORY/$SCRIPT_PATH" # comment-safe: path only
if [[ "$OUTPUT_FILE" = /* ]]; then
	output_path="$OUTPUT_FILE" # comment-safe: path only
else
	output_path="$PWD/$OUTPUT_FILE" # comment-safe: path only
fi
if [[ ! -f "$resolved_path" ]]; then
	echo "Validation script does not exist: $resolved_path" >&2
	exit 1
fi

if [[ ! -x "$resolved_path" ]]; then
	chmod +x "$resolved_path"
fi

exit_code=0
(cd "$WORKING_DIRECTORY" && "./$SCRIPT_PATH" >"$output_path" 2>&1) || exit_code=$? # comment-safe: runs the script
cat "$OUTPUT_FILE"                                                                 # comment-safe: job log, not the comment

{
	echo "exit-code=$exit_code"
	if [[ "$exit_code" -eq 0 ]]; then
		echo "status=passed"
	else
		echo "status=failed"
	fi
} >>"$GITHUB_OUTPUT"

if [[ "$exit_code" -ne 0 ]]; then
	name_text="$(printf '%s' "$VALIDATION_NAME" | comment_sanitize text)"
	path_code="$(printf '%s' "$SCRIPT_PATH" | comment_sanitize code)"
	output_block="$(comment_sanitize fence <"$OUTPUT_FILE")"
	# No <!-- lgtm-ci: line here: post-pr-comment writes the marker and
	# neutralises that namespace in bodies (#1674).
	cat >"$COMMENT_OUTPUT" <<EOF
## ${name_text} Failed

${path_code} exited with code \`$exit_code\`.

<details>
<summary>Output</summary>

${output_block}

</details>
EOF
fi

exit 0
