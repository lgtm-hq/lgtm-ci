#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract + structure tests for reusable-ai-review.yml (#853)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-ai-review.yml"

# --- Repo contract validators must accept the reusable ------------------------

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
	run grep -E '^      (provider|transport|lintro-version|python-version|model|max-cost-usd|blocking):' "$WORKFLOW"
	assert_success
	assert_line --partial "provider:"
	assert_line --partial "transport:"
	assert_line --partial "lintro-version:"
	assert_line --partial "python-version:"
	assert_line --partial "model:"
	assert_line --partial "max-cost-usd:"
	assert_line --partial "blocking:"
}

@test "reusable-ai-review: provider and transport inputs have empty defaults" {
	run awk '/^      provider:$/{f=1;next} f&&/^      [a-z]/{exit} f&&/default:/{print}' "$WORKFLOW"
	assert_success
	assert_output --partial 'default: ""'
	run awk '/^      transport:$/{f=1;next} f&&/^      [a-z]/{exit} f&&/default:/{print}' "$WORKFLOW"
	assert_success
	assert_output --partial 'default: ""'
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

@test "reusable-ai-review: lintro-version default meets the #2143 floor" {
	run awk '/^      lintro-version:$/{f=1;next} f&&/^      [a-z-]+:/{exit} f&&/default:/{gsub(/"/,""); print $2; exit}' "$WORKFLOW"
	assert_success
	[[ -n "$output" ]]
	printf '%s\n' "0.125.0" "$output" | sort -C -V
}

@test "reusable-ai-review: declares optional secrets by org name" {
	run awk '/^    secrets:/{f=1} f{print}' "$WORKFLOW"
	assert_success
	assert_output --partial "LINTRO_REVIEW_APP_ID:"
	assert_output --partial "LINTRO_REVIEW_APP_PRIVATE_KEY:"
	assert_output --partial "ANTHROPIC_API_KEY:"
	assert_output --partial "CLAUDE_CODE_OAUTH_TOKEN:"
	assert_output --partial "OPENAI_API_KEY:"
	assert_output --partial "CODEX_API_KEY:"
	assert_output --partial "CURSOR_API_KEY:"
}

@test "reusable-ai-review: timeout-minutes input is type number" {
	run awk '/^      timeout-minutes:$/{f=1;next} f&&/^      [a-z]/{exit} f{print}' "$WORKFLOW"
	assert_success
	assert_output --partial "type: number"
}

@test "reusable-ai-review: blocking defaults to false" {
	run awk '/^      blocking:$/{f=1;next} f&&/^      [a-z]/{exit} f&&/default:/{print}' "$WORKFLOW"
	assert_success
	assert_output --partial "default: false"
}

# --- Hardening ----------------------------------------------------------------

@test "reusable-ai-review: does not use job-level continue-on-error" {
	run grep -F "continue-on-error:" "$WORKFLOW"
	assert_failure
}

@test "reusable-ai-review: defaults to the ai-review egress preset" {
	run awk '/^      egress-preset:$/{f=1;next} f&&/^      [a-z]/{exit} f&&/default:/{print}' "$WORKFLOW"
	assert_success
	assert_output --partial 'default: "ai-review"'
}

@test "reusable-ai-review: default allowlist has no provider inference hosts" {
	run awk '/^      allowed-endpoints:$/{f=1;next} f&&/^      [a-z-]+:/{exit} f{print}' "$WORKFLOW"
	assert_success
	refute_output --partial "api.anthropic.com"
	refute_output --partial "api.openai.com"
	refute_output --partial "cursor.sh"
	assert_output --partial "pypi.org:443"
	assert_output --partial "astral.sh:443"
}

@test "reusable-ai-review: resolves egress before harden-runner" {
	run egress_tooling_checkout_order_ok "$WORKFLOW" ai-review
	assert_success
}

@test "reusable-ai-review: header documents pull_request trust model" {
	run grep -E "pull_request_target|PyPI release|never from the reviewed repo" "$WORKFLOW"
	assert_success
	assert_output --partial "pull_request_target"
	assert_output --partial "PyPI release"
	assert_output --partial "never from the reviewed repo"
}

@test "reusable-ai-review: maps inputs onto LINTRO_AI_* overlays" {
	run grep -E "LINTRO_AI_(PROVIDER|TRANSPORT|MODEL|MAX_COST_USD|ENABLED):" "$WORKFLOW"
	assert_success
	assert_output --partial "LINTRO_AI_PROVIDER:"
	assert_output --partial "LINTRO_AI_TRANSPORT:"
	assert_output --partial "LINTRO_AI_MODEL:"
	assert_output --partial "LINTRO_AI_MAX_COST_USD:"
	assert_output --partial "LINTRO_AI_ENABLED:"
}

@test "reusable-ai-review: App token is minted and scoped to the run step" {
	run grep -F "actions/create-github-app-token" "$WORKFLOW"
	assert_success
	run grep -c "GITHUB_TOKEN: \${{ steps.lintro-review-app.outputs.token }}" "$WORKFLOW"
	assert_success
	assert_output "1"
}

@test "reusable-ai-review: fails early when App credentials are missing" {
	run grep -F "Require lintro-review App credentials" "$WORKFLOW"
	assert_success
	run grep -F "APP_KEY_PRESENT" "$WORKFLOW"
	assert_success
	run grep -F "are required to post as lintro-review[bot]" "$WORKFLOW"
	assert_success
}

@test "reusable-ai-review: provider credentials are gated on resolve outputs" {
	run grep -c "steps.resolve.outputs.provider ==" "$WORKFLOW"
	assert_success
	[[ "$output" -ge 5 ]]
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
	run bash -c "grep -vE '^[[:space:]]*#' '$WORKFLOW' | grep -E 'uv sync|pip install \\.|pip install -e'"
	assert_failure
}

@test "reusable-ai-review: sparse-checkout includes scripts/ci" {
	run grep -F "scripts/ci/" "$WORKFLOW"
	assert_success
	run grep -F "post-pr-comment" "$WORKFLOW"
	assert_failure
}

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

@test "reusable-ai-review: job permissions do not grant pull-requests write" {
	run awk '
		/^  ai-review:/ { in_job = 1 }
		in_job && /^    permissions:/ { f = 1; next }
		f && /^    [a-z]/ { exit }
		f { print }
	' "$WORKFLOW"
	assert_success
	assert_output --partial "contents: read"
	assert_output --partial "pull-requests: read"
	refute_output --partial "pull-requests: write"
}

@test "reusable-ai-review: persist-credentials is false on checkouts" {
	run grep -c "persist-credentials: false" "$WORKFLOW"
	assert_success
	[[ "$output" -ge 2 ]]
}
