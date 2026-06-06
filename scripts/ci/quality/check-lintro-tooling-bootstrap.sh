#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Detect whether lgtm-ci tooling checkout needs a fallback ref
#
# Required environment variables:
#   GITHUB_OUTPUT - GitHub Actions output file
#
# Optional environment variables:
#   RESOLVE_SCRIPT - Path to resolve-lintro-image.sh in tooling checkout
#   VALIDATE_SCRIPT - Path to validate-lintro-version.sh in tooling checkout

set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"
# shellcheck source=../lib/github/output.sh
source "$SCRIPT_DIR/../lib/github/output.sh"

: "${RESOLVE_SCRIPT:=.lgtm-ci-tooling/scripts/ci/quality/resolve-lintro-image.sh}"
: "${VALIDATE_SCRIPT:=.lgtm-ci-tooling/scripts/ci/quality/validate-lintro-version.sh}"

if [[ -f "$RESOLVE_SCRIPT" && -f "$VALIDATE_SCRIPT" ]]; then
	set_github_output "needs-fallback" "false"
	log_info "Required lintro tooling scripts present at primary ref"
	exit 0
fi

set_github_output "needs-fallback" "true"
log_warn "Required tooling scripts missing at primary ref; bootstrapping from fallback"
