#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run the caller's version-update-script in the unprivileged
# `version-update-hook` job and capture what it changed as a diff (#849).
#
# Three phases:
#   1. snapshot — stage the prepared workspace (changelog + ecosystem
#      updates already applied by trusted code) so the hook's own edits can
#      be isolated, and make the tooling checkout read-only.
#   2. run — execute SCRIPT_PATH with NEXT_VERSION and RELEASE_METADATA_PATH.
#      No token of any kind is in this job's environment.
#   3. collect — diff the hook's changes (tracked edits plus new files,
#      excluding the tooling checkout) into OUTPUT_DIR/version-update.diff,
#      refuse if the tooling checkout changed, and run the scope check.
#
# Nothing that runs after the hook in this job is trusted: the hook can edit
# this script, git, or the diff. The privileged job re-checks the diff scope
# and `git apply --check`s it before anything touches the repository.
#
# Environment variables:
#   SCRIPT_PATH           - Validated hook path (validate-version-update-script.sh)
#   NEXT_VERSION          - Version passed through to the hook
#   RELEASE_METADATA_PATH - Read-only release-metadata.json for the hook
#   OUTPUT_DIR            - Directory receiving version-update.diff
#   TOOLING_DIR           - lgtm-ci tooling checkout (default .lgtm-ci-tooling)
#   GITHUB_STEP_SUMMARY   - Optional; receives a short summary

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"

: "${SCRIPT_PATH:?SCRIPT_PATH is required}"
: "${NEXT_VERSION:?NEXT_VERSION is required}"
: "${RELEASE_METADATA_PATH:?RELEASE_METADATA_PATH is required}"
: "${OUTPUT_DIR:?OUTPUT_DIR is required}"
TOOLING_DIR="${TOOLING_DIR:-.lgtm-ci-tooling}"

if [[ -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]]; then
	log_error "a GitHub token is present in the hook environment; the hook job must not carry one"
	exit 1
fi

if [[ ! -f "$RELEASE_METADATA_PATH" ]]; then
	log_error "release metadata not found: ${RELEASE_METADATA_PATH}"
	exit 1
fi

git rev-parse --is-inside-work-tree >/dev/null

# --- 1. snapshot ------------------------------------------------------------
# Index = prepared state. `git diff --cached <tree>` later yields exactly the
# hook's delta, including files it creates, without the tooling checkout.
git add -A -- . ":(exclude)${TOOLING_DIR}"
snapshot_tree="$(git write-tree)"

tooling_present=false
if [[ -d "$TOOLING_DIR/.git" ]]; then
	tooling_present=true
	# Honest hooks must not touch tooling; make the mistake loud and early.
	chmod -R a-w "$TOOLING_DIR"
fi

# --- 2. run -----------------------------------------------------------------
chmod 0444 "$RELEASE_METADATA_PATH"
log_info "Running version-update-script ${SCRIPT_PATH} (NEXT_VERSION=${NEXT_VERSION})"
hook_rc=0
env -u GH_TOKEN -u GITHUB_TOKEN \
	NEXT_VERSION="$NEXT_VERSION" \
	RELEASE_METADATA_PATH="$RELEASE_METADATA_PATH" \
	"$SCRIPT_PATH" || hook_rc=$?

if [[ "$tooling_present" == "true" ]]; then
	chmod -R u+w "$TOOLING_DIR"
fi

if [[ "$hook_rc" -ne 0 ]]; then
	log_error "version-update-script exited with status ${hook_rc}"
	exit "$hook_rc"
fi

# --- 3. collect -------------------------------------------------------------
if [[ "$tooling_present" == "true" ]]; then
	tooling_changes="$(git -C "$TOOLING_DIR" status --porcelain --untracked-files=all)"
	if [[ -n "$tooling_changes" ]]; then
		printf '::error title=version-update-script modified lgtm-ci tooling::%s\n' \
			"the hook wrote into ${TOOLING_DIR}; only files of the calling repository may change" >&2
		printf '%s\n' "$tooling_changes" | head -20 >&2
		exit 1
	fi
fi

mkdir -p -- "$OUTPUT_DIR"
diff_path="${OUTPUT_DIR}/version-update.diff"
git add -A -- . ":(exclude)${TOOLING_DIR}"
git diff --cached --binary --no-color --no-ext-diff "$snapshot_tree" >"$diff_path"

DIFF_PATH="$diff_path" "$SCRIPT_DIR/check-version-update-diff-scope.sh"

if [[ -s "$diff_path" ]]; then
	changed="$(git diff --cached --name-only "$snapshot_tree")"
	count="$(printf '%s\n' "$changed" | grep -c . || true)"
	log_info "version-update-script changed ${count} file(s):"
	printf '%s\n' "$changed" | head -20 >&2
else
	count=0
	log_info "version-update-script made no changes"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
	add_github_summary "### Version update hook"
	add_github_summary ""
	add_github_summary "- Script: \`${SCRIPT_PATH}\`"
	add_github_summary "- Files changed: ${count}"
fi
