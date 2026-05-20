#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Exit 0 with skipped outputs when PR comments cannot be posted (fork PRs).

set -euo pipefail

: "${EVENT_NAME:=}"
: "${EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME:=}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

if [[ "$EVENT_NAME" != "pull_request" ]]; then
	echo "can-comment=false" >>"$GITHUB_OUTPUT"
	echo "Fork guard: not a pull_request event"
	exit 0
fi

if [[ -z "$EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME" ]]; then
	echo "::error::EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME is required for pull_request events"
	exit 1
fi

if [[ "$EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME" != "$GITHUB_REPOSITORY" ]]; then
	echo "can-comment=false" >>"$GITHUB_OUTPUT"
	echo "Fork guard: skipping comment on fork PR ($EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME)"
	exit 0
fi

echo "can-comment=true" >>"$GITHUB_OUTPUT"
