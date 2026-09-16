#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Every wrapper that runs a release script whose default changelog
#          range comes from latest_stable_tag forwards the configured tag
#          prefix (#1012). Without TAG_PREFIX the script assumes `v`, and a
#          consumer tagging without it would get full-history notes.

load "../../helpers/common"

# Emit the env block of the step that runs the named script.
_script_step_env() {
	local file="$1" script="$2"
	awk -v script="$script" '
		/- name: / { buf = "" }
		{ buf = buf "\n" $0 }
		$0 ~ script { print buf; exit }
	' "$file"
}

@test "tag-prefix wiring: composite actions declare tag-prefix defaulting to v" {
	for action in generate-changelog create-github-release; do
		run awk '/^  tag-prefix:/ { f = 1 } f && /default:/ { print; exit }' \
			"${PROJECT_ROOT}/.github/actions/${action}/action.yml"
		assert_success
		assert_output --partial 'default: "v"'
	done
}

@test "tag-prefix wiring: reusable-github-release declares tag-prefix defaulting to v" {
	run awk '/^      tag-prefix:/ { f = 1 } f && /default:/ { print; exit }' \
		"${PROJECT_ROOT}/.github/workflows/reusable-github-release.yml"
	assert_success
	assert_output --partial 'default: "v"'
}

@test "tag-prefix wiring: every caller forwards TAG_PREFIX to the script" {
	local -a sites=(
		".github/actions/generate-changelog/action.yml generate-changelog.sh"
		".github/actions/create-github-release/action.yml create-github-release.sh"
		".github/workflows/reusable-github-release.yml create-github-release.sh"
		".github/workflows/reusable-release-version-pr.yml generate-changelog.sh"
		".github/workflows/reusable-release-multi-ecosystem.yml generate-changelog.sh"
		".github/workflows/reusable-release-auto-tag.yml create-tag.sh"
		".github/workflows/reusable-release-auto-tag.yml create-github-release.sh"
	)
	local site file script
	for site in "${sites[@]}"; do
		file="${site%% *}"
		script="${site##* }"
		run _script_step_env "${PROJECT_ROOT}/${file}" "$script"
		assert_success
		assert_output --partial "TAG_PREFIX: \${{ inputs.tag-prefix }}"
	done
}
