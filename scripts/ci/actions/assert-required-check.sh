#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail when an upstream reusable job did not pass required outputs.

set -euo pipefail

write_gate_outputs() {
	local exit_code="$1"
	local status="$2"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		echo "exit-code=${exit_code}" >>"${GITHUB_OUTPUT}"
		echo "status=${status}" >>"${GITHUB_OUTPUT}"
	fi
}

if [[ ! ${UPSTREAM_RESULT+x} ]]; then
	echo "::error::UPSTREAM_RESULT not set"
	write_gate_outputs 1 failed
	exit 1
fi

STATUS_EXPECTED="${STATUS_EXPECTED:-passed}"

if [[ "${UPSTREAM_RESULT}" != "success" ]]; then
	echo "::error::Upstream job failed (result=${UPSTREAM_RESULT})"
	write_gate_outputs 1 failed
	exit 1
fi

if [[ -n "${PASSED_OUTPUT:-}" && "${PASSED_OUTPUT}" != "true" ]]; then
	echo "::error::Upstream passed output is not true (passed=${PASSED_OUTPUT})"
	write_gate_outputs 1 failed
	exit 1
fi

if [[ -n "${STATUS_OUTPUT:-}" && "${STATUS_OUTPUT}" != "${STATUS_EXPECTED}" ]]; then
	echo "::error::Upstream status is not ${STATUS_EXPECTED} (status=${STATUS_OUTPUT})"
	write_gate_outputs 1 failed
	exit 1
fi

echo "Required check satisfied (upstream=${UPSTREAM_RESULT})"
write_gate_outputs 0 passed
