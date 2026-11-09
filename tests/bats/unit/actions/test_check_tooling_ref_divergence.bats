#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for .github/actions/checkout-and-harden/check-tooling-ref-divergence.sh (#1368)

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/.github/actions/checkout-and-harden/check-tooling-ref-divergence.sh"

setup() {
	TOOLING="${BATS_TEST_TMPDIR}/tooling"
	mkdir -p "$TOOLING"
	git -C "$TOOLING" init -q
	git -C "$TOOLING" -c user.name=t -c user.email=t@example.com \
		-c commit.gpgsign=false commit -q --allow-empty -m one
	HEAD_SHA="$(git -C "$TOOLING" rev-parse HEAD)"
	OTHER_SHA="0123456789abcdef0123456789abcdef01234567"
}

@test "check-tooling-ref-divergence: no-op when the override is empty" {
	run env TOOLING_REF_OVERRIDE="" WORKFLOW_SHA="$OTHER_SHA" TOOLING_DIR="$TOOLING" bash "$SCRIPT"
	assert_success
	assert_output ""
}

@test "check-tooling-ref-divergence: no-op when the override is unset" {
	run env -u TOOLING_REF_OVERRIDE WORKFLOW_SHA="$OTHER_SHA" TOOLING_DIR="$TOOLING" bash "$SCRIPT"
	assert_success
	assert_output ""
}

@test "check-tooling-ref-divergence: passes silently when the SHAs match" {
	run env TOOLING_REF_OVERRIDE="$HEAD_SHA" WORKFLOW_SHA="$HEAD_SHA" TOOLING_DIR="$TOOLING" bash "$SCRIPT"
	assert_success
	assert_output ""
}

@test "check-tooling-ref-divergence: SHA comparison ignores case" {
	local upper
	upper="$(printf '%s' "$HEAD_SHA" | tr '[:lower:]' '[:upper:]')"
	run env TOOLING_REF_OVERRIDE="$HEAD_SHA" WORKFLOW_SHA="$upper" TOOLING_DIR="$TOOLING" bash "$SCRIPT"
	assert_success
	assert_output ""
}

@test "check-tooling-ref-divergence: fails naming both SHAs, #995 and the fix" {
	run env TOOLING_REF_OVERRIDE="$HEAD_SHA" WORKFLOW_SHA="$OTHER_SHA" TOOLING_DIR="$TOOLING" bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error title=tooling-ref divergence::"
	assert_output --partial "$HEAD_SHA"
	assert_output --partial "$OTHER_SHA"
	assert_output --partial "#995"
	assert_output --partial "remove tooling-ref"
}

@test "check-tooling-ref-divergence: a non-true escape hatch still fails" {
	run env TOOLING_REF_OVERRIDE="$HEAD_SHA" WORKFLOW_SHA="$OTHER_SHA" ALLOW_DIVERGENCE="false" \
		TOOLING_DIR="$TOOLING" bash "$SCRIPT"
	assert_failure
	run env TOOLING_REF_OVERRIDE="$HEAD_SHA" WORKFLOW_SHA="$OTHER_SHA" ALLOW_DIVERGENCE="" \
		TOOLING_DIR="$TOOLING" bash "$SCRIPT"
	assert_failure
}

@test "check-tooling-ref-divergence: escape hatch warns and continues" {
	run env TOOLING_REF_OVERRIDE="$HEAD_SHA" WORKFLOW_SHA="$OTHER_SHA" ALLOW_DIVERGENCE="true" \
		TOOLING_DIR="$TOOLING" bash "$SCRIPT"
	assert_success
	assert_output --partial "::warning title=tooling-ref divergence::"
	assert_output --partial "$HEAD_SHA"
	assert_output --partial "$OTHER_SHA"
	refute_output --partial "::error"
}

@test "check-tooling-ref-divergence: skips with a notice when job.workflow_sha is unavailable" {
	run env TOOLING_REF_OVERRIDE="$HEAD_SHA" WORKFLOW_SHA="" TOOLING_DIR="$TOOLING" bash "$SCRIPT"
	assert_success
	assert_output --partial "::notice"
}

@test "check-tooling-ref-divergence: fails when the tooling checkout cannot be resolved" {
	run env TOOLING_REF_OVERRIDE="$HEAD_SHA" WORKFLOW_SHA="$OTHER_SHA" \
		TOOLING_DIR="${BATS_TEST_TMPDIR}/missing" bash "$SCRIPT"
	assert_failure
	assert_output --partial "::error"
}
