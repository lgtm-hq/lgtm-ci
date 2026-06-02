#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Aggregator for egress preset utilities
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/egress.sh"

[[ -n "${_LGTM_CI_EGRESS_LOADED:-}" ]] && return 0

_LGTM_CI_EGRESS_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")/egress" && pwd)" || {
	echo "egress.sh: cannot resolve egress assets directory" >&2
	return 1
}

[[ -f "$_LGTM_CI_EGRESS_DIR/presets.sh" ]] || {
	echo "egress.sh: missing presets.sh in $_LGTM_CI_EGRESS_DIR" >&2
	return 1
}
source "$_LGTM_CI_EGRESS_DIR/presets.sh"
readonly _LGTM_CI_EGRESS_LOADED=1
