#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Aggregator for SBOM utilities (sources all sbom/* modules)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/sbom.sh"
#   # Now all sbom functions are available
#
# Loading contract: all sbom/* modules are required; sourcing fails loudly
# (returns 1 with an error naming the missing module) when one is absent.

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_SBOM_LOADED:-}" ]] && return 0

_LGTM_CI_SBOM_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")/sbom" && pwd)" || {
	echo "sbom.sh: cannot resolve sbom modules directory" >&2
	return 1
}

# Source all SBOM modules in dependency order (all required)
[[ -f "$_LGTM_CI_SBOM_DIR/format.sh" ]] || {
	echo "sbom.sh: missing required module format.sh in $_LGTM_CI_SBOM_DIR" >&2
	return 1
}
# shellcheck source=sbom/format.sh
source "$_LGTM_CI_SBOM_DIR/format.sh" || return 1

[[ -f "$_LGTM_CI_SBOM_DIR/severity.sh" ]] || {
	echo "sbom.sh: missing required module severity.sh in $_LGTM_CI_SBOM_DIR" >&2
	return 1
}
# shellcheck source=sbom/severity.sh
source "$_LGTM_CI_SBOM_DIR/severity.sh" || return 1

[[ -f "$_LGTM_CI_SBOM_DIR/target.sh" ]] || {
	echo "sbom.sh: missing required module target.sh in $_LGTM_CI_SBOM_DIR" >&2
	return 1
}
# shellcheck source=sbom/target.sh
source "$_LGTM_CI_SBOM_DIR/target.sh" || return 1

readonly _LGTM_CI_SBOM_LOADED=1
