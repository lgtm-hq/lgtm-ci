#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-test-rust-coverage workflow

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-test-rust-coverage.yml"

_coverage_checkout_order_ok() {
	awk '
		/^  coverage:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  coverage:/ { in_job = 0 }
		in_job && /^    steps:/ { in_steps = 1 }
		in_job && in_steps && /^      - name: Harden runner/ { harden = NR }
		in_job && in_steps && /^      - name: Checkout repository/ { repo = NR }
		in_job && in_steps && /^      - name: Checkout lgtm-ci tooling/ { tooling = NR }
		END {
			ok = (harden > 0 && repo > 0 && tooling > 0 && harden < repo && repo < tooling)
			exit !ok
		}
	' "$WORKFLOW"
}

@test "reusable-test-rust-coverage: coverage job checkout order preserves tooling" {
	run _coverage_checkout_order_ok
	assert_success
}

@test "reusable-test-rust-coverage: exposes pages coverage inputs and outputs" {
	run grep -q 'upload-pages-coverage-html' "$WORKFLOW"
	assert_success
	run grep -q 'pages-coverage-artifact-name' "$WORKFLOW"
	assert_success
	run grep -q 'run-rust-coverage-html.sh' "$WORKFLOW"
	assert_success
}
