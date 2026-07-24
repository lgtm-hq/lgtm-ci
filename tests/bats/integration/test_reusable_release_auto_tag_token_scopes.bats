#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Auto-tag App token must declare its scopes explicitly (see #698)
#
# The floating-tag push moves `v0` onto a commit whose range can touch
# `.github/workflows/**`; GitHub rejects that as a workflow update unless the
# App token carries `workflows`. Requesting scopes implicitly let the token
# silently track the App's configuration, so the missing permission stayed
# invisible until a release failed.

load "../../helpers/common"

# Emit the `with:` block of the named step, stopping at the next step.
_step_with_block() {
	local workflow="$1" step="$2"
	awk -v step="$step" '
		$0 ~ "- name: " step { in_step = 1; next }
		in_step && /^      - name: / { exit }
		in_step { print }
	' "$workflow"
}

@test "reusable-release-auto-tag: App token declares contents and workflows scopes" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-auto-tag.yml"

	run _step_with_block "$workflow" "Create GitHub App installation token"
	assert_success
	assert_output --partial "permission-contents: write"
	assert_output --partial "permission-workflows: write"
}

@test "reusable-release-auto-tag: floating-tag step still pushes v0" {
	local workflow="${PROJECT_ROOT}/.github/workflows/reusable-release-auto-tag.yml"

	run _step_with_block "$workflow" "Update floating tag"
	assert_success
	assert_output --partial 'PUSH: "true"'
}
