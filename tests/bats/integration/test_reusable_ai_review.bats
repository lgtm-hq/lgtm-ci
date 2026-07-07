#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract + structure tests for reusable-ai-review.yml (#416)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-ai-review.yml"

# --- Repo contract validators must accept the new reusable --------------------

@test "reusable-ai-review: satisfies runner contract validator" {
	run "${PROJECT_ROOT}/scripts/ci/quality/validate-runner-contract.sh"
	assert_success
	assert_output --partial "OK:"
}

@test "reusable-ai-review: satisfies static job-name validator" {
	run "${PROJECT_ROOT}/scripts/ci/quality/validate-static-job-names.sh"
	assert_success
}

@test "reusable-ai-review: satisfies tooling sparse-checkout validator" {
	run "${PROJECT_ROOT}/scripts/ci/quality/validate-tooling-sparse-checkout.sh"
	assert_success
}

# --- Interface / inputs -------------------------------------------------------

@test "reusable-ai-review: exposes the documented inputs" {
	run grep -E '^      (depth|post|max-cost-usd|paths|lintro-version|strictness|model):' "$WORKFLOW"
	assert_success
	assert_line --partial "depth:"
	assert_line --partial "post:"
	assert_line --partial "max-cost-usd:"
	assert_line --partial "lintro-version:"
	assert_line --partial "strictness:"
	assert_line --partial "model:"
}

@test "reusable-ai-review: model input has no hardcoded default value" {
	run awk '/^      model:$/{f=1;next} f&&/^      [a-z]/{exit} f&&/default:/{print}' "$WORKFLOW"
	assert_success
	assert_output --partial 'default: ""'
}

@test "reusable-ai-review: lintro-version is pinned with a Renovate annotation" {
	run grep -F "# renovate: datasource=pypi depName=lintro" "$WORKFLOW"
	assert_success
	run grep -E 'default: "[0-9]+\.[0-9]+\.[0-9]+"' "$WORKFLOW"
	assert_success
}

@test "reusable-ai-review: declares anthropic-api-key as an optional secret" {
	run awk '/^    secrets:/{f=1} f&&/anthropic-api-key:/{print}' "$WORKFLOW"
	assert_success
	assert_output --partial "anthropic-api-key:"
}

@test "reusable-ai-review: timeout-minutes input is type number" {
	run awk '/^      timeout-minutes:$/{f=1;next} f&&/^      [a-z]/{exit} f{print}' "$WORKFLOW"
	assert_success
	assert_output --partial "type: number"
}

# --- Hardening ----------------------------------------------------------------

@test "reusable-ai-review: job is non-blocking (continue-on-error)" {
	run grep -F "continue-on-error: true" "$WORKFLOW"
	assert_success
}

@test "reusable-ai-review: defaults to the ai-review egress preset" {
	run awk '/^      egress-preset:$/{f=1;next} f&&/^      [a-z]/{exit} f&&/default:/{print}' "$WORKFLOW"
	assert_success
	assert_output --partial 'default: "ai-review"'
}

@test "reusable-ai-review: resolves egress before harden-runner" {
	run egress_tooling_checkout_order_ok "$WORKFLOW" ai-review
	assert_success
}

@test "reusable-ai-review: ANTHROPIC_API_KEY is scoped only to the run step" {
	# The key must appear exactly once (the Run AI review step), never at job
	# level nor in the preflight/checkout/comment steps.
	run grep -c "ANTHROPIC_API_KEY: \${{ secrets.anthropic-api-key }}" "$WORKFLOW"
	assert_success
	assert_output "1"
}

@test "reusable-ai-review: run step is gated on preflight should-run" {
	run awk '
		/- name: Run AI review/ { seen = 1 }
		seen && /if: steps.preflight.outputs.should-run == .true./ { found = 1; exit }
		seen && /- name:/ && !/Run AI review/ { exit }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-ai-review: never installs or runs PR code (no uv sync / pip install .)" {
	# Ignore documentation comment lines; only executable YAML must be clean.
	run bash -c "grep -vE '^[[:space:]]*#' '$WORKFLOW' | grep -E 'uv sync|pip install \\.|pip install -e'"
	assert_failure
}

@test "reusable-ai-review: sparse-checkout includes scripts/ci and post-pr-comment" {
	run grep -F "scripts/ci/" "$WORKFLOW"
	assert_success
	run grep -F ".github/actions/post-pr-comment" "$WORKFLOW"
	assert_success
}

# --- Action pinning -----------------------------------------------------------

@test "reusable-ai-review: third-party actions are SHA-pinned with version comments" {
	run awk '/uses: [a-z][^ ]*\// && !/\.\/\.lgtm-ci-tooling/ {print}' "$WORKFLOW"
	assert_success
	while IFS= read -r line; do
		[[ "$line" =~ uses:\ [^@]+@[0-9a-f]{40}\ #\ v[0-9] ]] || {
			echo "unpinned action: $line"
			return 1
		}
	done <<<"$output"
}

@test "reusable-ai-review: uses post-pr-comment with the sticky marker" {
	run awk '/uses: .*post-pr-comment/{f=1} f&&/marker:/{print;exit}' "$WORKFLOW"
	assert_success
	assert_output --partial "marker: lintro-ai-review"
}

@test "reusable-ai-review: comment steps skip fork PRs (no upsert with read-only token)" {
	# Each comment step (fetch-state, render, post) must exclude skip-reason
	# 'fork' as well as 'not-a-pr', so fork PRs take the graceful skip path
	# instead of attempting a sticky-comment upsert with a read-only token.
	run grep -c "steps.preflight.outputs.skip-reason != 'fork'" "$WORKFLOW"
	assert_success
	assert_output "3"
}
