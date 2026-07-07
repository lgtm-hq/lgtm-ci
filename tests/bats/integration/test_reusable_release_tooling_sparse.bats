#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Release reusables must keep egress composites after scripts/ci sparse checkout

load "../../helpers/common"

_release_scripts_sparse_keeps_egress() {
	local workflow="$1"
	awk '
		/Checkout lgtm-ci egress tooling/ { saw_egress = 1 }
		saw_egress && /- name: Checkout lgtm-ci tooling/ { block = 1 }
		saw_egress && /- name: Restore tooling for post-PR steps/ { block = 1 }
		block && /^          sparse-checkout: scripts\/ci\/$/ { bad = 1 }
		block && /sparse-checkout: \|/ {
			in_sparse = 1
			has_scripts = has_harden = has_resolve = 0
			next
		}
		in_sparse && /scripts\/ci\// { has_scripts = 1 }
		in_sparse && /\.github\/actions\/harden-runner/ { has_harden = 1 }
		in_sparse && /\.github\/actions\/resolve-egress-allowlist/ { has_resolve = 1 }
		in_sparse && /^          [a-zA-Z]/ && !/^          \./ && !/^          scripts/ {
			if (!(has_scripts && has_harden && has_resolve)) {
				bad = 1
			}
			in_sparse = 0
			block = 0
		}
		END { exit bad }
	' "$workflow"
}

@test "reusable-release-auto-tag: scripts sparse checkout retains egress composites" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-auto-tag.yml"
	run _release_scripts_sparse_keeps_egress "$workflow"
	assert_success
}

@test "reusable-release-version-pr: scripts sparse checkout retains egress composites" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-version-pr.yml"
	run _release_scripts_sparse_keeps_egress "$workflow"
	assert_success
}
