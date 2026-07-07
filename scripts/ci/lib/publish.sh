#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Aggregator for package publishing utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/publish.sh"
#
# This aggregator sources all publishing-related libraries:
#   - log.sh (logging, loaded first if not already loaded)
#   - publish/version.sh (version extraction)
#   - publish/validate.sh (package validation)
#   - publish/registry.sh (registry availability)
#
# Loading contract: all modules are required; sourcing fails loudly
# (returns 1 with an error naming the missing module) when one is absent.

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_PUBLISH_LOADED:-}" ]] && return 0

# Determine library directory relative to this file
_LGTM_CI_PUBLISH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)" || {
	echo "publish.sh: cannot resolve library directory" >&2
	return 1
}

# Source log.sh first if not already loaded (needed by publish modules)
if [[ -z "${_LGTM_CI_LOG_LOADED:-}" ]]; then
	[[ -f "$_LGTM_CI_PUBLISH_LIB_DIR/log.sh" ]] || {
		echo "publish.sh: missing required module log.sh in $_LGTM_CI_PUBLISH_LIB_DIR" >&2
		return 1
	}
	# shellcheck source=log.sh
	source "$_LGTM_CI_PUBLISH_LIB_DIR/log.sh" || return 1
fi

# Source all publish modules (all required)
[[ -f "$_LGTM_CI_PUBLISH_LIB_DIR/publish/version.sh" ]] || {
	echo "publish.sh: missing required module publish/version.sh in $_LGTM_CI_PUBLISH_LIB_DIR" >&2
	return 1
}
# shellcheck source=publish/version.sh
source "$_LGTM_CI_PUBLISH_LIB_DIR/publish/version.sh" || return 1

[[ -f "$_LGTM_CI_PUBLISH_LIB_DIR/publish/validate.sh" ]] || {
	echo "publish.sh: missing required module publish/validate.sh in $_LGTM_CI_PUBLISH_LIB_DIR" >&2
	return 1
}
# shellcheck source=publish/validate.sh
source "$_LGTM_CI_PUBLISH_LIB_DIR/publish/validate.sh" || return 1

[[ -f "$_LGTM_CI_PUBLISH_LIB_DIR/publish/registry.sh" ]] || {
	echo "publish.sh: missing required module publish/registry.sh in $_LGTM_CI_PUBLISH_LIB_DIR" >&2
	return 1
}
# shellcheck source=publish/registry.sh
source "$_LGTM_CI_PUBLISH_LIB_DIR/publish/registry.sh" || return 1

readonly _LGTM_CI_PUBLISH_LOADED=1
