#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Aggregator for installer framework (sources all installer/* modules)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/installer.sh"
#   installer_init
#   installer_parse_args "$@"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_INSTALLER_LOADED:-}" ]] && return 0
readonly _LGTM_CI_INSTALLER_LOADED=1

_LGTM_CI_INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/installer" && pwd)"

# Source all installer modules in dependency order
# Core module is critical - warn if missing
if [[ -f "$_LGTM_CI_INSTALLER_DIR/core.sh" ]]; then
  # shellcheck source=installer/core.sh
  source "$_LGTM_CI_INSTALLER_DIR/core.sh"
else
  echo "[WARN] installer/core.sh not found - installer_init will be unavailable" >&2
fi
[[ -f "$_LGTM_CI_INSTALLER_DIR/args.sh" ]] && source "$_LGTM_CI_INSTALLER_DIR/args.sh"
[[ -f "$_LGTM_CI_INSTALLER_DIR/version.sh" ]] && source "$_LGTM_CI_INSTALLER_DIR/version.sh"
[[ -f "$_LGTM_CI_INSTALLER_DIR/binary.sh" ]] && source "$_LGTM_CI_INSTALLER_DIR/binary.sh"
[[ -f "$_LGTM_CI_INSTALLER_DIR/fallbacks.sh" ]] && source "$_LGTM_CI_INSTALLER_DIR/fallbacks.sh"
