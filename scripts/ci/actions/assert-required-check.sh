#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail when an upstream reusable job did not pass required outputs.
#
# Two sources of truth, both optional beyond UPSTREAM_RESULT:
#   PASSED_OUTPUT / STATUS_OUTPUT   legacy job-output gate
#   RESULTS_DIR                     results.v1 documents (#1080): every
#                                   <...>/results.json under it must validate
#                                   and carry status "passed" or "no-tests"
#                                   (an empty leg is not a failure, matching
#                                   the passed output); EXPECTED_COUNT pins
#                                   how many legs must be present.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"

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

if [[ -n "${RESULTS_DIR:-}" ]]; then
	# shellcheck source=../lib/testing/results.sh
	source "$SCRIPT_DIR/../lib/testing/results.sh"
	if [[ ! -d "${RESULTS_DIR}" ]]; then
		echo "::error::results directory not found: ${RESULTS_DIR}"
		write_gate_outputs 1 failed
		exit 1
	fi
	legs=()
	while IFS= read -r leg; do legs+=("$leg"); done < <(
		find "${RESULTS_DIR}" -type f -name 'results.json' | LC_ALL=C sort
	)
	if [[ -n "${EXPECTED_COUNT:-}" && ! "${EXPECTED_COUNT}" =~ ^[0-9]+$ ]]; then
		echo "::error::EXPECTED_COUNT must be a non-negative integer (got '${EXPECTED_COUNT}')"
		write_gate_outputs 1 failed
		exit 1
	fi
	if [[ -n "${EXPECTED_COUNT:-}" && "${#legs[@]}" -ne "${EXPECTED_COUNT}" ]]; then
		echo "::error::Expected ${EXPECTED_COUNT} results.json legs under ${RESULTS_DIR}, found ${#legs[@]}"
		write_gate_outputs 1 failed
		exit 1
	fi
	if [[ "${#legs[@]}" -eq 0 ]]; then
		echo "::error::No results.json found under ${RESULTS_DIR}"
		write_gate_outputs 1 failed
		exit 1
	fi
	for leg in "${legs[@]}"; do
		if ! results_v1_validate "$leg"; then
			echo "::error::${leg} does not conform to results.v1"
			write_gate_outputs 1 failed
			exit 1
		fi
		leg_status="$(jq -r .status "$leg")"
		if [[ "$leg_status" != "passed" && "$leg_status" != "no-tests" ]]; then
			echo "::error::${leg} reports status ${leg_status} ($(jq -c .counts "$leg"))"
			write_gate_outputs 1 failed
			exit 1
		fi
	done
	echo "results.v1: ${#legs[@]} leg(s) passed"
fi

echo "Required check satisfied (upstream=${UPSTREAM_RESULT})"
write_gate_outputs 0 passed
