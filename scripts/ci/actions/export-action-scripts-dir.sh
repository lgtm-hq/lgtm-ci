#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Export SCRIPTS_DIR, the scripts/ directory next to a composite action
#
# The composite actions under .github/actions/<name> call
# "$SCRIPTS_DIR/ci/...". This resolves SCRIPTS_DIR as
# $GITHUB_ACTION_PATH/../../../scripts, the scripts/ of the checkout the action
# was loaded from, and appends it to GITHUB_ENV (#1624: it was an inline step in
# each action). Unlike resolve-scripts-dir.sh it never asks git: an action
# loaded from a tarball or a sparse tree must still find its own scripts/.
#
# Required environment variables:
#   GITHUB_ACTION_PATH - The composite action's directory
#   GITHUB_ENV         - GitHub Actions environment file

set -euo pipefail

: "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

scripts_dir="$(cd "${GITHUB_ACTION_PATH}/../../../scripts" && pwd)"
echo "SCRIPTS_DIR=${scripts_dir}" >>"${GITHUB_ENV}"
