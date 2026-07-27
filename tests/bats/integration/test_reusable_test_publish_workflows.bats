#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for publish workflows that reuse lgtm-ci tooling

load "../../helpers/common"

_publish_tooling_actions_ok() {
	local workflow="$1"
	awk '
		/\.\/\.lgtm-ci-tooling\/\.github\/actions\/generate-coverage-badge/ { badge = 1 }
		/\.\/\.lgtm-ci-tooling\/\.github\/actions\/publish-test-results/ { publish = 1 }
		END { exit !(badge && publish) }
	' "$workflow"
}

_publish_pages_contract_ok() {
	local workflow="$1"
	awk '
		/^  publish:/ { in_publish = 1 }
		in_publish && /name: github-pages/ { env = 1 }
		in_publish && /id-token: write/ { id_token = 1 }
		in_publish && /contents: read/ { contents_read = 1 }
		in_publish && /group: pages-\$\{\{ github.repository \}\}-\$\{\{ github.ref \}\}/ {
			concurrency = 1
		}
		END { exit !(env && id_token && contents_read && concurrency) }
	' "$workflow"
}

_publish_no_contents_write_ok() {
	local workflow="$1"
	awk '
		/^  publish:/ { in_publish = 1 }
		in_publish && /contents: write/ { exit 1 }
		END { exit 0 }
	' "$workflow"
}

@test "reusable-test-python-publish: checkout order preserves tooling in isolated jobs" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-test-python-publish.yml"
	run egress_tooling_checkout_order_ok "$workflow" "publish"
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
	run egress_tooling_checkout_order_ok "$workflow" "publish"
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

# The publish jobs of reusable-coverage.yml and reusable-test-e2e-matrix.yml
# merged into this one workflow (#770). The Pages contract they had to satisfy
# is unchanged and asserted here, on the file that now owns it — including the
# concurrency group and the github-pages environment, which had to move WITH
# the job or two publishers could race and stomp each other's site.
@test "reusable-publish-test-results-pages: publish job uses official Pages contract" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-publish-test-results-pages.yml"
	run _publish_pages_contract_ok "$workflow"
	assert_success
	run _publish_no_contents_write_ok "$workflow"
	assert_success
	run grep -q './.lgtm-ci-tooling/.github/actions/publish-test-results' "$workflow"
	assert_success
}

# The inverse: the producers must not have kept a Pages publisher behind. A
# leftover job would keep pages/id-token/actions:write in their caller unions
# no matter what its `if:` says.
@test "coverage and e2e-matrix: no Pages publisher survives in the producers" {
	local workflow
	for workflow in reusable-coverage.yml reusable-test-e2e-matrix.yml; do
		run grep -q 'actions/publish-test-results' \
			"${PROJECT_ROOT}/.github/workflows/${workflow}"
		assert_failure
		run grep -q 'name: github-pages' \
			"${PROJECT_ROOT}/.github/workflows/${workflow}"
		assert_failure
		run grep -q 'group: pages-' \
			"${PROJECT_ROOT}/.github/workflows/${workflow}"
		assert_failure
	done
}

@test "reusable-deploy-pages: shares the Pages concurrency group with publishers" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-deploy-pages.yml"
	run grep -q 'group: pages-${{ github.repository }}-${{ github.ref }}' "$workflow"
	assert_success
	run grep -q 'cancel-in-progress: false' "$workflow"
	assert_success
}
