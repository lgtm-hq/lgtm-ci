#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract check that both reusable-test-shell twins declare and
#          forward the kcov include path and empty-coverage inputs (#1373)

load "../../helpers/common"

setup() {
	WORKFLOWS=(
		"${PROJECT_ROOT}/.github/workflows/reusable-test-shell.yml"
		"${PROJECT_ROOT}/.github/workflows/reusable-test-shell-run.yml"
	)
}

# Print the body of one workflow_call input (lines after "      <name>:" up to
# the next input at the same indent).
_input_block() {
	awk -v name="$1" '
		$0 == "      " name ":" { show = 1; next }
		show && /^      [a-z#]/ { exit }
		show { print }
	' "$2"
}

@test "reusable-test-shell twins: coverage-include-path input defaults to scripts/ci/lib" {
	local workflow
	for workflow in "${WORKFLOWS[@]}"; do
		run _input_block coverage-include-path "$workflow"
		assert_success
		assert_output --partial "type: string"
		assert_output --partial 'default: "scripts/ci/lib"'
		assert_output --partial "required: false"
	done
}

@test "reusable-test-shell twins: coverage-on-empty input defaults to fail" {
	local workflow
	for workflow in "${WORKFLOWS[@]}"; do
		run _input_block coverage-on-empty "$workflow"
		assert_success
		assert_output --partial "type: string"
		assert_output --partial 'default: "fail"'
		assert_output --partial "required: false"
	done
}

@test "reusable-test-shell twins: run and parse coverage steps forward both inputs" {
	local workflow
	for workflow in "${WORKFLOWS[@]}"; do
		# single-job run + parse, and the sharded run: three steps
		run grep -c 'COVERAGE_INCLUDE_PATHS: ${{ inputs.coverage-include-path }}' "$workflow"
		assert_output "3"
		run grep -c 'COVERAGE_ON_EMPTY: ${{ inputs.coverage-on-empty }}' "$workflow"
		assert_output "4"
	done
}

@test "reusable-test-shell twins: every run-coverage and parse-coverage step carries both env vars" {
	local workflow
	for workflow in "${WORKFLOWS[@]}"; do
		run awk '
			function check() {
				if (step == 1 && !(inc && empty)) bad = 1
			}
			/^      - name:/ { check(); step = 0; inc = 0; empty = 0 }
			/^          STEP: (run|parse)-coverage$/ { step = 1 }
			/COVERAGE_INCLUDE_PATHS: \$\{\{ inputs.coverage-include-path \}\}/ { inc = 1 }
			/COVERAGE_ON_EMPTY: \$\{\{ inputs.coverage-on-empty \}\}/ { empty = 1 }
			END { check(); exit bad }
		' "$workflow"
		assert_success
	done
}

@test "reusable-test-shell twins: merge-coverage step forwards COVERAGE_ON_EMPTY" {
	local workflow
	for workflow in "${WORKFLOWS[@]}"; do
		run awk '
			/^      - name:/ { in_step = 0 }
			/^          STEP: merge-coverage$/ { in_step = 1 }
			in_step && /COVERAGE_ON_EMPTY: \$\{\{ inputs.coverage-on-empty \}\}/ { found = 1 }
			END { exit !found }
		' "$workflow"
		assert_success
	done
}
