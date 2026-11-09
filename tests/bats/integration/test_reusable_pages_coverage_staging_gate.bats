#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests that Pages coverage staging/generation only runs when
# the pages-upload-gate says the upload will happen (#1311)

load "../../helpers/common"

# Succeeds when the named step's `if:` references the upload gate output.
# Args: workflow file, step name.
_step_if_references_gate() {
	local workflow="$1"
	local step_name="$2"
	awk -v step_name="$step_name" '
		/^      - name: / {
			in_step = ($0 == "      - name: " step_name)
			in_if = 0
		}
		in_step && /^        if:/ { in_if = 1 }
		in_step && in_if && /^        [a-z-]+:/ && !/^        if:/ { in_if = 0 }
		in_step && in_if && /steps\.pages-upload-gate\.outputs\.should-upload == .true./ {
			found = 1
		}
		END { exit !found }
	' "$workflow"
}

# Succeeds when the gate step is defined before the named step.
_gate_precedes_step() {
	local workflow="$1"
	local step_name="$2"
	awk -v step_name="$step_name" '
		/^        id: pages-upload-gate$/ { gate_seen = 1 }
		$0 == "      - name: " step_name { if (gate_seen) ok = 1; exit }
		END { exit !ok }
	' "$workflow"
}

@test "reusable-test-node: staging step gated on pages-upload-gate" {
	run _step_if_references_gate \
		"${PROJECT_ROOT}/.github/workflows/reusable-test-node.yml" "Stage pages coverage HTML"
	assert_success
}

@test "reusable-test-node-run: staging step gated on pages-upload-gate" {
	run _step_if_references_gate \
		"${PROJECT_ROOT}/.github/workflows/reusable-test-node-run.yml" "Stage pages coverage HTML"
	assert_success
}

@test "reusable-test-node-custom: staging step gated on pages-upload-gate" {
	run _step_if_references_gate \
		"${PROJECT_ROOT}/.github/workflows/reusable-test-node-custom.yml" "Stage pages coverage HTML"
	assert_success
}

@test "reusable-rust-test: coverage HTML generation gated on pages-upload-gate" {
	run _step_if_references_gate \
		"${PROJECT_ROOT}/.github/workflows/reusable-rust-test.yml" "Generate Rust coverage HTML"
	assert_success
}

@test "reusable-rust-test-run: coverage HTML generation gated on pages-upload-gate" {
	run _step_if_references_gate \
		"${PROJECT_ROOT}/.github/workflows/reusable-rust-test-run.yml" "Generate Rust coverage HTML"
	assert_success
}

@test "reusable-rust-test: gate step runs before coverage HTML generation" {
	run _gate_precedes_step \
		"${PROJECT_ROOT}/.github/workflows/reusable-rust-test.yml" "Generate Rust coverage HTML"
	assert_success
}

@test "reusable-rust-test-run: gate step runs before coverage HTML generation" {
	run _gate_precedes_step \
		"${PROJECT_ROOT}/.github/workflows/reusable-rust-test-run.yml" "Generate Rust coverage HTML"
	assert_success
}

@test "stage-node-pages-coverage: still fails closed on missing index.html" {
	local tmp
	tmp="$(mktemp -d)"
	mkdir -p "${tmp}/coverage"
	WORKING_DIRECTORY="$tmp" PAGES_COVERAGE_SOURCE_SUBPATH="coverage" \
		PAGES_COVERAGE_STAGING_DIR="${tmp}/out" \
		run bash "${PROJECT_ROOT}/scripts/ci/actions/stage-node-pages-coverage.sh"
	rm -rf "$tmp"
	assert_failure 1
	assert_output --partial "missing index.html"
}
