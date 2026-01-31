#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Aggregator for package publishing utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/publish.sh"
#
# This aggregator sources all publishing-related libraries:
#   - publish/version.sh (version extraction)
#   - publish/validate.sh (package validation)
#   - publish/registry.sh (registry availability)
#   - publish/homebrew.sh (Homebrew formula generation)

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_PUBLISH_LOADED:-}" ]] && return 0
readonly _LGTM_CI_PUBLISH_LOADED=1

# Determine library directory relative to this file
_LGTM_CI_PUBLISH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source log.sh first if not already loaded (needed by publish modules)
if [[ -z "${_LGTM_CI_LOG_LOADED:-}" ]]; then
	# shellcheck source=log.sh
	[[ -f "$_LGTM_CI_PUBLISH_LIB_DIR/log.sh" ]] && source "$_LGTM_CI_PUBLISH_LIB_DIR/log.sh"
fi

# Source all publish modules
# shellcheck source=publish/version.sh
[[ -f "$_LGTM_CI_PUBLISH_LIB_DIR/publish/version.sh" ]] && source "$_LGTM_CI_PUBLISH_LIB_DIR/publish/version.sh"

# shellcheck source=publish/validate.sh
[[ -f "$_LGTM_CI_PUBLISH_LIB_DIR/publish/validate.sh" ]] && source "$_LGTM_CI_PUBLISH_LIB_DIR/publish/validate.sh"

# shellcheck source=publish/registry.sh
[[ -f "$_LGTM_CI_PUBLISH_LIB_DIR/publish/registry.sh" ]] && source "$_LGTM_CI_PUBLISH_LIB_DIR/publish/registry.sh"

# shellcheck source=publish/homebrew.sh
[[ -f "$_LGTM_CI_PUBLISH_LIB_DIR/publish/homebrew.sh" ]] && source "$_LGTM_CI_PUBLISH_LIB_DIR/publish/homebrew.sh"
