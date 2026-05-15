#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run a validated repo-specific version update script.
#
# Environment variables:
#   SCRIPT_PATH - Validated script path
#   NEXT_VERSION - Version passed through to the script

set -euo pipefail

: "${SCRIPT_PATH:?SCRIPT_PATH is required}"
: "${NEXT_VERSION:?NEXT_VERSION is required}"

"$SCRIPT_PATH"
