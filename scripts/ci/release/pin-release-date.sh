#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Write today's date as the release date step output
#
# The prepare job pins the date once, so the changelog and the release
# metadata written by later jobs agree even across midnight. The date is the
# runner's local date, as `date +%Y-%m-%d` gives it.
#
# Required environment variables:
#   GITHUB_OUTPUT - Step output file; receives date=YYYY-MM-DD

set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

release_date="$(date +%Y-%m-%d)"
echo "date=${release_date}" >>"${GITHUB_OUTPUT}"
