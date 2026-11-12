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
# Keep the tooling checkout out of every `git add` through info/exclude, not
# an exclude pathspec: Git exits 1 when a pathspec names a path that the
# caller's .gitignore already ignores (#1448).
tooling_pattern="/${TOOLING_DIR#./}"
tooling_pattern="${tooling_pattern%/}/"
info_exclude="$(git rev-parse --git-path info/exclude)"
mkdir -p -- "$(dirname -- "$info_exclude")"
if ! grep -qxF -- "$tooling_pattern" "$info_exclude" 2>/dev/null; then
	printf '%s\n' "$tooling_pattern" >>"$info_exclude"
fi

# info/exclude has the lowest precedence: a negation in the caller's
# .gitignore, committed or written by the hook, lets the tooling checkout back
# into the index. Dropping it after every add keeps the exclusion absolute, as
# the exclude pathspec was.
tooling_path="${TOOLING_DIR#./}"
tooling_path="${tooling_path%/}"
stage_without_tooling() {
	git -c advice.addEmbeddedRepo=false add -A .
	# --cached only touches the index; -f skips the up-to-date check that a
	# freshly staged entry fails. The working tree is left alone. The path is
	# literal: a wildcard in it must not match files the caller owns.
	git --literal-pathspecs rm -r -q -f --cached --ignore-unmatch -- "$tooling_path"
}

# Index = prepared state. `git diff --cached <tree>` later yields exactly the
# hook's delta, including files it creates, without the tooling checkout.
stage_without_tooling
snapshot_tree="$(git write-tree)"

# The tooling is a plain directory extracted from prepare's artifact, not a
# checkout (#1451), so its content is recorded as a Git tree in a scratch
# repository outside the workspace. Each snapshot uses a fresh index: Git then
# hashes every file instead of trusting stat data the hook could restore.
tooling_present=false
tooling_git_dir=""
tooling_tree() {
	local index="${tooling_git_dir}/index-$1"
	rm -f -- "$index"
	GIT_INDEX_FILE="$index" git -C "$TOOLING_DIR" --git-dir="$tooling_git_dir" \
		--work-tree=. add -A -f -- .
	GIT_INDEX_FILE="$index" git -C "$TOOLING_DIR" --git-dir="$tooling_git_dir" \
		--work-tree=. write-tree
}
if [[ -d "$TOOLING_DIR" ]]; then
	tooling_present=true
	tooling_git_dir="$(mktemp -d)"
	trap 'rm -rf -- "$tooling_git_dir"' EXIT
	git init -q --bare "$tooling_git_dir"
	tooling_before="$(tooling_tree before)"
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
	tooling_after="$(tooling_tree after)"
	tooling_changes="$(git --git-dir="$tooling_git_dir" diff-tree -r --name-status \
		"$tooling_before" "$tooling_after")"
	if [[ -n "$tooling_changes" ]]; then
		printf '::error title=version-update-script modified lgtm-ci tooling::%s\n' \
			"the hook wrote into ${TOOLING_DIR}; only files of the calling repository may change" >&2
		printf '%s\n' "$tooling_changes" | head -20 >&2
		exit 1
	fi
fi

mkdir -p -- "$OUTPUT_DIR"
diff_path="${OUTPUT_DIR}/version-update.diff"
stage_without_tooling
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
