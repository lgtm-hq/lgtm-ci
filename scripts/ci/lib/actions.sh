#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Common initialization for CI action scripts
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
#   source "$SCRIPT_DIR/../lib/actions.sh"
#
# This aggregator sources common libraries needed by action scripts:
#   - log.sh (logging utilities)
#   - github.sh (GitHub Actions helpers)
#   - sbom.sh (SBOM utilities)
#   - installer.sh (tool installation)
#
# Loading contract: all libraries are required; sourcing fails loudly
# (returns 1 with an error naming the missing library) when one is absent.

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_ACTIONS_LOADED:-}" ]] && return 0

# Determine library directory relative to this file
_LGTM_CI_ACTIONS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)" || {
	echo "actions.sh: cannot resolve library directory" >&2
	return 1
}

# Source all libraries (all required)
[[ -f "$_LGTM_CI_ACTIONS_LIB_DIR/log.sh" ]] || {
	echo "actions.sh: missing required library log.sh in $_LGTM_CI_ACTIONS_LIB_DIR" >&2
	return 1
}
# shellcheck source=log.sh
source "$_LGTM_CI_ACTIONS_LIB_DIR/log.sh" || return 1

[[ -f "$_LGTM_CI_ACTIONS_LIB_DIR/github.sh" ]] || {
	log_error "actions.sh: missing required library github.sh in $_LGTM_CI_ACTIONS_LIB_DIR"
	return 1
}
# shellcheck source=github.sh
source "$_LGTM_CI_ACTIONS_LIB_DIR/github.sh" || return 1

[[ -f "$_LGTM_CI_ACTIONS_LIB_DIR/sbom.sh" ]] || {
	log_error "actions.sh: missing required library sbom.sh in $_LGTM_CI_ACTIONS_LIB_DIR"
	return 1
}
# shellcheck source=sbom.sh
source "$_LGTM_CI_ACTIONS_LIB_DIR/sbom.sh" || return 1

[[ -f "$_LGTM_CI_ACTIONS_LIB_DIR/installer.sh" ]] || {
	log_error "actions.sh: missing required library installer.sh in $_LGTM_CI_ACTIONS_LIB_DIR"
	return 1
}
# shellcheck source=installer.sh
source "$_LGTM_CI_ACTIONS_LIB_DIR/installer.sh" || return 1

readonly _LGTM_CI_ACTIONS_LOADED=1
