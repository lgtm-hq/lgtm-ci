#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-publish-npm-set.yml (#965)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-publish-npm-set.yml"
WRAPPER="${PROJECT_ROOT}/.github/workflows/reusable-publish-npm.yml"

# Print the `required:` value of one workflow_call input block.
input_required() {
	awk -v input="$1" '
		$0 == "      " input ":" { in_input = 1; next }
		in_input && /^      [a-z-]+:$/ { exit }
		in_input && /^        required:/ { print $2; exit }
	' "$WORKFLOW"
}

@test "reusable-publish-npm-set: requires packages-dir and order" {
	run input_required packages-dir
	assert_output "true"
	run input_required order
	assert_output "true"
	# Sanity: an optional input reads false through the same helper.
	run input_required dist-tag
	assert_output "false"
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
	run grep -F "ALLOWED_ENTRY_WORKFLOWS: \${{ inputs.entry-workflows }}" "$WORKFLOW"
	assert_success
	# The guard must run before the artifact download and the publish step.
	run awk '
		/assert-entry-workflow.sh/ { guard = NR }
		/name: Download staged package set/ { download = NR }
		/name: Publish package set/ { publish = NR }
		END { exit !(guard && download && publish && guard < download && download < publish) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-publish-npm-set: exposes runner-image and downloads the staged artifact into packages-dir" {
	run grep -F 'runs-on: ${{ inputs.runner-image }}' "$WORKFLOW"
	assert_success
	run grep -F "if: inputs.artifact-name != ''" "$WORKFLOW"
	assert_success
	run grep -F 'path: ${{ inputs.packages-dir }}' "$WORKFLOW"
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

# Print the `value:` of one workflow_call output block of the wrapper.
wrapper_output_value() {
	awk -v output="$1" '
		$0 == "      " output ":" { in_output = 1; next }
		in_output && /^      [a-z-]+:$/ { exit }
		in_output && /^        value:/ { sub(/^        value: */, ""); print; exit }
	' "$WRAPPER"
}

@test "reusable-publish-npm: keeps the legacy output contract as a compatibility shim" {
	# `published` stays a 'true'/'false' string; `version` and `package-name`
	# come from the set JSON; `tarball` is kept as an always-empty output.
	run awk '
		/^      published:$/ { in_output = 1; next }
		in_output && /^      [a-z-]+:$/ { exit }
		in_output { print }
	' "$WRAPPER"
	assert_output --partial "fromJSON(jobs.publish.outputs.published || '[]')[0].status == 'published'"
	assert_output --partial "&& 'true' || 'false'"
	run wrapper_output_value version
	assert_output "\${{ fromJSON(jobs.publish.outputs.published || '[]')[0].version }}"
	run wrapper_output_value package-name
	assert_output "\${{ fromJSON(jobs.publish.outputs.published || '[]')[0].name }}"
	run wrapper_output_value tarball
	assert_output "\${{ '' }}"
	run wrapper_output_value published-set
	assert_output "\${{ jobs.publish.outputs.published }}"
}

@test "reusable-publish-npm: refuses the npm-token secret before the publish job" {
	# The guard lives in deprecation-notice, which publish needs, so a token
	# caller fails before any npm command runs.
	run awk '
		/^  deprecation-notice:/ { in_job = 1; next }
		in_job && /^  [a-z-]+:$/ { in_job = 0 }
		in_job && /NPM_TOKEN_SUPPLIED: \$\{\{ secrets.npm-token != .. \}\}/ { found_env = 1 }
		in_job && /::error::reusable-publish-npm.yml no longer accepts the npm-token secret/ { found_error = 1 }
		END { exit !(found_env && found_error) }
	' "$WRAPPER"
	assert_success
	run grep -F "needs: [deprecation-notice]" "$WRAPPER"
	assert_success
}
