#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Normalize reusables to .lgtm-ci-tooling egress composite references (#279)
#
# Cross-repo callers resolve ./.github/actions/* from the caller workspace. Check out
# lgtm-ci to .lgtm-ci-tooling first, then use ./.lgtm-ci-tooling/.github/actions/...
#
# Usage:
#   bash scripts/ci/actions/bump-harden-runner-action-ref.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

exec python3 "$SCRIPT_DIR/migrate-egress-via-tooling-checkout.py"
