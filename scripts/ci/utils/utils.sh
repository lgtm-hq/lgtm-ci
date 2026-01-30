#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Unified utility library for CI scripts
#
# This file sources all modular utility libraries from scripts/ci/lib/
# For granular imports, source individual files from lib/ directly.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_UTILS_LOADED:-}" ]] && return 0
readonly _LGTM_CI_UTILS_LOADED=1

# Determine library directory
_LGTM_CI_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LGTM_CI_LIB_DIR="${_LGTM_CI_UTILS_DIR}/../lib"

# Source all library modules
# Order matters: log.sh should be first as other modules depend on it

# Core logging (no dependencies)
if [[ -f "$_LGTM_CI_LIB_DIR/log.sh" ]]; then
  # shellcheck source=../lib/log.sh
  source "$_LGTM_CI_LIB_DIR/log.sh"
fi

# Platform detection (no dependencies)
if [[ -f "$_LGTM_CI_LIB_DIR/platform.sh" ]]; then
  # shellcheck source=../lib/platform.sh
  source "$_LGTM_CI_LIB_DIR/platform.sh"
fi

# File system utilities (depends on log.sh)
if [[ -f "$_LGTM_CI_LIB_DIR/fs.sh" ]]; then
  # shellcheck source=../lib/fs.sh
  source "$_LGTM_CI_LIB_DIR/fs.sh"
fi

# Git utilities (no dependencies)
if [[ -f "$_LGTM_CI_LIB_DIR/git.sh" ]]; then
  # shellcheck source=../lib/git.sh
  source "$_LGTM_CI_LIB_DIR/git.sh"
fi

# GitHub Actions utilities (no dependencies)
if [[ -f "$_LGTM_CI_LIB_DIR/github.sh" ]]; then
  # shellcheck source=../lib/github.sh
  source "$_LGTM_CI_LIB_DIR/github.sh"
fi

# Network utilities (depends on log.sh, fs.sh)
if [[ -f "$_LGTM_CI_LIB_DIR/network.sh" ]]; then
  # shellcheck source=../lib/network.sh
  source "$_LGTM_CI_LIB_DIR/network.sh"
fi

# Installer framework (depends on all above)
if [[ -f "$_LGTM_CI_LIB_DIR/installer.sh" ]]; then
  # shellcheck source=../lib/installer.sh
  source "$_LGTM_CI_LIB_DIR/installer.sh"
fi

# =============================================================================
# Additional utility functions (not in separate modules)
# =============================================================================

# Display standardized help message
# Usage: show_help "script_name" "description" "usage_pattern"
show_help() {
  local script_name="$1"
  local description="$2"
  local usage="${3:-}"
  cat <<EOF
Usage: $script_name $usage

$description

Options:
  --help, -h    Show this help message
  --dry-run     Show what would be done without executing
  --verbose     Enable verbose output
EOF
}

export -f show_help
