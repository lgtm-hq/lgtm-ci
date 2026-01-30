#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: GitHub Actions environment detection utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
#   if is_ci; then echo "Running in CI"; fi

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_GITHUB_ENV_LOADED:-}" ]] && return 0
readonly _LGTM_CI_GITHUB_ENV_LOADED=1

# =============================================================================
# CI environment detection
# =============================================================================

# Check if running in any CI environment
is_ci() {
  [[ -n "${CI:-}" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]]
}

# Check if running in GitHub Actions specifically
is_github_actions() {
  [[ -n "${GITHUB_ACTIONS:-}" ]]
}

# Check if we're in a PR context
# Includes pull_request_target for workflows handling forked PRs
is_pr_context() {
  [[ "${GITHUB_EVENT_NAME:-}" == "pull_request" ]] \
    || [[ "${GITHUB_EVENT_NAME:-}" == "pull_request_target" ]]
}

# Check if we're on the default branch (usually main/master)
# Handles detached HEAD in GitHub Actions by preferring GITHUB_REF_NAME
is_default_branch() {
  local current_branch
  local default_branch="${GITHUB_DEFAULT_BRANCH:-main}"

  if [[ -n "${GITHUB_REF_NAME:-}" ]]; then
    current_branch="$GITHUB_REF_NAME"
  elif [[ -n "${GITHUB_REF:-}" ]]; then
    current_branch="${GITHUB_REF#refs/heads/}"
  else
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  fi

  [[ -n "$current_branch" ]] && [[ "$current_branch" == "$default_branch" ]]
}

# =============================================================================
# Export functions
# =============================================================================
export -f is_ci is_github_actions is_pr_context is_default_branch
