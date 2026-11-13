#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Stage check-tooling-ref-divergence.sh outside the tooling checkout.
#
# The tooling checkout that follows rewrites this composite's own directory to
# the override ref, which may predate the guard (#1368), so the guard is copied
# to RUNNER_TEMP first. On GHES the bootstrap checkout falls back to the
# override ref itself; when that tree predates the guard script, skip the guard
# with a notice instead of failing on an opaque cp error. A cp that fails for
# any other reason still fails the step.
#
# This file comes from the same bootstrap checkout as action.yml, so it is
# trusted to the same degree.
#
# Environment variables:
#   GITHUB_ACTION_PATH   - This composite's directory
#   RUNNER_TEMP          - Staging directory
#   GITHUB_OUTPUT        - Receives staged=true or staged=false
#   TOOLING_REF_OVERRIDE - The caller's raw tooling-ref, named in the notice

set -euo pipefail

src="${GITHUB_ACTION_PATH}/check-tooling-ref-divergence.sh"
if [[ -f "$src" ]]; then
	cp "$src" "${RUNNER_TEMP}/check-tooling-ref-divergence.sh"
	echo "staged=true" >>"${GITHUB_OUTPUT}"
else
	echo "::notice title=tooling-ref divergence::the bootstrap composite predates the" \
		"divergence guard; skipping the check for tooling-ref ${TOOLING_REF_OVERRIDE}"
	echo "staged=false" >>"${GITHUB_OUTPUT}"
fi
