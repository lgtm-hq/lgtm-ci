#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-publish-npm-set.yml (#965)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-publish-npm-set.yml"
WRAPPER="${PROJECT_ROOT}/.github/workflows/reusable-publish-npm.yml"

@test "reusable-publish-npm-set: requires packages-dir and order" {
	run grep -F "packages-dir:" "$WORKFLOW"
	assert_success
	run grep -F "order:" "$WORKFLOW"
	assert_success
	run grep -F "required: true" "$WORKFLOW"
	assert_success
}

@test "reusable-publish-npm-set: dry-run defaults to true" {
	run awk '
		/dry-run:/ { in_input = 1; next }
		in_input && /default:/ { print; exit }
	' "$WORKFLOW"
	assert_output --partial "true"
}

@test "reusable-publish-npm-set: job uses OIDC trusted publishing permissions" {
	run grep -F "id-token: write" "$WORKFLOW"
	assert_success
	run grep -F "attestations: write" "$WORKFLOW"
	assert_success
	run grep -F "contents: read" "$WORKFLOW"
	assert_success
}

@test "reusable-publish-npm-set: step order is verify-artifacts, publish, verify-published" {
	run awk '
		/name: Verify artifacts/ { verify = NR }
		/name: Publish package set/ { publish = NR }
		/name: Verify published packages/ { post = NR }
		END { exit !(verify && publish && post && verify < publish && publish < post) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-publish-npm-set: gates verification steps on their inputs" {
	run grep -F "if: inputs.checksums-file != ''" "$WORKFLOW"
	assert_success
	run grep -F "if: inputs.post-publish-verify" "$WORKFLOW"
	assert_success
}

@test "reusable-publish-npm-set: wires the entry-workflow guard before any publish" {
	run grep -F "assert-entry-workflow.sh" "$WORKFLOW"
	assert_success
	run grep -F "ALLOWED_ENTRY_WORKFLOWS: \${{ inputs.entry-workflows }}" "$WORKFLOW"
	assert_success
}

@test "reusable-publish-npm-set: exposes published and dist-tag-drift outputs" {
	run grep -F "value: \${{ jobs.publish.outputs.published }}" "$WORKFLOW"
	assert_success
	run grep -F "value: \${{ jobs.publish.outputs.dist-tag-drift }}" "$WORKFLOW"
	assert_success
	run grep -F "id: publish" "$WORKFLOW"
	assert_success
}

@test "reusable-publish-npm-set: maps dry-run to the publish script LIVE flag" {
	run grep -F "LIVE: \${{ inputs.dry-run == false && '1' || '0' }}" "$WORKFLOW"
	assert_success
	run grep -F "DRY_RUN: \${{ inputs.dry-run == true && '1' || '0' }}" "$WORKFLOW"
	assert_success
}

@test "reusable-publish-npm: is a deprecated thin wrapper over the package-set reusable" {
	run grep -F "DEPRECATED" "$WRAPPER"
	assert_success
	run grep -F "reusable-publish-npm-set.yml" "$WRAPPER"
	assert_success
	# Single-directory shape: the package IS the packages directory.
	run grep -F 'order: "."' "$WRAPPER"
	assert_success
	run grep -F "deprecation-notice:" "$WRAPPER"
	assert_success
}
