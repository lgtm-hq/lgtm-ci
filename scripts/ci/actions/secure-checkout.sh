#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Verify checkout integrity
#
# Required environment variables:
#   STEP - Which step to run: repo-dir or verify
#   CHECKOUT_PATH - Path input for checkout (for repo-dir step)
#   WORKSPACE - GitHub workspace path
#   REPOSITORY - Repository name
#   PERSIST_CREDENTIALS - Whether credentials should be persisted

set -euo pipefail

: "${STEP:?STEP is required}"

case "$STEP" in
repo-dir)
	: "${WORKSPACE:?WORKSPACE is required}"
	: "${CHECKOUT_PATH:=}"
	if [[ -n "$CHECKOUT_PATH" ]]; then
		echo "path=${WORKSPACE}/${CHECKOUT_PATH}" >>"$GITHUB_OUTPUT"
	else
		echo "path=${WORKSPACE}" >>"$GITHUB_OUTPUT"
	fi
	;;

verify)
	: "${REPOSITORY:?REPOSITORY is required}"
	: "${PERSIST_CREDENTIALS:=false}"

	# Verify we're in a git repository
	if ! git rev-parse --git-dir >/dev/null 2>&1; then
		echo "::error::Checkout verification failed - not a git repository"
		exit 1
	fi

	# Log checkout info
	echo "Repository: $REPOSITORY"
	echo "Commit: $(git rev-parse HEAD)"
	echo "Ref: $(git symbolic-ref -q --short HEAD 2>/dev/null || git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD)"

	# Verify credentials are not persisted (unless explicitly requested)
	if [[ "$PERSIST_CREDENTIALS" != "true" ]]; then
		if git config --get credential.helper >/dev/null 2>&1; then
			echo "::warning::Credential helper is configured despite persist-credentials=false"
		fi
	fi
	;;

*)
	echo "Unknown step: $STEP"
	exit 1
	;;
esac
