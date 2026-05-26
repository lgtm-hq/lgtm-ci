#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for publish workflows that reuse lgtm-ci tooling

load "../../helpers/common"

_publish_checkout_order_ok() {
	local workflow="$1"
	awk '
		/^    steps:/ { in_steps = 1 }
		in_steps && /^      - name: Harden runner/ { harden = NR }
		in_steps && /^      - name: Checkout repository/ { repo = NR }
		in_steps && /^      - name: Checkout lgtm-ci tooling/ { tooling = NR }
		END {
			ok = (harden > 0 && repo > 0 && tooling > 0 && harden < repo && repo < tooling)
			exit !ok
		}
	' "$workflow"
}

_publish_tooling_actions_ok() {
	local workflow="$1"
	awk '
		/\.\/\.lgtm-ci-tooling\/\.github\/actions\/generate-coverage-badge/ { badge = 1 }
		/\.\/\.lgtm-ci-tooling\/\.github\/actions\/publish-test-results/ { publish = 1 }
		END { exit !(badge && publish) }
	' "$workflow"
}

@test "reusable-test-python-publish: checkout order preserves tooling in isolated jobs" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-python-publish.yml"
	run _publish_checkout_order_ok "$workflow"
	assert_success
}

@test "reusable-test-python-publish: uses local tooling actions for badge and Pages publish" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-python-publish.yml"
	run _publish_tooling_actions_ok "$workflow"
	assert_success
}

@test "reusable-test-python-publish: does not rely on clean: false workaround" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-python-publish.yml"
	run grep -q 'clean: false' "$workflow"
	assert_failure
}

@test "reusable-test-node-publish: checkout order preserves tooling in isolated jobs" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-node-publish.yml"
	run _publish_checkout_order_ok "$workflow"
	assert_success
}

@test "reusable-test-node-publish: uses local tooling actions for badge and Pages publish" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-node-publish.yml"
	run _publish_tooling_actions_ok "$workflow"
	assert_success
}

@test "reusable-test-node-publish: does not rely on clean: false workaround" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-node-publish.yml"
	run grep -q 'clean: false' "$workflow"
	assert_failure
}

@test "publish-test-results: uses official GitHub Pages actions" {
	local action="${PROJECT_ROOT}/.github/actions/publish-test-results/action.yml"
	run grep -E 'peaceiris|actions-gh-pages' "$action"
	assert_failure
	run grep -q 'actions/configure-pages@' "$action"
	assert_success
	run grep -q 'actions/upload-pages-artifact@' "$action"
	assert_success
	run grep -q 'actions/deploy-pages@' "$action"
	assert_success
}

@test "publish-test-results: no legacy gh-pages branch inputs" {
	local action="${PROJECT_ROOT}/.github/actions/publish-test-results/action.yml"
	run grep -qE 'target-branch|keep-history|retention-days' "$action"
	assert_failure
}

@test "reusable-test-python-publish: official Pages job contract" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-python-publish.yml"
	run grep -q 'group: pages-${{ github.repository }}-${{ github.ref }}' "$workflow"
	assert_success
	run grep -q 'name: github-pages' "$workflow"
	assert_success
	run grep -q 'id-token: write' "$workflow"
	assert_success
	run grep -q 'contents: read' "$workflow"
	assert_success
	run grep -q 'contents: write' "$workflow"
	assert_failure
}

@test "reusable-test-node-publish: official Pages job contract" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-node-publish.yml"
	run grep -q 'group: pages-${{ github.repository }}-${{ github.ref }}' "$workflow"
	assert_success
	run grep -q 'name: github-pages' "$workflow"
	assert_success
	run grep -q 'id-token: write' "$workflow"
	assert_success
	run grep -q 'contents: read' "$workflow"
	assert_success
	run grep -q 'contents: write' "$workflow"
	assert_failure
}

@test "reusable-coverage: publish job uses official Pages contract" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-coverage.yml"
	run awk '/^  publish:/{p=1} p&&/name: github-pages/{e=1} p&&/id-token: write/{i=1} p&&/contents: read/{r=1} p&&/group: pages-\$\{\{ github.repository \}\}-\$\{\{ github.ref \}\}/{c=1} END{exit !(e&&i&&r&&c)}' "$workflow"
	assert_success
	run awk '/^  publish:/{p=1} p&&/contents: write/{exit 1} END{exit 0}' "$workflow"
	assert_success
}

@test "reusable-test-e2e-matrix: publish job uses official Pages contract" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-e2e-matrix.yml"
	run awk '/^  publish:/{p=1} p&&/name: github-pages/{e=1} p&&/id-token: write/{i=1} p&&/contents: read/{r=1} p&&/group: pages-\$\{\{ github.repository \}\}-\$\{\{ github.ref \}\}/{c=1} END{exit !(e&&i&&r&&c)}' "$workflow"
	assert_success
	run awk '/^  publish:/{p=1} p&&/contents: write/{exit 1} END{exit 0}' "$workflow"
	assert_success
}

@test "reusable-deploy-pages: shares Pages concurrency group" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-deploy-pages.yml"
	run grep -q 'group: pages-${{ github.repository }}-${{ github.ref }}' "$workflow"
	assert_success
}
