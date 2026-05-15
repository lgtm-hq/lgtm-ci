#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail a workflow step with a captured command exit code.

set -euo pipefail

: "${EXIT_CODE:?EXIT_CODE is required}"

if [[ ! "$EXIT_CODE" =~ ^[0-9]+$ ]]; then
	echo "::error::Invalid exit code: $EXIT_CODE"
	exit 1
fi

if [[ "$EXIT_CODE" -gt 255 ]]; then
	echo "::error::Exit code out of range: $EXIT_CODE (expected 0-255)"
	exit 1
fi

if [[ "$EXIT_CODE" -ne 0 ]]; then
	echo "::error::Command failed with exit code $EXIT_CODE"
	exit "$EXIT_CODE"
fi
