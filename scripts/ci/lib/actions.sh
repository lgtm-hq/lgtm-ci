#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Common initialization for CI action scripts
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/../lib/actions.sh"
#
# This aggregator sources common libraries needed by action scripts:
#   - log.sh (logging utilities)
#   - github.sh (GitHub Actions helpers)
#   - sbom.sh (SBOM utilities, if available)
#   - installer.sh (tool installation, if available)

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_ACTIONS_LOADED:-}" ]] && return 0
readonly _LGTM_CI_ACTIONS_LOADED=1

# Determine library directory relative to this file
_LGTM_CI_ACTIONS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source core libraries (required)
# shellcheck source=log.sh
if [[ -f "$_LGTM_CI_ACTIONS_LIB_DIR/log.sh" ]]; then
	source "$_LGTM_CI_ACTIONS_LIB_DIR/log.sh"
else
	echo "[ERROR] Required library not found: log.sh" >&2
	exit 1
fi
# shellcheck source=github.sh
if [[ -f "$_LGTM_CI_ACTIONS_LIB_DIR/github.sh" ]]; then
	source "$_LGTM_CI_ACTIONS_LIB_DIR/github.sh"
else
	echo "[ERROR] Required library not found: github.sh" >&2
	exit 1
fi

# Source optional libraries (load if available)
# shellcheck source=sbom.sh
[[ -f "$_LGTM_CI_ACTIONS_LIB_DIR/sbom.sh" ]] && source "$_LGTM_CI_ACTIONS_LIB_DIR/sbom.sh"
# shellcheck source=installer.sh
[[ -f "$_LGTM_CI_ACTIONS_LIB_DIR/installer.sh" ]] && source "$_LGTM_CI_ACTIONS_LIB_DIR/installer.sh"
