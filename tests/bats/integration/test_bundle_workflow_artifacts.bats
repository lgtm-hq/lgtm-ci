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

@test "bundle-workflow-artifacts action: passes GH_TOKEN for gh CLI" {
	local action="${PROJECT_ROOT}/.github/actions/bundle-workflow-artifacts/action.yml"
	run awk '
		/^    - name: Bundle workflow artifacts/ { in_bundle = 1 }
		in_bundle && /^    - name:/ && $0 !~ /Bundle workflow artifacts/ { in_bundle = 0 }
		in_bundle && /GH_TOKEN: \$\{\{ github\.token \}\}/ { gh_token = 1 }
		in_bundle && /GITHUB_TOKEN:/ { github_token = 1 }
		END { exit !(gh_token && !github_token) }
	' "$action"
	assert_success
}

@test "reusable-deploy-site-with-reports: build job has actions permission" {
	# actions: write (implies read) so it can both resolve/download workflow
	# artifacts for bundling and prune stale same-run Pages artifacts (#415).
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-deploy-site-with-reports.yml"
	run awk '
		/^  build:/ { in_build = 1 }
		/^  deploy:/ { in_build = 0 }
		in_build && /actions: (read|write)/ { actions = 1 }
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
	run grep -q 'actions/deploy-pages@' "$workflow"
	assert_success
	run grep -q 'bundle-workflow-artifacts' "$workflow"
	assert_success
}

@test "reusable-deploy-site-with-reports: build job does not run configure-pages" {
	# configure-pages calls GET /repos/{owner}/{repo}/pages, which needs Pages
	# access on a private repository. build has no Pages permission (#1447).
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-deploy-site-with-reports.yml"
	run awk '
		/^  build:/ { in_build = 1; next }
		/^  [A-Za-z0-9_-]+:/ { in_build = 0 }
		in_build && /uses: *["'\'']?actions\/configure-pages@/ { found = 1 }
		END { exit found }
	' "$workflow"
	assert_success
	# build calls this composite, so it must not configure Pages either.
	run grep -c 'actions/configure-pages@' \
		"${PROJECT_ROOT}/.github/actions/deploy-pages/action.yml"
	assert_output "0"
}

@test "reusable-deploy-site-with-reports: build job holds no Pages permission" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-deploy-site-with-reports.yml"
	run awk '
		/^  build:/ { in_build = 1; next }
		/^  [A-Za-z0-9_-]+:/ { in_build = 0 }
		in_build && /^      pages:/ { found = 1 }
		# An inline value such as write-all or { pages: read } would grant
		# Pages access without a block-style pages: key.
		in_build && /^    permissions: *[^ #]/ { found = 1 }
		END { exit found }
	' "$workflow"
	assert_success
}

@test "reusable-deploy-site-with-reports: deploy job runs configure-pages before deploy-pages" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-deploy-site-with-reports.yml"
	run awk '
		/^  deploy:/ { in_deploy = 1; next }
		/^  [A-Za-z0-9_-]+:/ { in_deploy = 0 }
		in_deploy && /^      pages: write/ { pages = 1 }
		# Anchored so a commented-out step does not count as present.
		in_deploy && /^ +(- )?name: Checkout and harden/ { harden = NR }
		in_deploy && /^ +(- )?uses: actions\/configure-pages@/ { configure = NR; count++ }
		in_deploy && /^ +(- )?uses: actions\/deploy-pages@/ { deploy = NR }
		END {
			exit !(pages && count == 1 && harden > 0 && deploy > 0 \
				&& harden < configure && configure < deploy)
		}
	' "$workflow"
	assert_success
}

@test "reusable-deploy-site-with-reports: the configure-pages step is unconditional" {
	# A step switched off with if: or allowed to fail would pass the placement
	# test while skipping the Pages check.
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-deploy-site-with-reports.yml"
	run awk '
		/^      - / { in_step = 0 }
		/^      - name: Configure Pages$/ { in_step = 1; seen = 1; next }
		in_step && /^ +(if|continue-on-error):/ { bad = 1 }
		END { exit !(seen && !bad) }
	' "$workflow"
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
		# The generated harden-runner agent check (#1203) is drift-checked.
		pending && !/# lgtm-ci-inline:begin verify-harden-runner-agent$/ { inline = 1 }
		{ pending = 0 }
		in_build && /run: \|/ { pending = 1 }
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
