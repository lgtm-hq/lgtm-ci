#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Validate and run a caller-owned CI script.

set -euo pipefail

: "${SCRIPT_PATH:?SCRIPT_PATH is required}"
: "${VALIDATION_NAME:=Validation}"
: "${WORKING_DIRECTORY:=.}"
: "${COMMENT_OUTPUT:=validation-comment.md}"
: "${OUTPUT_FILE:=validation-output.txt}"

if [[ -z "${GITHUB_OUTPUT:-}" || ! -w "$GITHUB_OUTPUT" ]]; then
	echo "GITHUB_OUTPUT must be set to a writable file" >&2
	exit 1
fi

if [[ "$SCRIPT_PATH" = /* || "$SCRIPT_PATH" == *".."* ]]; then
	echo "SCRIPT_PATH must be a relative path inside the repository" >&2
	exit 1
fi

resolved_path="$WORKING_DIRECTORY/$SCRIPT_PATH"
if [[ "$OUTPUT_FILE" = /* ]]; then
	output_path="$OUTPUT_FILE"
else
	output_path="$PWD/$OUTPUT_FILE"
fi
if [[ ! -f "$resolved_path" ]]; then
	echo "Validation script does not exist: $resolved_path" >&2
	exit 1
fi

if [[ ! -x "$resolved_path" ]]; then
	chmod +x "$resolved_path"
fi

exit_code=0
(cd "$WORKING_DIRECTORY" && "./$SCRIPT_PATH" >"$output_path" 2>&1) || exit_code=$?
cat "$OUTPUT_FILE"

{
	echo "exit-code=$exit_code"
	if [[ "$exit_code" -eq 0 ]]; then
		echo "status=passed"
	else
		echo "status=failed"
	fi
} >>"$GITHUB_OUTPUT"

if [[ "$exit_code" -ne 0 ]]; then
	cat >"$COMMENT_OUTPUT" <<EOF
<!-- lgtm-ci:validation -->
## ${VALIDATION_NAME} Failed

\`$SCRIPT_PATH\` exited with code \`$exit_code\`.

<details>
<summary>Output</summary>

\`\`\`
$(sed "s/\`\`\`/\` \` \`/g" "$OUTPUT_FILE")
\`\`\`

</details>
EOF
fi

exit 0
