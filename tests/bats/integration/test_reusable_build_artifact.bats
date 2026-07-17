#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-build-artifact workflow (#522)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-build-artifact.yml"

_tooling_sparse_cone_ok() {
	local workflow="$1"
	awk '
		/sparse-checkout-cone-mode: true/ { found = 1; exit }
		END { exit !found }
	' "$workflow"
}

@test "reusable-build-artifact: prepare and build checkout order" {
	run egress_tooling_checkout_order_ok "$WORKFLOW" "prepare"
	assert_success
	run egress_tooling_checkout_order_ok "$WORKFLOW" "build"
	assert_success
}

@test "reusable-build-artifact: tooling sparse checkout uses cone mode" {
	run _tooling_sparse_cone_ok "$WORKFLOW"
	assert_success
}

@test "reusable-build-artifact: requires build-command artifact-name artifact-path" {
	run awk '
		/^      build-command:/ { in_bc = 1 }
		in_bc && /^      [a-zA-Z0-9_-]+:/ && !/^      build-command:/ { in_bc = 0 }
		in_bc && /required: true/ { bc = 1 }
		/^      artifact-name:/ { in_an = 1 }
		in_an && /^      [a-zA-Z0-9_-]+:/ && !/^      artifact-name:/ { in_an = 0 }
		in_an && /required: true/ { an = 1 }
		/^      artifact-path:/ { in_ap = 1 }
		in_ap && /^      [a-zA-Z0-9_-]+:/ && !/^      artifact-path:/ { in_ap = 0 }
		in_ap && /required: true/ { ap = 1 }
		END { exit !(bc && an && ap) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-build-artifact: exposes artifact name id and url outputs" {
	run grep -q 'jobs.build.outputs.artifact-name' "$WORKFLOW"
	assert_success
	run grep -q 'jobs.build.outputs.artifact-id' "$WORKFLOW"
	assert_success
	run grep -q 'jobs.build.outputs.artifact-url' "$WORKFLOW"
	assert_success
}

@test "reusable-build-artifact: static inner job name uses job-name input" {
	run awk '
		/^  build:/ { in_build = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  build:/ { in_build = 0 }
		in_build && /^    name: \$\{\{ inputs\.job-name \}\}/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-build-artifact: build job has no draft-pr or PR-only if" {
	run awk '
		/^  build:/ { in_build = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  build:/ { in_build = 0 }
		in_build && /^    if:/ { found = 1 }
		END { exit found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-build-artifact: uses validate and run scripts" {
	run grep -F 'validate-build-artifact-inputs.sh' "$WORKFLOW"
	assert_success
	run grep -F 'run-build-artifact.sh' "$WORKFLOW"
	assert_success
	run grep -F 'resolve-build-artifact-name.sh' "$WORKFLOW"
	assert_success
	run grep -F 'generate-version-matrix.sh' "$WORKFLOW"
	assert_success
}

@test "reusable-build-artifact: upload-artifact uses upload repo v7 SHA" {
	run grep -F 'uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1' \
		"$WORKFLOW"
	assert_success
}

@test "reusable-build-artifact: setup-node uses matrix node-version" {
	run awk '
		/^  build:/ { in_build = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  build:/ { in_build = 0 }
		in_build && /node-version: \$\{\{ matrix\.node-version \}\}/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-build-artifact: no pull-requests permission" {
	run grep -q 'pull-requests:' "$WORKFLOW"
	assert_failure
}
