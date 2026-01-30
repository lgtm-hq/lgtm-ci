#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Argument parsing for installer scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/args.sh"
#   installer_parse_args "$@"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_INSTALLER_ARGS_LOADED:-}" ]] && return 0
readonly _LGTM_CI_INSTALLER_ARGS_LOADED=1

# =============================================================================
# Argument parsing
# =============================================================================

# Show help message generated from TOOL_* variables
# Expects: TOOL_NAME, TOOL_DESC, TOOL_VERSION (optional), TOOL_EXTRA_HELP (optional)
installer_show_help() {
  local version_info=""
  local upper_name=""
  local help_text=""

  if [[ -n "${TOOL_VERSION:-}" ]]; then
    version_info=" (default: ${TOOL_VERSION})"
    upper_name=$(echo "${TOOL_NAME:-TOOL}" | tr '[:lower:]' '[:upper:]')
  fi

  help_text="${TOOL_DESC:-Install ${TOOL_NAME:-tool}}.

Usage:
  install-${TOOL_NAME:-tool}.sh [--help] [--dry-run]${TOOL_VERSION:+ [--version VERSION]}

Options:
  --help, -h       Show this help message
  --dry-run        Show what would be done without executing"

  if [[ -n "${TOOL_VERSION:-}" ]]; then
    help_text+="
  --version VER    Version to install${version_info}

Environment Variables:
  ${upper_name}_VERSION   Version to install"
  fi

  help_text+="
  BIN_DIR            Installation directory (default: ~/.local/bin)"

  if [[ -n "${TOOL_EXTRA_HELP:-}" ]]; then
    help_text+="

${TOOL_EXTRA_HELP}"
  fi

  echo "$help_text"
}

# Parse standard installer arguments
# Sets: DRY_RUN, TOOL_VERSION (if --version provided)
# Returns: remaining unparsed arguments in INSTALLER_ARGS array
installer_parse_args() {
  INSTALLER_ARGS=()

  # Check for help first
  for arg in "$@"; do
    if [[ "$arg" == "--help" ]] || [[ "$arg" == "-h" ]]; then
      installer_show_help
      exit 0
    fi
  done

  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --version)
        if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
          echo "ERROR: --version requires a version argument" >&2
          exit 1
        fi
        TOOL_VERSION="$2"
        shift 2
        ;;
      -*)
        echo "WARN: Unknown option: $1" >&2
        shift
        ;;
      *)
        INSTALLER_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

# =============================================================================
# Export functions
# =============================================================================
export -f installer_show_help installer_parse_args
