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
	run grep -F 'generate-build-matrix.sh' "$WORKFLOW"
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

# --- toolchain-agnostic contract (#760) -------------------------------------

_input_default() {
	local workflow="$1" input="$2"
	awk -v want="      ${input}:" '
		$0 == want { in_input = 1; next }
		in_input && /^      [a-zA-Z0-9_-]+:/ { exit }
		in_input && /^        default:/ {
			sub(/^        default: /, "")
			gsub(/"/, "")
			print
			exit
		}
	' "$workflow"
}

@test "reusable-build-artifact: toolchain input defaults to node" {
	run _input_default "$WORKFLOW" "toolchain"
	assert_success
	assert_output "node"
}

@test "reusable-build-artifact: toolchain input documents the vetted enum" {
	run grep -F 'node | rust | python' "$WORKFLOW"
	assert_success
	run grep -F 'toolchain must be one of: node, rust, python, none' \
		"${PROJECT_ROOT}/scripts/ci/actions/validate-build-artifact-inputs.sh"
	assert_success
}

@test "reusable-build-artifact: exposes matrix runner-map and toolchain-version inputs" {
	local input
	for input in matrix runner-map runner-map-key toolchain-version; do
		run grep -qE "^      ${input}:" "$WORKFLOW"
		assert_success
	done
}

@test "reusable-build-artifact: runner-map defaults to an empty object" {
	run _input_default "$WORKFLOW" "runner-map"
	assert_success
	assert_output "{}"
}

@test "reusable-build-artifact: node-version and node-version-matrix survive" {
	run grep -qE '^      node-version:' "$WORKFLOW"
	assert_success
	run grep -qE '^      node-version-matrix:' "$WORKFLOW"
	assert_success
}

@test "reusable-build-artifact: node-version-matrix is marked deprecated" {
	run awk '
		/^      node-version-matrix:/ { in_input = 1; next }
		in_input && /^      [a-zA-Z0-9_-]+:/ { exit }
		in_input && /DEPRECATED/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-build-artifact: build runs-on falls back to runner-image" {
	run grep -F 'runs-on: ${{ matrix.runner || inputs.runner-image }}' "$WORKFLOW"
	assert_success
}

@test "reusable-build-artifact: each toolchain setup step is gated on the enum" {
	local toolchain
	for toolchain in node python rust; do
		run grep -F "if: inputs.toolchain == '${toolchain}'" "$WORKFLOW"
		assert_success
	done
}

@test "reusable-build-artifact: toolchain setup actions are digest-pinned" {
	# node uses the upstream action directly; python and rust go through
	# lgtm-ci composites that pin astral-sh/setup-uv and dtolnay/rust-toolchain.
	run grep -qE 'uses: actions/setup-node@[0-9a-f]{40} # v' "$WORKFLOW"
	assert_success
	run grep -F 'uses: ./.lgtm-ci-tooling/.github/actions/setup-python' "$WORKFLOW"
	assert_success
	run grep -F 'uses: ./.lgtm-ci-tooling/.github/actions/setup-rust' "$WORKFLOW"
	assert_success
	run grep -qE 'uses: astral-sh/setup-uv@[0-9a-f]{40} # v' \
		"${PROJECT_ROOT}/.github/actions/setup-python/action.yml"
	assert_success
	run grep -qE 'uses: dtolnay/rust-toolchain@[0-9a-f]{40} # v' \
		"${PROJECT_ROOT}/.github/actions/setup-rust/action.yml"
	assert_success
}

@test "reusable-build-artifact: build sparse checkout adds the setup composites" {
	run awk '
		/^  build:/ { in_build = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  build:/ { in_build = 0 }
		in_build && /\.github\/actions\/setup-python/ { python = 1 }
		in_build && /\.github\/actions\/setup-rust/ { rust = 1 }
		END { exit !(python && rust) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-build-artifact: artifact name resolution reads the matrix leg" {
	run grep -F 'MATRIX_JSON: ${{ toJson(matrix) }}' "$WORKFLOW"
	assert_success
}

@test "reusable-build-artifact: the build step receives the matrix leg" {
	# Both the name resolver and the build runner need the leg: the runner
	# exports it as MATRIX_<FIELD> for the caller's build command.
	run grep -cF 'MATRIX_JSON: ${{ toJson(matrix) }}' "$WORKFLOW"
	assert_success
	assert_output "2"
}

@test "reusable-build-artifact: prepare forwards the toolchain inputs" {
	local pair
	for pair in \
		'TOOLCHAIN: ${{ inputs.toolchain }}' \
		'TOOLCHAIN_VERSION: ${{ inputs.toolchain-version }}' \
		'MATRIX: ${{ inputs.matrix }}' \
		'RUNNER_MAP: ${{ inputs.runner-map }}' \
		'RUNNER_MAP_KEY: ${{ inputs.runner-map-key }}' \
		'DEFAULT_RUNNER: ${{ inputs.runner-image }}'; do
		run grep -F "$pair" "$WORKFLOW"
		assert_success
	done
}
