#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for bundle workflow artifacts and deploy-site-with-reports (#226)

load "../../helpers/common"

@test "bundle-workflow-artifacts action: references script not inline shell" {
	local action="${PROJECT_ROOT}/.github/actions/bundle-workflow-artifacts/action.yml"
	run grep -q 'bundle-workflow-artifacts.sh' "$action"
	assert_success
	run awk '
		/^    - name: Bundle workflow artifacts/ { in_bundle = 1 }
		in_bundle && /^    - name:/ && $0 !~ /Bundle workflow artifacts/ { exit 0 }
		in_bundle && /run: \|/ { exit 1 }
		END { exit 0 }
	' "$action"
	assert_success
}

@test "bundle-workflow-artifacts action: exposes bundle outputs" {
	local action="${PROJECT_ROOT}/.github/actions/bundle-workflow-artifacts/action.yml"
	run grep -q 'files-bundled' "$action"
	assert_success
	run grep -q 'bundles-applied' "$action"
	assert_success
	run grep -q 'bundle-warnings' "$action"
	assert_success
}

@test "reusable-deploy-site-with-reports: build job has actions read permission" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-deploy-site-with-reports.yml"
	run awk '
		/^  build:/ { in_build = 1 }
		/^  deploy:/ { in_build = 0 }
		in_build && /actions: read/ { actions = 1 }
		in_build && /contents: read/ { contents = 1 }
		END { exit !(actions && contents) }
	' "$workflow"
	assert_success
}

@test "reusable-deploy-site-with-reports: bundles after build and before upload" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-deploy-site-with-reports.yml"
	run awk '
		/^  build:/ { in_build = 1 }
		/^  deploy:/ { in_build = 0 }
		in_build && /name: Build site/ { build = NR }
		in_build && /name: Bundle workflow artifacts/ { bundle = NR }
		in_build && /name: Prepare and upload artifact/ { upload = NR }
		END { exit !(build > 0 && bundle > 0 && upload > 0 && build < bundle && bundle < upload) }
	' "$workflow"
	assert_success
}

@test "reusable-deploy-site-with-reports: uses official Pages deploy actions" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-deploy-site-with-reports.yml"
	run grep -q 'actions/configure-pages@' "$workflow"
	assert_success
	run grep -q 'actions/deploy-pages@' "$workflow"
	assert_success
	run grep -q 'bundle-workflow-artifacts' "$workflow"
	assert_success
}

@test "reusable-deploy-site-with-reports: shared pages concurrency group" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-deploy-site-with-reports.yml"
	run grep -q 'group: pages-${{ github.repository }}-${{ github.ref }}' "$workflow"
	assert_success
}

@test "reusable-deploy-site-with-reports: build job checkout order" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-deploy-site-with-reports.yml"
	run egress_tooling_checkout_order_ok "$workflow" "build"
	assert_success
}

@test "reusable-deploy-site-with-reports: exposes page-url output" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-deploy-site-with-reports.yml"
	run grep -q 'jobs.deploy.outputs.page-url' "$workflow"
	assert_success
}

@test "reusable-deploy-site-with-reports: per-job allowed-endpoints inputs" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-deploy-site-with-reports.yml"
	run grep -q 'allowed-endpoints-build:' "$workflow"
	assert_success
	run grep -q 'allowed-endpoints-deploy:' "$workflow"
	assert_success
	run grep -q 'inputs.allowed-endpoints-build' "$workflow"
	assert_success
	run grep -q 'inputs.allowed-endpoints-deploy' "$workflow"
	assert_success
}

@test "reusable-deploy-site-with-reports: no inline shell in build job" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-deploy-site-with-reports.yml"
	run awk '
		/^  build:/ { in_build = 1 }
		/^  deploy:/ { in_build = 0 }
		in_build && /run: \|/ { inline = 1 }
		END { exit inline }
	' "$workflow"
	assert_success
}

@test "example turbo-themes manifest: valid JSON with expected bundles" {
	local manifest="${PROJECT_ROOT}/examples/bundle-manifest-turbo-themes.json"
	run jq -e '.bundles | length >= 5' "$manifest"
	assert_success
	run jq -e '.bundles[] | select(.dest == "coverage")' "$manifest"
	assert_success
}
