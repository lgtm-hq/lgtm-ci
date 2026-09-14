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

# Print the `default:` value of one workflow_call input block.
input_default() {
	awk -v input="$1" '
		$0 == "      " input ":" { in_input = 1; next }
		in_input && /^      [a-z-]+:$/ { exit }
		in_input && /^        default:/ { sub(/^        default: */, ""); print; exit }
	' "$WORKFLOW"
}

@test "reusable-publish-npm-set: dry-run defaults to true" {
	run input_default dry-run
	assert_output "true"
}

# Print the lines of one job's `permissions:` block (job-level, 4-space key).
job_permissions() {
	awk -v job="$1" '
		$0 == "  " job ":" { in_job = 1; next }
		in_job && /^  [a-z-]+:$/ { exit }
		in_job && /^    permissions:$/ { in_perms = 1; next }
		in_perms && /^    [a-z-]+:/ { exit }
		in_perms && /^      [a-z-]+: / { print }
	' "$WORKFLOW"
}

@test "reusable-publish-npm-set: job uses OIDC trusted publishing permissions" {
	run job_permissions publish
	assert_line "      contents: read"
	assert_line "      id-token: write"
	assert_line "      attestations: write"
	run job_permissions publish
	refute_output --partial "contents: write"
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

# Print the lines of one step (from its `- name:` to the next step).
step_block() {
	awk -v step="$1" '
		$0 == "      - name: " step { in_step = 1; print; next }
		in_step && /^      - name: / { exit }
		in_step { print }
	' "$WORKFLOW"
}

@test "reusable-publish-npm-set: gates verification steps on their inputs" {
	run step_block "Verify artifacts"
	assert_line "        if: inputs.checksums-file != ''"
	run step_block "Verify published packages"
	assert_line "        if: inputs.post-publish-verify"
	# Default must be true so callers that omit the input still get verification.
	run input_default post-publish-verify
	assert_output "true"
}

@test "reusable-publish-npm-set: live publishes fail closed before download, verify, or publish" {
	# The entry guard receives LIVE and the preconditions step runs before
	# the artifact download, so a misconfigured live run touches nothing.
	run step_block "Assert entry workflow is allowlisted"
	assert_line "          LIVE: \${{ inputs.dry-run == false && '1' || '0' }}"
	run step_block "Assert live-publish preconditions"
	assert_line "          LIVE: \${{ inputs.dry-run == false && '1' || '0' }}"
	assert_line "          RUNNER_ENVIRONMENT: \${{ runner.environment }}"
	assert_line "          CHECKSUMS_FILE: \${{ inputs.checksums-file }}"
	assert_line "          SIGNER_REPO: \${{ inputs.signer-repo }}"
	assert_line "          SIGNER_WORKFLOW: \${{ inputs.signer-workflow }}"
	assert_output --partial "assert-live-publish-inputs.sh"
	run awk '
		/name: Assert live-publish preconditions/ { pre = NR }
		/name: Download staged package set/ { download = NR }
		END { exit !(pre && download && pre < download) }
	' "$WORKFLOW"
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

# Print the `value:` of one workflow_call output block.
output_value() {
	awk -v output="$1" '
		$0 == "      " output ":" { in_output = 1; next }
		in_output && /^      [a-z-]+:$/ { exit }
		in_output && /^        value:/ { sub(/^        value: */, ""); print; exit }
	' "$WORKFLOW"
}

@test "reusable-publish-npm-set: exposes published and dist-tag-drift outputs" {
	run output_value published
	assert_output "\${{ jobs.publish.outputs.published }}"
	run output_value dist-tag-drift
	assert_output "\${{ jobs.publish.outputs.dist-tag-drift }}"
	run step_block "Publish package set"
	assert_line "        id: publish"
}

@test "reusable-publish-npm-set: maps dry-run to the publish script LIVE flag" {
	run step_block "Publish package set"
	assert_line "          LIVE: \${{ inputs.dry-run == false && '1' || '0' }}"
	run step_block "Verify published packages"
	assert_line "          DRY_RUN: \${{ inputs.dry-run == true && '1' || '0' }}"
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
		# \047 is a literal apostrophe (the awk program itself is single-quoted).
		in_job && /NPM_TOKEN_SUPPLIED: \$\{\{ secrets\.npm-token != \047\047 \}\}/ { found_env = 1 }
		in_job && /::error::reusable-publish-npm.yml no longer accepts the npm-token secret/ { found_error = 1 }
		END { exit !(found_env && found_error) }
	' "$WRAPPER"
	assert_success
	run grep -F "needs: [deprecation-notice]" "$WRAPPER"
	assert_success
}

@test "reusable-publish-npm: forwards the live-publish and runner inputs to the set workflow" {
	run awk '
		/^  publish:$/ { in_job = 1; next }
		in_job && /^  [a-z-]+:$/ { in_job = 0; in_with = 0 }
		in_job && /^    with:$/ { in_with = 1; next }
		in_with && /^      [a-z-]+: / { print }
	' "$WRAPPER"
	assert_line "      entry-workflows: \${{ inputs.entry-workflows }}"
	assert_line "      checksums-file: \${{ inputs.checksums-file }}"
	assert_line "      files-to-verify: \${{ inputs.files-to-verify }}"
	assert_line "      signer-repo: \${{ inputs.signer-repo }}"
	assert_line "      signer-workflow: \${{ inputs.signer-workflow }}"
	assert_line "      runner-image: \${{ inputs.runner-image }}"
}
