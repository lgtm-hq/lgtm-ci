#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for version-drift prevention workflows (#98)

load "../../helpers/common"

@test "validate-action-pinning workflow: calls reusable with verify-tags enabled" {
	local workflow="${PROJECT_ROOT}/.github/workflows/validate-action-pinning.yml"

	run grep -E 'uses: \./\.github/workflows/reusable-validate-action-pinning\.yml' "$workflow"
	assert_success
	run grep -E 'verify-tags: true' "$workflow"
	assert_success
	run grep -E 'audit-transitive: true' "$workflow"
	assert_success
}

@test "reusable-validate-action-pinning: forwards verify-tags input to action" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-validate-action-pinning.yml"

	run grep -F 'verify-tags: ${{ inputs.verify-tags }}' "$workflow"
	assert_success
}

@test "validate-action-pinning action: wires GH_TOKEN for verify-tags API resolution" {
	local action="${PROJECT_ROOT}/.github/actions/validate-action-pinning/action.yml"

	run grep -F 'GH_TOKEN: ${{ env.GH_TOKEN || github.token }}' "$action"
	assert_success
}

@test "dependency-review workflow: calls reusable dependency review" {
	local workflow="${PROJECT_ROOT}/.github/workflows/dependency-review.yml"

	run grep -E 'uses: \./\.github/workflows/reusable-dependency-review\.yml' "$workflow"
	assert_success
}

@test "validate-lintro-version workflow: triggers on pyproject and lintro image paths" {
	local workflow="${PROJECT_ROOT}/.github/workflows/validate-lintro-version.yml"

	run grep -F "pyproject.toml" "$workflow"
	assert_success
	run grep -F "reusable-quality-lint.yml" "$workflow"
	assert_success
	run grep -F "reusable-validate-lintro-version.yml" "$workflow"
	assert_success
	run grep -F ".github/workflows/validate-lintro-version.yml" "$workflow"
	assert_success
	run grep -F "scripts/ci/quality/check-lintro-tooling-bootstrap.sh" "$workflow"
	assert_success
	run grep -F "scripts/ci/quality/resolve-lintro-image.sh" "$workflow"
	assert_success
	run grep -F "scripts/ci/quality/validate-lintro-version.sh" "$workflow"
	assert_success
}

@test "validate-lintro-version workflow: runs on merge_group" {
	local workflow="${PROJECT_ROOT}/.github/workflows/validate-lintro-version.yml"

	run grep -F "merge_group:" "$workflow"
	assert_success
}

@test "validate-lintro-version workflow: bootstraps tooling from PR head when base lacks scripts" {
	local workflow="${PROJECT_ROOT}/.github/workflows/validate-lintro-version.yml"
	local reusable="${PROJECT_ROOT}/.github/workflows/reusable-validate-lintro-version.yml"

	run grep -F "tooling-ref-fallback:" "$workflow"
	assert_success
	run grep -F "pull_request.head.sha" "$workflow"
	assert_success
	run grep -F "tooling-ref-fallback:" "$reusable"
	assert_success
	run grep -F "BOOTSTRAP_SCRIPT:" "$reusable"
	assert_success
	run grep -F 'inputs.tooling-bootstrap-script' "$reusable"
	assert_success
	run grep -F "tooling-bootstrap-script:" "$workflow"
	assert_success
	if grep -qE 'run:[[:space:]]*[|>][-+]?' "$reusable"; then
		fail "reusable workflow contains inline multiline run blocks"
	fi
}

@test "registry-health-check workflow: runs on schedule and workflow_dispatch" {
	local workflow="${PROJECT_ROOT}/.github/workflows/registry-health-check.yml"

	run grep -F "cron: '0 2 * * 1'" "$workflow"
	assert_success
	run grep -F "workflow_dispatch" "$workflow"
	assert_success
}

@test "registry-health-check workflow: grants issues write for issue opening" {
	local workflow="${PROJECT_ROOT}/.github/workflows/registry-health-check.yml"

	run grep -F "issues: write" "$workflow"
	assert_success
	run grep -F "open-issue-on-failure: true" "$workflow"
	assert_success
}

@test "reusable-registry-health-check: scopes issue creation to follow-up job" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-registry-health-check.yml"

	run grep -F "open-registry-health-issue:" "$workflow"
	assert_success
	run grep -F "needs.registry-health.outputs.digest-failure == 'true'" "$workflow"
	assert_success
	run grep -F "digest-failure: \${{ steps.health.outputs.digest-failure }}" "$workflow"
	assert_success
}

@test "reusable-registry-health-check: hardens egress on issue follow-up job" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-registry-health-check.yml"

	run awk '
		/open-registry-health-issue:/ { in_job = 1 }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ && $0 !~ /open-registry-health-issue:/ {
			in_job = 0
		}
		in_job && /harden-runner/ { found = 1; exit }
		END { exit !found }
	' "$workflow"
	assert_success
	run awk '
		/open-registry-health-issue:/ { in_job = 1 }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ && $0 !~ /open-registry-health-issue:/ {
			in_job = 0
		}
		in_job && /egress-preset: github-minimal/ { found = 1; exit }
		END { exit !found }
	' "$workflow"
	assert_success
}

@test "reusable-registry-health-check: grants contents read to issue job checkout" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-registry-health-check.yml"

	run awk '
		/open-registry-health-issue:/ { in_job = 1; in_perms = 0 }
		in_job && /^  [A-Za-z_][A-Za-z0-9_-]*:/ && $0 !~ /open-registry-health-issue:/ {
			in_job = 0
			in_perms = 0
		}
		in_job && /permissions:/ { in_perms = 1 }
		in_perms && /contents: read/ { found = 1; exit }
		END { exit !found }
	' "$workflow"
	assert_success
}
