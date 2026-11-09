#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests - callers that ship their own report keep it
#          unwrapped by passing raw: true to the artifact report publisher.

load "../../helpers/common"

WORKFLOWS="${PROJECT_ROOT}/.github/workflows"

# Print the `with:` block of the job that calls the report publisher.
publisher_with_block() {
	awk '
		/^  [a-z0-9-]+:$/ { in_call = 0; in_with = 0 }
		/uses: .*reusable-publish-artifact-report\.yml/ { in_call = 1 }
		in_call && /^    with:$/ { in_with = 1; next }
		in_call && in_with && /^    [a-z-]+:/ { in_with = 0 }
		in_call && in_with { print }
	' "$1"
}

@test "contract: reusable-link-check passes raw: true to the report publisher" {
	run publisher_with_block "${WORKFLOWS}/reusable-link-check.yml"
	assert_success
	assert_line "      raw: true"
}

@test "contract: reusable-validate passes raw: true to the report publisher" {
	run publisher_with_block "${WORKFLOWS}/reusable-validate.yml"
	assert_success
	assert_line "      raw: true"
}

@test "contract: report publisher declares raw as boolean defaulting to false" {
	run awk '/^      raw:$/ {f=1} f && /type:/ {t=$2} f && /default:/ {print t, $2; exit}' \
		"${WORKFLOWS}/reusable-publish-artifact-report.yml"
	assert_success
	assert_output "boolean false"
}

@test "contract: every in-repo caller of the report publisher sets raw explicitly" {
	local f
	for f in "${WORKFLOWS}"/*.yml; do
		[[ "$f" == *reusable-publish-artifact-report.yml ]] && continue
		grep -q 'reusable-publish-artifact-report\.yml' "$f" || continue
		run publisher_with_block "$f"
		assert_success
		assert_output --partial "raw: "
	done
}
