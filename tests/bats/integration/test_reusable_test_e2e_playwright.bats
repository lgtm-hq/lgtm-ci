#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-test-e2e-playwright workflow (#521)

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-test-e2e-playwright.yml"

_tooling_sparse_cone_ok() {
	local workflow="$1"
	awk '
		/sparse-checkout-cone-mode: true/ { found = 1; exit }
		END { exit !found }
	' "$workflow"
}

@test "reusable-test-e2e-playwright: test job checkout order preserves tooling" {
	run egress_tooling_checkout_order_ok "$WORKFLOW" "test"
	assert_success
}

@test "reusable-test-e2e-playwright: tooling sparse checkout uses cone mode" {
	run _tooling_sparse_cone_ok "$WORKFLOW"
	assert_success
}

@test "reusable-test-e2e-playwright: requires job-name input" {
	run awk '
		/^      job-name:/ { in_input = 1 }
		in_input && /^      [a-zA-Z0-9_-]+:/ && !/^      job-name:/ { in_input = 0 }
		in_input && /required: true/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-e2e-playwright: static inner job name uses job-name input" {
	run awk '
		/^  test:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  test:/ { in_job = 0 }
		in_job && /^    name: \$\{\{ inputs\.job-name \}\}$/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-e2e-playwright: defaults egress-preset to playwright" {
	run awk '
		/^      egress-preset:/ { in_input = 1 }
		in_input && /^      [a-zA-Z0-9_-]+:/ && !/^      egress-preset:/ { in_input = 0 }
		in_input && /default: "playwright"/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-e2e-playwright: allowlist includes Playwright CDN hosts" {
	run grep -F 'cdn.playwright.dev:443' "$WORKFLOW"
	assert_success
	run grep -F 'playwright.azureedge.net:443' "$WORKFLOW"
	assert_success
}

@test "reusable-test-e2e-playwright: caches ms-playwright with resolved key" {
	run grep -F 'path: ~/.cache/ms-playwright' "$WORKFLOW"
	assert_success
	run grep -F 'steps.playwright-cache.outputs.cache-key' "$WORKFLOW"
	assert_success
	run grep -F 'run-playwright-tests.sh' "$WORKFLOW"
	assert_success
}

@test "reusable-test-e2e-playwright: install uses playwright install --with-deps via script" {
	run awk '
		/Install Playwright browsers/ { in_step = 1 }
		in_step && /STEP: install-browsers/ { step = 1 }
		in_step && /run-playwright-tests\.sh/ { script = 1 }
		END { exit !(step && script) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-e2e-playwright: report upload gated on failure" {
	run grep -F "steps.upload-gate.outputs.should-upload == 'true'" "$WORKFLOW"
	assert_success
	run grep -F 'STEP: upload-gate' "$WORKFLOW"
	assert_success
}

@test "reusable-test-e2e-playwright: publish-test-summary gated to pull_request" {
	run awk '
		/^  publish-test-summary:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  publish-test-summary:/ { in_job = 0 }
		in_job && /github\.event_name == .pull_request./ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-e2e-playwright: passes project grep base-url web-server to run" {
	run awk '
		/Run Playwright/ { in_step = 1 }
		in_step && /PROJECT: \$\{\{ inputs\.project \}\}/ { project = 1 }
		in_step && /GREP: \$\{\{ inputs\.grep \}\}/ { grep = 1 }
		in_step && /BASE_URL: \$\{\{ inputs\.base-url \}\}/ { base = 1 }
		in_step && /WEB_SERVER: \$\{\{ inputs\.web-server \}\}/ { web = 1 }
		END { exit !(project && grep && base && web) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-e2e-playwright: default test-command is npx playwright test" {
	run awk '
		/^      test-command:/ { in_input = 1 }
		in_input && /^      [a-zA-Z0-9_-]+:/ && !/^      test-command:/ { in_input = 0 }
		in_input && /default: "npx playwright test"/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

# -----------------------------------------------------------------------------
# Reporter contract (#804)
# -----------------------------------------------------------------------------

@test "reusable-test-e2e-playwright: reporters input defaults to one list,json,junit,html set" {
	run awk '
		/^      reporters:/ { in_input = 1 }
		in_input && /^      [a-zA-Z0-9_-]+:/ && !/^      reporters:/ { in_input = 0 }
		in_input && /default: "list,json,junit,html"/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-e2e-playwright: run step receives REPORTERS from the reporters input" {
	run awk '
		/Run Playwright/ { in_step = 1 }
		in_step && /REPORTERS: \$\{\{ inputs\.reporters \}\}/ { found = 1 }
		in_step && /Parse results/ { in_step = 0 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-test-e2e-playwright: no literal --reporter flag is assembled in the workflow" {
	# Reporter selection lives in run-playwright-tests.sh (one flag); the
	# workflow must not append a second one.
	run grep -E -- '--reporter=' "$WORKFLOW"
	assert_failure
}

@test "reusable-test-e2e-playwright: upload-report-when defaults to failure and reaches the gate" {
	run awk '
		/^      upload-report-when:/ { in_input = 1 }
		in_input && /^      [a-zA-Z0-9_-]+:/ && !/^      upload-report-when:/ { in_input = 0 }
		in_input && /default: "failure"/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
	run grep -F 'UPLOAD_REPORT_WHEN: ${{ inputs.upload-report-when }}' "$WORKFLOW"
	assert_success
}

@test "reusable-test-e2e-playwright: report artifact includes HTML, JSON and JUnit outputs" {
	run grep -F '${{ inputs.working-directory }}/playwright-report/' "$WORKFLOW"
	assert_success
	run grep -F '${{ inputs.working-directory }}/playwright-results.json' "$WORKFLOW"
	assert_success
	run grep -F '${{ inputs.working-directory }}/playwright-results.xml' "$WORKFLOW"
	assert_success
}

@test "reusable-test-e2e-playwright: verdict step re-raises a run step that failed without an exit code" {
	run awk '
		/Fail on Playwright errors/ { in_step = 1 }
		in_step && /steps\.run\.outcome == .failure./ { outcome = 1 }
		in_step && /EXIT_CODE: \$\{\{ steps\.run\.outputs\.exit-code \|\| .1. \}\}/ { fallback = 1 }
		END { exit !(outcome && fallback) }
	' "$WORKFLOW"
	assert_success
}
