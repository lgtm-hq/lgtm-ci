#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Deprecation removal gate and known-consumer report (#1082).
#
# Thin entry point for scripts/ci/catalog/deprecations.py, which holds the
# logic and documents it. With no arguments it runs `gate`, which is what the
# "Deprecation Gate" CI job calls. In GitHub Actions the base is HEAD^1: the
# checkout is the PR merge commit (or merge-queue / pushed commit), whose
# first parent is exactly what the change was built on, while a fresh
# origin/main may have moved on and would blame the PR for newer commits.
# Locally the base is origin/main:
#
#   check-deprecations.sh                  # gate: fail on ungated removals
#   check-deprecations.sh report           # consumers still using each deprecation
#   check-deprecations.sh scan [--write]   # refresh catalog/consumers.yml (needs gh)
#
# Environment:
#   PYTHON                (optional) interpreter with PyYAML; default python3,
#                         or this checkout's .venv when python3 lacks PyYAML
#   DEPRECATION_BASE_REF  (optional) base revision for `gate` when no
#                         arguments are given (default: HEAD^1 in GitHub
#                         Actions, origin/main elsewhere)

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
	default_base=origin/main
	if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
		default_base="HEAD^1"
	fi
	set -- gate --base-ref "${DEPRECATION_BASE_REF:-${default_base}}"
fi

exec "${PYTHON}" "${SCRIPT_DIR}/deprecations.py" "$@"
