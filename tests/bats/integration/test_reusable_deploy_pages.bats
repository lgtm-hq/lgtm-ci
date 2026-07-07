#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the deploy-only reusable-deploy-pages workflow

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-deploy-pages.yml"

@test "reusable-deploy-pages: exposes artifact-name input defaulting to github-pages" {
	run awk '
		/^      artifact-name:/ { in_input = 1 }
		in_input && /^      [a-zA-Z0-9_-]+:/ && !/^      artifact-name:/ { in_input = 0 }
		in_input && /default: "github-pages"/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-deploy-pages: egress-preset defaults to github-pages" {
	run awk '
		/^      egress-preset:/ { in_input = 1 }
		in_input && /^      [a-zA-Z0-9_-]+:/ && !/^      egress-preset:/ { in_input = 0 }
		in_input && /default: "github-pages"/ { found = 1 }
		END { exit !found }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-deploy-pages: timeout-minutes input is type number defaulting to 10" {
	run awk '
		/^      timeout-minutes:/ { in_input = 1 }
		in_input && /^      [a-zA-Z0-9_-]+:/ && !/^      timeout-minutes:/ { in_input = 0 }
		in_input && /type: number/ { has_type = 1 }
		in_input && /default: 10/ { has_default = 1 }
		END { exit !(has_type && has_default) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-deploy-pages: drops legacy build inputs" {
	run grep -E '^      (source-path|build-command|node-version|package-manager|working-directory|frozen-lockfile):' \
		"$WORKFLOW"
	assert_failure
}

@test "reusable-deploy-pages: exposes page-url output from deploy job" {
	run grep -F 'value: ${{ jobs.deploy.outputs.page-url }}' "$WORKFLOW"
	assert_success
}

@test "reusable-deploy-pages: shares the pages concurrency group with cancel-in-progress false" {
	run awk '
		/^concurrency:/ { in_conc = 1 }
		in_conc && /^[a-zA-Z]/ && !/^concurrency:/ { in_conc = 0 }
		in_conc && /^  group: pages-\$\{\{ github.repository \}\}-\$\{\{ github.ref \}\}$/ { has_group = 1 }
		in_conc && /cancel-in-progress: false/ { has_cancel = 1 }
		END { exit !(has_group && has_cancel) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-deploy-pages: is deploy-only (single deploy job, no build job)" {
	run awk '
		/^jobs:/ { in_jobs = 1; next }
		in_jobs && /^  [a-zA-Z0-9_-]+:/ { print }
	' "$WORKFLOW"
	assert_success
	assert_output "  deploy:"
}

@test "reusable-deploy-pages: deploy job declares pages and id-token write" {
	run awk '
		/^  deploy:/ { in_job = 1 }
		/^  [a-zA-Z0-9_-]+:/ && !/^  deploy:/ { in_job = 0 }
		in_job && /pages: write/ { has_pages = 1 }
		in_job && /id-token: write/ { has_oidc = 1 }
		in_job && /contents: read/ { has_contents = 1 }
		END { exit !(has_pages && has_oidc && has_contents) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-deploy-pages: deploy job runs-on inputs.runner-image" {
	run grep -F 'runs-on: ${{ inputs.runner-image }}' "$WORKFLOW"
	assert_success
}

@test "reusable-deploy-pages: deploy job checkout order preserves tooling" {
	run egress_tooling_checkout_order_ok "$WORKFLOW" "deploy"
	assert_success
}

@test "reusable-deploy-pages: deploy step consumes artifact-name via deploy-pages action" {
	run awk '
		/- name: Deploy to GitHub Pages/ { in_step = 1 }
		in_step && /uses: actions\/deploy-pages@/ { has_action = 1 }
		in_step && /artifact_name: \$\{\{ inputs\.artifact-name \}\}/ { has_artifact = 1 }
		END { exit !(has_action && has_artifact) }
	' "$WORKFLOW"
	assert_success
}

@test "reusable-deploy-pages: deploy-pages action is SHA-pinned with version comment" {
	run grep -F 'actions/deploy-pages@cd2ce8fcbc39b97be8ca5fce6e763baed58fa128 # v5.0.0' \
		"$WORKFLOW"
	assert_success
}

@test "reusable-deploy-pages: does not build or upload the Pages artifact" {
	run grep -E '^ *uses: .*(configure-pages|upload-pages-artifact)|- name: Setup Node|- name: Install dependencies' \
		"$WORKFLOW"
	assert_failure
}
