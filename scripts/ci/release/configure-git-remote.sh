#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Configure git remote URL with an app token
#
# Sets the origin remote URL to use an access token for
# authenticated push operations in CI.
#
# Required environment variables:
#   GH_APP_TOKEN  - GitHub App installation token
#   GH_REPOSITORY - Repository in owner/repo format

set -euo pipefail

: "${GH_APP_TOKEN:?GH_APP_TOKEN is required}"
: "${GH_REPOSITORY:?GH_REPOSITORY is required}"

git remote set-url origin \
	"https://x-access-token:${GH_APP_TOKEN}@github.com/${GH_REPOSITORY}.git"
