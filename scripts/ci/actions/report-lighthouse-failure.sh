#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Report why a Lighthouse run failed, then fail the step
#
# The run-lighthouse action's "Check result" step runs only after a failure:
# an audit below threshold, a non-zero lhci exit, or both. Each cause gets one
# line; the exit status is always 1.
#
# Environment variables:
#   AUDIT_FAILED   - "true" when the parsed audit is below threshold
#   AUDIT_ERROR    - The ::error:: line naming the failed categories
#   LIGHTHOUSE_EXIT_CODE - lhci's exit code (empty or 0 when it succeeded)

set -euo pipefail

if [[ "${AUDIT_FAILED:-}" == true ]]; then
	echo "${AUDIT_ERROR:-}"
fi
if [[ "${LIGHTHOUSE_EXIT_CODE:-0}" != 0 ]]; then
	echo "::error::Lighthouse CI exited with code ${LIGHTHOUSE_EXIT_CODE}"
fi
exit 1
