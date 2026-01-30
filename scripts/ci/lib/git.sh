#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Git helper utilities for CI scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/git.sh"
#   branch=$(get_current_branch)

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_GIT_LOADED:-}" ]] && return 0
readonly _LGTM_CI_GIT_LOADED=1

# =============================================================================
# Git helper functions
# =============================================================================

# Get the root directory of the git repository
get_git_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

# Get the current branch name
get_current_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null
}

# Get the full commit SHA
get_commit_sha() {
  git rev-parse HEAD 2>/dev/null
}

# Get the short commit SHA (exactly 7 characters)
get_short_sha() {
  git rev-parse --short=7 HEAD 2>/dev/null
}

# Check if we're in a git repository
is_git_repo() {
  git rev-parse --git-dir >/dev/null 2>&1
}

# Check if the working directory is clean
# Returns false if not in a git repo or if there are uncommitted changes
is_git_clean() {
  # First check if we're in a git repo
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 1  # Not in a repo = not clean
  fi
  # Run git status and check both exit code and output
  local status_output
  if ! status_output=$(git status --porcelain 2>/dev/null); then
    return 1  # git status failed = not clean
  fi
  [[ -z "$status_output" ]]
}

# Get the remote URL for origin
get_git_remote_url() {
  git remote get-url origin 2>/dev/null
}

# Get the most recent reachable tag from HEAD matching a pattern
# Note: Returns the tag closest to HEAD in commit history, not necessarily
# the highest version number. Use get_tags for version-sorted list.
get_latest_tag() {
  local pattern="${1:-v*}"
  git describe --tags --match "$pattern" --abbrev=0 2>/dev/null
}

# Get list of tags matching a pattern
get_tags() {
  local pattern="${1:-v*}"
  git tag -l "$pattern" --sort=-v:refname 2>/dev/null
}

# Check if a tag exists
tag_exists() {
  local tag="$1"
  [[ -n "$tag" ]] || return 1
  git rev-parse "refs/tags/$tag" >/dev/null 2>&1
}

# =============================================================================
# Export functions
# =============================================================================
export -f get_git_root get_current_branch get_commit_sha get_short_sha
export -f is_git_repo is_git_clean get_git_remote_url
export -f get_latest_tag get_tags tag_exists
