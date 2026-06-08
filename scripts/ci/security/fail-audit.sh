#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail the CI job when the security audit found vulnerabilities or errors.
#
# Usage:
#   bash scripts/ci/security/fail-audit.sh

set -euo pipefail

echo "::error::Security audit found vulnerabilities or failed. Review the PR comment and CI logs."
exit 1
