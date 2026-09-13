#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-release-recover.yml and the retention
#          defaults (#966)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-release-recover.yml"
EXAMPLE="${PROJECT_ROOT}/examples/release-recover.yml"

@test "reusable-release-recover: dry-run defaults to true" {
	run awk '
		/^      dry-run:/ { in_input = 1; next }
		in_input && /default:/ { print; exit }
	' "$WORKFLOW"
	assert_output --partial "true"
}

@test "reusable-release-recover: requires tag, source run id, and head sha" {
	run grep -cF "required: true" "$WORKFLOW"
	assert_output 3
}

@test "reusable-release-recover: dry-run boundary stops before any resume job" {
	run grep -F "Dry run: detection only" "$WORKFLOW"
	assert_success
	# Every resume job is gated on !inputs.dry-run.
	run grep -cF "!inputs.dry-run &&" "$WORKFLOW"
	assert_output 3
}

@test "reusable-release-recover: resume jobs are gated on the detected missing set" {
	run grep -cF "contains(fromJSON(needs.resolve.outputs.missing)" "$WORKFLOW"
	assert_output 3
}

@test "reusable-release-recover: resumes through the same scripts as the tag path" {
	# npm resumes through #965's publish-set.sh...
	run grep -F "scripts/ci/actions/npm/publish-set.sh" "$WORKFLOW"
	assert_success
	run grep -F "scripts/ci/actions/npm/verify-published.sh" "$WORKFLOW"
	assert_success
	# ...and the GitHub Release through create-github-release.sh with
	# immutable assets so only missing assets upload.
	run grep -F "scripts/ci/release/create-github-release.sh" "$WORKFLOW"
	assert_success
	run grep -F 'IMMUTABLE_ASSETS: "true"' "$WORKFLOW"
	assert_success
}

@test "reusable-release-recover: records the outcome on the release-failure issue" {
	run grep -F "record-recovery.sh" "$WORKFLOW"
	assert_success
	# The record job runs always(): a failed recovery must land on the issue too.
	run grep -F "if: always()" "$WORKFLOW"
	assert_success
}

@test "reusable-release-recover: declares the least-privilege union" {
	# The caller needs actions read, issues write, contents read/write for the
	# release resume, and id-token for the npm resume.
	run grep -F "actions: read" "$WORKFLOW"
	assert_success
	run grep -F "issues: write" "$WORKFLOW"
	assert_success
	run grep -F "contents: write" "$WORKFLOW"
	assert_success
	run grep -F "id-token: write" "$WORKFLOW"
	assert_success
}

@test "example release-recover: dispatches the reusable with dry-run first" {
	run grep -F "reusable-release-recover.yml" "$EXAMPLE"
	assert_success
	run grep -F "default: true" "$EXAMPLE"
	assert_success
	run grep -F "source-run-sha" "$EXAMPLE"
	assert_success
}

@test "release artifact retention defaults to the 90-day recovery window" {
	run awk '
		/artifact-retention-days:/ { in_input = 1; next }
		in_input && /default:/ { print; exit }
	' "${PROJECT_ROOT}/.github/workflows/reusable-build-python-dist.yml"
	assert_output --partial "default: 90"
	run awk '
		/^      retention-days:/ { in_input = 1; next }
		in_input && /default:/ { print; exit }
	' "${PROJECT_ROOT}/.github/workflows/reusable-build-rust-binaries.yml"
	assert_output --partial "default: 90"
}

@test "release recovery runbook exists and names the tiers" {
	local runbook="${PROJECT_ROOT}/docs/release-recovery.md"
	run grep -F "Tier 2" "$runbook"
	assert_success
	run grep -F "tier three" "$runbook"
	assert_success
	run grep -F "90 days" "$runbook"
	assert_success
}
