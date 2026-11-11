#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail when a reusable workflow mishandles the optional tooling token (#1451).
#
# Usage: bash scripts/ci/quality/validate-tooling-token.sh
#
# Thin entry point: the rules live in validate_tooling_token.py next to this
# file. WORKFLOWS_DIR, ACTIONS_DIR and ALLOWLIST_FILE override the defaults.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${REPO_ROOT:-}" ]]; then
	REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
fi

exec python3 "${SCRIPT_DIR}/validate_tooling_token.py" \
	--workflows-dir "${WORKFLOWS_DIR:-${REPO_ROOT}/.github/workflows}" \
	--actions-dir "${ACTIONS_DIR:-${REPO_ROOT}/.github/actions}" \
	--allowlist "${ALLOWLIST_FILE:-${SCRIPT_DIR}/tooling-token-allowlist.txt}"
