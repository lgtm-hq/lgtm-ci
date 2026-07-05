#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Aggregator for network utilities (sources all network/* modules)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/network.sh"
#   # Now all network functions are available
#
# Loading contract: all network/* modules are required; sourcing fails loudly
# (returns 1 with an error naming the missing module) when one is absent.

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_NETWORK_LOADED:-}" ]] && return 0

_LGTM_CI_NETWORK_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")/network" && pwd)" || {
	echo "network.sh: cannot resolve network modules directory" >&2
	return 1
}

# Source all network modules (all required)
[[ -f "$_LGTM_CI_NETWORK_DIR/port.sh" ]] || {
	echo "network.sh: missing required module port.sh in $_LGTM_CI_NETWORK_DIR" >&2
	return 1
}
# shellcheck source=network/port.sh
source "$_LGTM_CI_NETWORK_DIR/port.sh" || return 1

[[ -f "$_LGTM_CI_NETWORK_DIR/checksum.sh" ]] || {
	echo "network.sh: missing required module checksum.sh in $_LGTM_CI_NETWORK_DIR" >&2
	return 1
}
# shellcheck source=network/checksum.sh
source "$_LGTM_CI_NETWORK_DIR/checksum.sh" || return 1

[[ -f "$_LGTM_CI_NETWORK_DIR/download.sh" ]] || {
	echo "network.sh: missing required module download.sh in $_LGTM_CI_NETWORK_DIR" >&2
	return 1
}
# shellcheck source=network/download.sh
source "$_LGTM_CI_NETWORK_DIR/download.sh" || return 1

readonly _LGTM_CI_NETWORK_LOADED=1
