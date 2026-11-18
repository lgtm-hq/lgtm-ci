#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Write the login of a pull request's author as a step output
#
# Required environment variables:
#   GH_TOKEN      - Token gh reads the pull request with
#   PR_NUMBER     - The pull request number
#   GITHUB_OUTPUT - Step output file; receives author=<login>

set -euo pipefail

: "${PR_NUMBER:?PR_NUMBER is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

author="$(gh pr view "${PR_NUMBER}" --json author --jq '.author.login')"
echo "author=${author}" >>"${GITHUB_OUTPUT}"
