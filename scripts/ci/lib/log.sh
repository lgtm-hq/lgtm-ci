#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Logging utilities for CI scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
#   log_info "Starting process..."

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_LOG_LOADED:-}" ]] && return 0
readonly _LGTM_CI_LOG_LOADED=1

# =============================================================================
# Color codes for terminal output
# =============================================================================
readonly LGTM_CI_RED='\033[0;31m'
readonly LGTM_CI_GREEN='\033[0;32m'
readonly LGTM_CI_YELLOW='\033[1;33m'
readonly LGTM_CI_BLUE='\033[0;34m'
readonly LGTM_CI_NC='\033[0m' # No Color

# Export for compatibility with scripts expecting these names
# shellcheck disable=SC2034
readonly RED="${LGTM_CI_RED}"
# shellcheck disable=SC2034
readonly GREEN="${LGTM_CI_GREEN}"
# shellcheck disable=SC2034
readonly YELLOW="${LGTM_CI_YELLOW}"
# shellcheck disable=SC2034
readonly BLUE="${LGTM_CI_BLUE}"
# shellcheck disable=SC2034
readonly NC="${LGTM_CI_NC}"

# =============================================================================
# Logging functions
# =============================================================================

log_info() {
  echo -e "${LGTM_CI_BLUE}[INFO]${LGTM_CI_NC} $*" >&2
}

log_success() {
  echo -e "${LGTM_CI_GREEN}[SUCCESS]${LGTM_CI_NC} $*" >&2
}

log_warn() {
  echo -e "${LGTM_CI_YELLOW}[WARN]${LGTM_CI_NC} $*" >&2
}

# Alias for backwards compatibility
log_warning() {
  log_warn "$@"
}

log_error() {
  echo -e "${LGTM_CI_RED}[ERROR]${LGTM_CI_NC} $*" >&2
}

log_verbose() {
  # Use string comparison to handle non-numeric VERBOSE values
  [[ "${VERBOSE:-}" == "1" || "${VERBOSE,,:-}" == "true" ]] && echo -e "${LGTM_CI_BLUE}[VERBOSE]${LGTM_CI_NC} $*" >&2 || true
}

# Exit with error message
die() {
  log_error "$@"
  exit 1
}

# =============================================================================
# Export functions
# =============================================================================
export -f log_info log_success log_warn log_warning log_error log_verbose die
