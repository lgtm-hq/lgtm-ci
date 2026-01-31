#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Aggregator for SBOM utilities (sources all sbom/* modules)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/sbom.sh"
#   # Now all sbom functions are available

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_SBOM_LOADED:-}" ]] && return 0
readonly _LGTM_CI_SBOM_LOADED=1

_LGTM_CI_SBOM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/sbom" && pwd)"

# Source all SBOM modules in dependency order
[[ -f "$_LGTM_CI_SBOM_DIR/format.sh" ]] && source "$_LGTM_CI_SBOM_DIR/format.sh"
[[ -f "$_LGTM_CI_SBOM_DIR/severity.sh" ]] && source "$_LGTM_CI_SBOM_DIR/severity.sh"
[[ -f "$_LGTM_CI_SBOM_DIR/target.sh" ]] && source "$_LGTM_CI_SBOM_DIR/target.sh"
