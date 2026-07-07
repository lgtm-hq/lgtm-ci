#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Aggregator for GitHub Actions utilities (sources all github/* modules)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/github.sh"
#   # Now all github functions are available
#
# Loading contract: all github/* modules are required; sourcing fails loudly
# (returns 1 with an error naming the missing module) when one is absent.

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_GITHUB_LOADED:-}" ]] && return 0

_LGTM_CI_GITHUB_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")/github" && pwd)" || {
	echo "github.sh: cannot resolve github modules directory" >&2
	return 1
}

# Source all GitHub modules in dependency order (all required)
[[ -f "$_LGTM_CI_GITHUB_DIR/env.sh" ]] || {
	echo "github.sh: missing required module env.sh in $_LGTM_CI_GITHUB_DIR" >&2
	return 1
}
# shellcheck source=github/env.sh
source "$_LGTM_CI_GITHUB_DIR/env.sh" || return 1

[[ -f "$_LGTM_CI_GITHUB_DIR/output.sh" ]] || {
	echo "github.sh: missing required module output.sh in $_LGTM_CI_GITHUB_DIR" >&2
	return 1
}
# shellcheck source=github/output.sh
source "$_LGTM_CI_GITHUB_DIR/output.sh" || return 1

[[ -f "$_LGTM_CI_GITHUB_DIR/summary.sh" ]] || {
	echo "github.sh: missing required module summary.sh in $_LGTM_CI_GITHUB_DIR" >&2
	return 1
}
# shellcheck source=github/summary.sh
source "$_LGTM_CI_GITHUB_DIR/summary.sh" || return 1

[[ -f "$_LGTM_CI_GITHUB_DIR/format.sh" ]] || {
	echo "github.sh: missing required module format.sh in $_LGTM_CI_GITHUB_DIR" >&2
	return 1
}
# shellcheck source=github/format.sh
source "$_LGTM_CI_GITHUB_DIR/format.sh" || return 1

readonly _LGTM_CI_GITHUB_LOADED=1
