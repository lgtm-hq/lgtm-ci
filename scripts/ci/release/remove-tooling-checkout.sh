#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Remove the temporary lgtm-ci tooling checkout before PR creation.

set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"

if [[ ! -d "$GITHUB_WORKSPACE" ]]; then
	printf '::error::GITHUB_WORKSPACE does not exist: %s\n' "$GITHUB_WORKSPACE" >&2
	exit 1
fi

rm -rf -- "$GITHUB_WORKSPACE/.lgtm-ci-tooling"
printf 'Removed temporary lgtm-ci tooling checkout\n'
