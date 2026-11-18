#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Wait a fixed number of seconds before a retry
#
# Used between a failed artifact download and its retry, when the listing can
# lag behind the upload (#803).
#
# Required environment variables:
#   PAUSE_SECONDS - Whole seconds to wait, 0 to 600

set -euo pipefail

: "${PAUSE_SECONDS:?PAUSE_SECONDS is required}"

if [[ ! "${PAUSE_SECONDS}" =~ ^[0-9]+$ ]] || ((10#${PAUSE_SECONDS} > 600)); then
	echo "::error::PAUSE_SECONDS must be a whole number of seconds from 0 to 600 (got '${PAUSE_SECONDS}')" >&2
	exit 1
fi

sleep "$((10#${PAUSE_SECONDS}))"
