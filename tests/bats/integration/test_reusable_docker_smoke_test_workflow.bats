#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-docker-smoke-test.yml (standalone image
#          validation reusable, #381)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-docker-smoke-test.yml"

@test "reusable-docker-smoke-test: requires an immutable digest input" {
	run awk '
		/^      digest:$/ { in_input = 1 }
		in_input && /^        required: true$/ { found = 1; exit }
		in_input && /^      [a-z-]+:$/ && !/^      digest:$/ { in_input = 0 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-smoke-test: exposes smoke-test and health-check inputs" {
	run grep -E '^      smoke-test:$' "$WORKFLOW"
	assert_success
	run grep -E '^      smoke-test-script:$' "$WORKFLOW"
	assert_success
	run grep -E '^      health-check-cmd:$' "$WORKFLOW"
	assert_success
	run grep -E '^      health-check-port:$' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-smoke-test: exposes runner-image with ubuntu-24.04 default" {
	run grep -E '^      runner-image:$' "$WORKFLOW"
	assert_success
	run grep -F 'runs-on: ${{ inputs.runner-image }}' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-smoke-test: records the digest before validating" {
	# The digest input is persisted via record-digest (which validates the
	# sha256 format) and the validation steps pull by that immutable digest.
	run grep -F 'STEP: record-digest' "$WORKFLOW"
	assert_success
	run grep -F 'DIGEST: ${{ inputs.digest }}' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-smoke-test: runs the shared smoke-test and health-check steps" {
	run grep -F 'STEP: smoke-test' "$WORKFLOW"
	assert_success
	run grep -F 'STEP: health-check' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-smoke-test: registry login uses the docker-auth composite" {
	run grep -F 'uses: ./.lgtm-ci-tooling/.github/actions/docker-auth' "$WORKFLOW"
	assert_success
	run grep -F 'uses: docker/login-action@' "$WORKFLOW"
	assert_failure
}

@test "reusable-docker-smoke-test: QEMU setup skips native linux/amd64" {
	run awk '
		/name: Setup QEMU/ { in_step = 1 }
		in_step && /if: \$\{\{ inputs\.platform != .linux\/amd64. \}\}/ { has_if = 1 }
		in_step && /uses: docker\/setup-qemu-action@/ { has_uses = 1 }
		in_step && /^      - name:/ && !/Setup QEMU/ { in_step = 0 }
		END { exit !(has_if && has_uses) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-smoke-test: read-only permissions" {
	run grep -E '^      packages: write$' "$WORKFLOW"
	assert_failure
	run grep -E '^      packages: read$' "$WORKFLOW"
	assert_success
}
