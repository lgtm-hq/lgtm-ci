#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run a caller-provided command from a reusable workflow input.

set -euo pipefail

: "${COMMAND:?COMMAND is required}"
: "${WORKING_DIRECTORY:=.}"

if [[ ! -d "$WORKING_DIRECTORY" ]]; then
	echo "Working directory does not exist: $WORKING_DIRECTORY" >&2
	exit 1
fi

cd "$WORKING_DIRECTORY"
echo "Running command in $WORKING_DIRECTORY"
bash -c "$COMMAND"
