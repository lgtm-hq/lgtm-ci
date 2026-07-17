#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Notification utilities library aggregator
#
# Sources all notification libraries for convenient single-file import.
# Usage: source "scripts/ci/lib/notify.sh"
#
# Loading contract: all notify/* modules are required; sourcing fails loudly
# (returns 1 with an error naming the missing module) when one is absent.

# Guard against multiple sourcing
[[ -n "${_LGTM_CI_NOTIFY_LOADED:-}" ]] && return 0

# Get the directory of this script
NOTIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)" || {
	echo "notify.sh: cannot resolve library directory" >&2
	return 1
}

# Source all notify sub-libraries in dependency order (all required)
[[ -f "$NOTIFY_LIB_DIR/notify/context.sh" ]] || {
	echo "notify.sh: missing required module notify/context.sh in $NOTIFY_LIB_DIR" >&2
	return 1
}
# shellcheck source=./notify/context.sh
source "$NOTIFY_LIB_DIR/notify/context.sh" || return 1

[[ -f "$NOTIFY_LIB_DIR/notify/fields.sh" ]] || {
	echo "notify.sh: missing required module notify/fields.sh in $NOTIFY_LIB_DIR" >&2
	return 1
}
# shellcheck source=./notify/fields.sh
source "$NOTIFY_LIB_DIR/notify/fields.sh" || return 1

[[ -f "$NOTIFY_LIB_DIR/notify/payload.sh" ]] || {
	echo "notify.sh: missing required module notify/payload.sh in $NOTIFY_LIB_DIR" >&2
	return 1
}
# shellcheck source=./notify/payload.sh
source "$NOTIFY_LIB_DIR/notify/payload.sh" || return 1

[[ -f "$NOTIFY_LIB_DIR/notify/deliver.sh" ]] || {
	echo "notify.sh: missing required module notify/deliver.sh in $NOTIFY_LIB_DIR" >&2
	return 1
}
# shellcheck source=./notify/deliver.sh
source "$NOTIFY_LIB_DIR/notify/deliver.sh" || return 1

readonly _LGTM_CI_NOTIFY_LOADED=1
