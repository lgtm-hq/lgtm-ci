#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Apply the diff produced by the unprivileged version-update-hook
# job to the privileged job's workspace (#849).
#
# The diff is untrusted data: caller code produced it in a job with no
# secrets, and this is the only point where its content reaches a job that
# holds the App installation token. It is scope-checked, then dry-run with
# `git apply --check`, and only then applied to the working tree. Nothing
# from the artifact is executed.
#
# Environment variables:
#   DIFF_PATH - Path to version-update.diff from the version-update-changes artifact

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"

: "${DIFF_PATH:?DIFF_PATH is required}"

if [[ ! -f "$DIFF_PATH" ]]; then
	log_error "version-update diff not found: ${DIFF_PATH} (did the version-update-hook job upload it?)"
	exit 1
fi

git rev-parse --is-inside-work-tree >/dev/null

if [[ ! -s "$DIFF_PATH" ]]; then
	log_info "version-update-script made no changes; nothing to apply"
	exit 0
fi

DIFF_PATH="$DIFF_PATH" "$SCRIPT_DIR/check-version-update-diff-scope.sh"

if ! git apply --check --binary -- "$DIFF_PATH"; then
	log_error "version-update diff does not apply cleanly to this workspace"
	exit 1
fi

git apply --binary -- "$DIFF_PATH"
log_info "Applied version-update-script changes:"
git apply --stat -- "$DIFF_PATH" | tail -20 >&2
