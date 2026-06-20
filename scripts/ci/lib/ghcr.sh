#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Barrel file for GHCR library modules
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/ghcr.sh"

[[ -n "${_LGTM_CI_GHCR_LOADED:-}" ]] && return 0
readonly _LGTM_CI_GHCR_LOADED=1

_GHCR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")/ghcr" && pwd)"

# shellcheck source=ghcr/registry.sh
source "$_GHCR_LIB_DIR/registry.sh"
# shellcheck source=ghcr/tags.sh
source "$_GHCR_LIB_DIR/tags.sh"
