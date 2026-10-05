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
#   DIFF_PATH             - Path to version-update.diff from the hook-changes artifact
#   NEXT_VERSION          - Optional; version this job computed
#   EXPECTED_NEXT_VERSION - Optional; version the prepare job handed the hook.
#                           When both are set and differ (a tag landed between
#                           the jobs), the diff was built for another release
#                           and is refused.

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

if [[ -n "${NEXT_VERSION:-}" && -n "${EXPECTED_NEXT_VERSION:-}" && "$NEXT_VERSION" != "$EXPECTED_NEXT_VERSION" ]]; then
	log_error "version drift: the hook ran for ${EXPECTED_NEXT_VERSION} but this job resolved ${NEXT_VERSION}; refusing to apply"
	exit 1
fi

if [[ ! -s "$DIFF_PATH" ]]; then
	log_info "version-update-script made no changes; nothing to apply"
	exit 0
fi

DIFF_PATH="$DIFF_PATH" "$SCRIPT_DIR/check-version-update-diff-scope.sh"

if ! git apply --check --binary -- "$DIFF_PATH"; then
	log_error "version-update diff does not apply cleanly to this workspace"
	exit 1
fi

# --intent-to-add registers files the hook created so change detection and
# the PR commit see them; without it they stay untracked (`??`) and are
# ignored by check-version-files-changed.sh.
git apply --binary --intent-to-add -- "$DIFF_PATH"
log_info "Applied version-update-script changes:"
git apply --stat -- "$DIFF_PATH" | tail -20 >&2
