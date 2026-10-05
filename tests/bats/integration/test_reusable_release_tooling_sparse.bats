#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Release reusables' two-phase tooling checkouts keep scripts/ci and no stale egress composites

load "../../helpers/common"

_release_scripts_sparse_is_scripts_only() {
	local workflow="$1"
	awk '
		/Checkout lgtm-ci bootstrap tooling/ { saw_bootstrap = 1 }
		saw_bootstrap && /- name: Checkout lgtm-ci tooling/ { block = 1 }
		saw_bootstrap && /- name: Restore tooling for post-PR steps/ { block = 1 }
		block && /sparse-checkout: \|/ {
			in_sparse = 1
			has_scripts = has_stale = 0
			next
		}
		in_sparse && /scripts\/ci\// { has_scripts = 1 }
		in_sparse && /\.github\/actions\/(harden-runner|resolve-egress-allowlist)/ { has_stale = 1 }
		in_sparse && /^          [a-zA-Z]/ && !/^          \./ && !/^          scripts/ {
			if (!has_scripts || has_stale) {
				bad = 1
			}
			in_sparse = 0
			block = 0
		}
		END { exit bad }
	' "$workflow"
}

@test "reusable-release-auto-tag: scripts sparse checkout keeps scripts/ci and no removed egress composites" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-auto-tag.yml"
	run _release_scripts_sparse_is_scripts_only "$workflow"
	assert_success
}

@test "reusable-release-version-pr: scripts sparse checkout keeps scripts/ci and no removed egress composites" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"
	run _release_scripts_sparse_is_scripts_only "$workflow"
	assert_success
}

@test "release reusables: bootstrap tooling checkout no longer lists egress composites" {
	local workflow
	for workflow in reusable-release-auto-tag reusable-release-version-pr reusable-release-multi-ecosystem; do
		run grep -E '\.github/actions/(harden-runner|resolve-egress-allowlist)' "${PROJECT_ROOT}/.github/workflows/${workflow}.yml"
		assert_failure
	done
}
