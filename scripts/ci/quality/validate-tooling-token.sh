#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail when a reusable workflow mishandles the optional tooling token (#1451).
#
# Usage: bash scripts/ci/quality/validate-tooling-token.sh
#
# Thin entry point: the rules live in validate_tooling_token.py next to this
# file. WORKFLOWS_DIR, ACTIONS_DIR and ALLOWLIST_FILE override the defaults.
#
# Environment:
#   PYTHON             (optional) interpreter with PyYAML; default python3,
#                      or this checkout's .venv when python3 lacks PyYAML
#   ALLOWLIST_CEILING  (optional) number of entries the allowlist must have;
#                      default is the constant committed in the Python file.
#                      For fixtures only: the repository check never sets it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKOUT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
if [[ -z "${REPO_ROOT:-}" ]]; then
	REPO_ROOT="${CHECKOUT_ROOT}"
fi

if [[ -z "${PYTHON:-}" ]]; then
	PYTHON=python3
	if ! "${PYTHON}" -c 'import yaml' 2>/dev/null && [[ -x "${CHECKOUT_ROOT}/.venv/bin/python" ]]; then
		PYTHON="${CHECKOUT_ROOT}/.venv/bin/python"
	fi
fi

args=(
	--workflows-dir "${WORKFLOWS_DIR:-${REPO_ROOT}/.github/workflows}"
	--actions-dir "${ACTIONS_DIR:-${REPO_ROOT}/.github/actions}"
	--allowlist "${ALLOWLIST_FILE:-${SCRIPT_DIR}/tooling-token-allowlist.txt}"
)
if [[ -n "${ALLOWLIST_CEILING:-}" ]]; then
	args+=(--ceiling "${ALLOWLIST_CEILING}")
fi

exec "${PYTHON}" "${SCRIPT_DIR}/validate_tooling_token.py" "${args[@]}"
