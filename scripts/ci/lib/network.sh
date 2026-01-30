#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Aggregator for network utilities (sources all network/* modules)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/network.sh"
#   # Now all network functions are available

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_NETWORK_LOADED:-}" ]] && return 0
readonly _LGTM_CI_NETWORK_LOADED=1

_LGTM_CI_NETWORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/network" && pwd)"

# Source all network modules
[[ -f "$_LGTM_CI_NETWORK_DIR/port.sh" ]] && source "$_LGTM_CI_NETWORK_DIR/port.sh"
[[ -f "$_LGTM_CI_NETWORK_DIR/checksum.sh" ]] && source "$_LGTM_CI_NETWORK_DIR/checksum.sh"
[[ -f "$_LGTM_CI_NETWORK_DIR/download.sh" ]] && source "$_LGTM_CI_NETWORK_DIR/download.sh"
