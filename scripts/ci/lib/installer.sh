#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Aggregator for installer framework (sources all installer/* modules)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/installer.sh"
#   installer_init
#   installer_parse_args "$@"
#
# Loading contract: all installer/* modules are required; sourcing fails loudly
# (returns 1 with an error naming the missing module) when one is absent.

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_INSTALLER_LOADED:-}" ]] && return 0

_LGTM_CI_INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")/installer" && pwd)" || {
	echo "installer.sh: cannot resolve installer modules directory" >&2
	return 1
}

# Source all installer modules in dependency order (all required)
[[ -f "$_LGTM_CI_INSTALLER_DIR/core.sh" ]] || {
	echo "installer.sh: missing required module core.sh in $_LGTM_CI_INSTALLER_DIR" >&2
	return 1
}
# shellcheck source=installer/core.sh
source "$_LGTM_CI_INSTALLER_DIR/core.sh" || return 1

[[ -f "$_LGTM_CI_INSTALLER_DIR/args.sh" ]] || {
	echo "installer.sh: missing required module args.sh in $_LGTM_CI_INSTALLER_DIR" >&2
	return 1
}
# shellcheck source=installer/args.sh
source "$_LGTM_CI_INSTALLER_DIR/args.sh" || return 1

[[ -f "$_LGTM_CI_INSTALLER_DIR/version.sh" ]] || {
	echo "installer.sh: missing required module version.sh in $_LGTM_CI_INSTALLER_DIR" >&2
	return 1
}
# shellcheck source=installer/version.sh
source "$_LGTM_CI_INSTALLER_DIR/version.sh" || return 1

[[ -f "$_LGTM_CI_INSTALLER_DIR/binary.sh" ]] || {
	echo "installer.sh: missing required module binary.sh in $_LGTM_CI_INSTALLER_DIR" >&2
	return 1
}
# shellcheck source=installer/binary.sh
source "$_LGTM_CI_INSTALLER_DIR/binary.sh" || return 1

[[ -f "$_LGTM_CI_INSTALLER_DIR/fallbacks.sh" ]] || {
	echo "installer.sh: missing required module fallbacks.sh in $_LGTM_CI_INSTALLER_DIR" >&2
	return 1
}
# shellcheck source=installer/fallbacks.sh
source "$_LGTM_CI_INSTALLER_DIR/fallbacks.sh" || return 1

readonly _LGTM_CI_INSTALLER_LOADED=1
