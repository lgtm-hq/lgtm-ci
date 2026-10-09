#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-release-recover.yml and the retention
#          defaults (#966). Since #1081 the workflow is a facade over the
#          read-only reusable-release-recover-plan.yml and the internal
#          reusable-release-recover-resume.yml; job-level contracts are
#          asserted on the file that now holds the job.

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-release-recover.yml"
PLAN="${PROJECT_ROOT}/.github/workflows/reusable-release-recover-plan.yml"
RESUME="${PROJECT_ROOT}/.github/workflows/reusable-release-recover-resume.yml"
EXAMPLE="${PROJECT_ROOT}/examples/release-recover.yml"

# Print the lines of one job (from its key to the next job key) of FILE
# (default: the facade).
job_block() {
	awk -v job="$1" '
		$0 == "  " job ":" { in_job = 1; next }
		in_job && /^  [a-z-]+:$/ { exit }
		in_job { print }
	' "${2:-$WORKFLOW}"
}


# Lines of one named step inside one job of FILE (default: the facade).
step_block_in_job() {
	awk -v job="$1" -v step="$2" '
		$0 == "  " job ":" { in_job = 1; next }
		in_job && /^  [a-z-]+:$/ { exit }
		in_job && $0 == "      - name: " step { in_step = 1; print; next }
		in_step && /^      - name: / { in_step = 0 }
		in_step { print }
	' "${3:-$WORKFLOW}"
}

@test "reusable-release-recover: dry-run defaults to true" {
	run awk '
		/^      dry-run:/ { in_input = 1; next }
		in_input && /default:/ { print; exit }
	' "$WORKFLOW"
	assert_output --partial "true"
}

@test "reusable-release-recover: requires tag, source run id, the publish workflow path, and tooling-ref" {
	run grep -cF "required: true" "$WORKFLOW"
	assert_output 4
	run awk '
		$0 == "      tooling-ref:" { in_input = 1; next }
		in_input && /^      [a-z-]+:$/ { exit }
		in_input && /^        required:/ { print $2; exit }
	' "$WORKFLOW"
	assert_output "true"
	run grep -F "      source-workflow:" "$WORKFLOW"
	assert_success
	# The source run's identity is read from the API, never from an input.
	run grep -F "source-run-sha" "$WORKFLOW"
	assert_failure
	run job_block resolve "$PLAN"
	assert_line "          SOURCE_RUN_ID: \${{ inputs.source-run-id }}"
	assert_line "          SOURCE_WORKFLOW: \${{ inputs.source-workflow }}"
}

@test "reusable-release-recover: facade runs the read-only plan, then the resume stage" {
	run job_block plan
	assert_line "    uses: ./.github/workflows/reusable-release-recover-plan.yml"
	assert_line "      contents: read"
	refute_output --partial ": write"
	run job_block resume
	assert_line "    uses: ./.github/workflows/reusable-release-recover-resume.yml"
	# The record job inside must also run after a failed or dry-run plan.
	assert_line "    if: always()"
	assert_line "      missing: \${{ needs.plan.outputs.missing || '[]' }}"
	assert_line "      unresumable: \${{ needs.plan.outputs.unresumable || '[]' }}"
	assert_line "      resolve-result: \${{ needs.plan.result }}"
	assert_line "      homebrew-dispatch-token: \${{ secrets.homebrew-dispatch-token }}"
	# The plan grants no write scope and mints no OIDC token.
	run python3 "${PROJECT_ROOT}/scripts/ci/docs/validate-caller-permissions.py" \
		--union reusable-release-recover-plan.yml
	assert_output "actions: read
contents: read"
}

@test "reusable-release-recover: detection gets the verified release manifest and the record stage the closure inputs" {
	run job_block resolve "$PLAN"
	assert_output --partial "RELEASE_MANIFEST: \${{ inputs.release-artifact-name != '' && format('recovery-artifacts/release/{0}', inputs.release-checksums-file) || '' }}"
	assert_line "      unresumable: \${{ steps.detect.outputs.unresumable }}"
	run grep -F "value: \${{ jobs.resolve.outputs.unresumable }}" "$PLAN"
	assert_success
	run job_block record "$RESUME"
	assert_line "          UNRESUMABLE_SET: \${{ inputs.unresumable }}"
	assert_line "          RESOLVE_RESULT: \${{ inputs.resolve-result }}"
	assert_line "          DRY_RUN: \${{ inputs.dry-run == true && '1' || '0' }}"
}

@test "reusable-release-recover: dry-run boundary stops before any resume job" {
	run grep -F "Plan only: detection, nothing was resumed." "$PLAN"
	assert_success
	# Every resume job is gated on !inputs.dry-run and a successful plan.
	run grep -cF "!inputs.dry-run &&" "$RESUME"
	assert_output 3
	run grep -cF "inputs.resolve-result == 'success' &&" "$RESUME"
	assert_output 3
}

@test "reusable-release-recover: resume jobs are gated on the detected missing set" {
	run grep -cF "contains(fromJSON(inputs.missing)" "$RESUME"
	assert_output 3
}

@test "reusable-release-recover: resumes through the same scripts and guards as the tag path" {
	run job_block resume-npm "$RESUME"
	# #965's contract, in order: entry guard, live preconditions,
	# verify-artifacts, publish-set (the only writer), verify-published.
	assert_output --partial "scripts/ci/actions/npm/assert-entry-workflow.sh"
	assert_output --partial "scripts/ci/actions/npm/assert-live-publish-inputs.sh"
	assert_output --partial "scripts/ci/actions/npm/verify-artifacts.sh"
	assert_output --partial "scripts/ci/actions/npm/publish-set.sh"
	assert_output --partial "scripts/ci/actions/npm/verify-published.sh"
	run awk '
		/assert-entry-workflow.sh/ { guard = NR }
		/assert-live-publish-inputs.sh/ { pre = NR }
		/name: Download the original npm artifacts/ { download = NR }
		/npm\/verify-artifacts.sh/ { verify = NR }
		/npm\/publish-set.sh/ { publish = NR }
		/npm\/verify-published.sh/ { post = NR }
		END { exit !(guard && pre && download && verify && publish && post && guard < pre && pre < download && download < verify && verify < publish && publish < post) }
	' "$RESUME"
	assert_success
	# The resume is always live and inherits the #965 inputs.
	run job_block resume-npm "$RESUME"
	assert_line '          LIVE: "1"'
	assert_line "          ALLOWED_ENTRY_WORKFLOWS: \${{ inputs.npm-entry-workflows }}"
	assert_line "          ACCESS: \${{ inputs.npm-access }}"
	assert_line "          RUNNER_ENVIRONMENT: \${{ runner.environment }}"
	assert_line "          ORDER: \${{ inputs.npm-order }}"
	assert_line "          FILES: \${{ inputs.npm-files-to-verify }}"
	assert_line '          DRY_RUN: "0"'
	# The verifier waits for dist-tags.<npm-dist-tag> to point at the publish,
	# so the resume's verify step is wired with the tag like the tag path.
	run step_block_in_job resume-npm "Verify published packages" "$RESUME"
	assert_line "          DIST_TAG: \${{ inputs.npm-dist-tag }}"
	assert_line "          PROVENANCE: \${{ inputs.npm-provenance == true && '1' || '0' }}"
	assert_line '          DRY_RUN: "0"'
	# The GitHub Release resumes through create-github-release.sh with
	# immutable assets so only missing assets upload.
	run job_block resume-github-release "$RESUME"
	assert_output --partial "scripts/ci/release/create-github-release.sh"
	assert_line '          IMMUTABLE_ASSETS: "true"'
	assert_output --partial "verify-recovery-artifacts.sh"
	assert_line "          RELEASE_TAG: \${{ inputs.tag }}"
}

@test "reusable-release-recover: npm access defaults to public and the entry allowlist is an input" {
	run awk '
		$0 == "      npm-access:" { in_input = 1; next }
		in_input && /^      [a-z-]+:$/ { exit }
		in_input && /^        default:/ { sub(/^        default: */, ""); print; exit }
	' "$WORKFLOW"
	assert_output "public"
	run grep -F "      npm-entry-workflows:" "$WORKFLOW"
	assert_success
}

@test "reusable-release-recover: runs the default-branch workflow code, never the tag" {
	# Every checkout pins the required tooling-ref; nothing checks out
	# inputs.tag, and neither github.workflow_sha (the caller's commit inside
	# a called workflow) nor the job.workflow_sha default used elsewhere is a
	# ref here: recovery tooling is always an explicit operator choice.
	run bash -c 'cat "$0" "$1" | grep -c "ref: \${{ inputs.tooling-ref }}"' "$PLAN" "$RESUME"
	assert_output 5
	run grep -E "(github|job)\.workflow_sha \}\}" "$WORKFLOW" "$PLAN" "$RESUME"
	assert_failure
	run bash -c 'cat "$0" "$1" | grep -cE "^\s+ref: "' "$PLAN" "$RESUME"
	assert_output 5
	# The facade checks nothing out.
	run grep -cE "^\s+ref: " "$WORKFLOW"
	assert_output 0
	run grep -F "ref: \${{ inputs.tag }}" "$WORKFLOW" "$PLAN" "$RESUME"
	assert_failure
	run grep -F "inputs.tag }}" "$PLAN"
	assert_success
	run grep -E "uses: .*@\\$\{\{ inputs\.tag" "$WORKFLOW" "$PLAN" "$RESUME"
	assert_failure
}

@test "reusable-release-recover: every job is under the runner contract with harden first" {
	# runs-on is the runner-image input on every job; no hardcoded label.
	run bash -c 'cat "$0" "$1" | grep -cE "^    runs-on: "' "$PLAN" "$RESUME"
	assert_output 5
	run bash -c 'cat "$0" "$1" | grep -c "runs-on: \${{ inputs.runner-image }}"' "$PLAN" "$RESUME"
	assert_output 5
	run bash -c 'cat "$0" "$1" | grep -cE "^    timeout-minutes: "' "$PLAN" "$RESUME"
	assert_output 5
	# The facade's jobs only call the stages.
	run grep -cE "^    runs-on: " "$WORKFLOW"
	assert_output 0
	# The first step of every job is the harden-runner step.
	run awk '
		/^    steps:$/ { expect = 1; next }
		expect && /^      - / { if ($0 != "      - name: Harden runner") bad++; expect = 0 }
		END { exit bad > 0 }
	' "$PLAN" "$RESUME"
	assert_success
	run bash -c 'cat "$0" "$1" | grep -c "      - name: Harden runner"' "$PLAN" "$RESUME"
	assert_output 5
}

@test "reusable-release-recover: records the outcome on the release-failure issue" {
	run grep -F "record-recovery.sh" "$RESUME"
	assert_success
	# The record job runs always(): a failed recovery must land on the issue too.
	run job_block record "$RESUME"
	assert_line "    if: always()"
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
	run grep -F "source-workflow: .github/workflows/publish-pypi-on-tag.yml" "$EXAMPLE"
	assert_success
	run grep -F "source-run-sha" "$EXAMPLE"
	assert_failure
	# The example names its own file as the npm entry workflow and grants the
	# union of the reusable's per-job permissions.
	run grep -F "npm-entry-workflows: .github/workflows/release-recover.yml" "$EXAMPLE"
	assert_success
	run grep -F "contents: write" "$EXAMPLE"
	assert_success
	run grep -F "attestations: write" "$EXAMPLE"
	assert_success
	run grep -F "homebrew-dispatch-token: \${{ secrets.HOMEBREW_DISPATCH_TOKEN }}" "$EXAMPLE"
	assert_success
}

@test "reusable-release-recover: the Homebrew re-dispatch uses the declared cross-repo secret" {
	run grep -F "      homebrew-dispatch-token:" "$WORKFLOW"
	assert_success
	run grep -F "      homebrew-dispatch-token:" "$RESUME"
	assert_success
	run job_block resume-homebrew "$RESUME"
	assert_line "          GH_TOKEN: \${{ secrets.homebrew-dispatch-token }}"
	refute_output --partial "GH_TOKEN: \${{ github.token }}"
}

@test "reusable-release-recover: every job composes its allowlist from the release-recover preset" {
	# harden-runner installs the allowlist at job start, so every job selects
	# the release-recover preset from the embedded map by expression (#913).
	# Five harden-runner selectors plus their five unknown-preset guards.
	run bash -c 'cat "$0" "$1" | grep -c "fromJSON(env.LGTM_CI_EGRESS_PRESETS)\[inputs.egress-preset || '"'"'release-recover'"'"'\]"' "$PLAN" "$RESUME"
	assert_output 10
	run bash -c 'cat "$0" "$1" | grep -c "^      - name: Fail on unknown egress-preset"' "$PLAN" "$RESUME"
	assert_output 5
	run awk '/^      egress-preset:$/{f=1;next} f&&/^      [a-z-]+:/{exit} f{print}' "$WORKFLOW"
	assert_output --partial 'default: "release-recover"'
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
