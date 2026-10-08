#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Deprecation removal gate and known-consumer report (#1082).
#
# Thin entry point for scripts/ci/catalog/deprecations.py, which holds the
# logic and documents it. With no arguments it runs `gate` against origin/main,
# which is what the "Deprecation Gate" CI job calls:
#
#   check-deprecations.sh                  # gate: fail on ungated removals
#   check-deprecations.sh report           # consumers still using each deprecation
#   check-deprecations.sh scan [--write]   # refresh catalog/consumers.yml (needs gh)
#
# Environment:
#   PYTHON                (optional) interpreter with PyYAML; default python3,
#                         or this checkout's .venv when python3 lacks PyYAML
#   DEPRECATION_BASE_REF  (optional) base revision for `gate` when no
#                         arguments are given (default: origin/main)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

if [[ -z "${PYTHON:-}" ]]; then
	PYTHON=python3
	if ! "${PYTHON}" -c 'import yaml' 2>/dev/null && [[ -x "${REPO_ROOT}/.venv/bin/python" ]]; then
		PYTHON="${REPO_ROOT}/.venv/bin/python"
	fi
fi

if [[ $# -eq 0 ]]; then
	set -- gate --base-ref "${DEPRECATION_BASE_REF:-origin/main}"
fi

exec "${PYTHON}" "${SCRIPT_DIR}/deprecations.py" "$@"
