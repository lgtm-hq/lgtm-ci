#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: GitHub Actions integration utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/github.sh"
#   set_github_output "version" "1.0.0"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_GITHUB_LOADED:-}" ]] && return 0
readonly _LGTM_CI_GITHUB_LOADED=1

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
# GitHub Actions output/environment helpers
# =============================================================================

# Set a GitHub Actions output variable
# Usage: set_github_output "key" "value"
set_github_output() {
  local key="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "$key=$value" >>"$GITHUB_OUTPUT"
  fi
}

# Set a multiline GitHub Actions output variable
# Usage: set_github_output_multiline "key" "multiline value"
set_github_output_multiline() {
  local key="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    # Use unique delimiter to prevent content collision
    local delimiter="LGTM_CI_EOF_$$_$(date +%s)"
    {
      echo "$key<<$delimiter"
      echo "$value"
      echo "$delimiter"
    } >>"$GITHUB_OUTPUT"
  fi
}

# Set a GitHub Actions environment variable
# Usage: set_github_env "key" "value"
set_github_env() {
  local key="$1"
  local value="$2"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "$key=$value" >>"$GITHUB_ENV"
  fi
}

# Add path to GitHub Actions PATH
# Usage: add_github_path "/some/path"
add_github_path() {
  local path="$1"
  if [[ -n "${GITHUB_PATH:-}" ]] && [[ -d "$path" ]]; then
    echo "$path" >>"$GITHUB_PATH"
  fi
}

# Configure git user for CI commits (github-actions[bot])
configure_git_ci_user() {
  git config user.name "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"
}

# =============================================================================
# GitHub Actions step summary helpers
# =============================================================================

# Add content to the GitHub Actions step summary
# Usage: add_github_summary "## Results" "Some content"
add_github_summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "$*" >>"$GITHUB_STEP_SUMMARY"
  fi
}

# =============================================================================
# GitHub Pages URL helpers
# =============================================================================

# Construct GitHub Pages URL for a given path
# Usage: get_github_pages_url "playwright" -> https://owner.github.io/repo/playwright/
# Usage: get_github_pages_url "lighthouse" "lgtm-hq/turbo-themes"
get_github_pages_url() {
  local path="${1:-}"
  local repo="${2:-${GITHUB_REPOSITORY:-}}"

  if [[ -z "$repo" ]]; then
    echo ""
    return 1
  fi

  local repo_owner="${repo%%/*}"
  local repo_name="${repo#*/}"

  if [[ -z "$repo_owner" || -z "$repo_name" ]]; then
    echo ""
    return 1
  fi

  # Normalize owner to lowercase for GitHub Pages domain
  local repo_owner_lower
  repo_owner_lower=$(echo "$repo_owner" | tr '[:upper:]' '[:lower:]')
  local repo_name_lower
  repo_name_lower=$(echo "$repo_name" | tr '[:upper:]' '[:lower:]')

  # Handle user pages repos (repo name equals owner.github.io)
  local base_url
  if [[ "$repo_name_lower" == "${repo_owner_lower}.github.io" ]]; then
    base_url="https://${repo_owner_lower}.github.io"
  else
    base_url="https://${repo_owner_lower}.github.io/${repo_name}"
  fi

  if [[ -n "$path" ]]; then
    echo "${base_url}/${path}/"
  else
    echo "${base_url}/"
  fi
}

# =============================================================================
# Score formatting helpers for PR comments
# =============================================================================

# Format a numeric score with color-coded emoji indicator
# Usage: format_score_with_color 95 -> "🟢 95"
# Usage: format_score_with_color 75 80 -> "🔴 75" (custom threshold)
# Thresholds: 🟢 >= 90, 🟡 >= threshold (default 80), 🔴 < threshold
format_score_with_color() {
  local score="$1"
  local threshold="${2:-80}"

  if [[ "$score" == "N/A" || -z "$score" ]]; then
    echo "⚪ N/A"
  elif [[ "$score" -ge 90 ]] 2>/dev/null; then
    echo "🟢 $score"
  elif [[ "$score" -ge "$threshold" ]] 2>/dev/null; then
    echo "🟡 $score"
  else
    echo "🔴 $score"
  fi
}

# Format a percentage with color-coded emoji indicator
# Usage: format_percentage_with_color 95.5 -> "🟢 95.5%"
# Note: Uses awk for float comparisons (POSIX-compatible, no bc dependency)
format_percentage_with_color() {
  local pct="$1"
  local threshold="${2:-80}"

  if [[ "$pct" == "N/A" || -z "$pct" ]]; then
    echo "⚪ N/A"
    return
  fi

  # Use awk for float comparison (POSIX-compatible)
  if awk "BEGIN { exit !($pct >= 90) }" 2>/dev/null; then
    echo "🟢 ${pct}%"
  elif awk "BEGIN { exit !($pct >= $threshold) }" 2>/dev/null; then
    echo "🟡 ${pct}%"
  else
    echo "🔴 ${pct}%"
  fi
}

# =============================================================================
# Export functions
# =============================================================================
export -f is_ci is_github_actions is_pr_context is_default_branch
export -f set_github_output set_github_output_multiline set_github_env add_github_path
export -f configure_git_ci_user add_github_summary
export -f get_github_pages_url format_score_with_color format_percentage_with_color
