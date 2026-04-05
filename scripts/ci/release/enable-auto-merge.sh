#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Enable auto-merge (squash) on a pull request
#
# Required environment variables:
#   GH_TOKEN  - GitHub token for authentication
#   PR_NUMBER - Pull request number to auto-merge

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"

: "${PR_NUMBER:?PR_NUMBER is required}"

log_info "Enabling auto-merge (squash) for PR #$PR_NUMBER"
gh pr merge "$PR_NUMBER" --auto --squash
log_success "Auto-merge enabled for PR #$PR_NUMBER"
