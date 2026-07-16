#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve SCRIPTS_DIR for composite actions and export it via GITHUB_ENV.
#
# Prefer git toplevel when the action lives inside a checkout; otherwise derive
# the repo root from GITHUB_ACTION_PATH (.../.github/actions/<name>).
#
# Required environment variables:
#   GITHUB_ACTION_PATH - Composite action directory
#   GITHUB_ENV         - GitHub Actions environment file

set -euo pipefail

: "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

action_dir="${GITHUB_ACTION_PATH}"
repo_root="$(
	cd "${action_dir}" && git rev-parse --show-toplevel 2>/dev/null ||
		echo "${action_dir%/.github/actions/*}"
)"

echo "SCRIPTS_DIR=${repo_root}/scripts" >>"${GITHUB_ENV}"
