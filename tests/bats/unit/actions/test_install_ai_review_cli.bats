#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/install-ai-review-cli.sh gating

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/install-ai-review-cli.sh"

@test "install-ai-review-cli: skips when transport is api" {
	run env PROVIDER=anthropic TRANSPORT=api bash "$SCRIPT"
	assert_success
	assert_output --partial "no CLI binary"
}

@test "install-ai-review-cli: skips when provider is unset" {
	run env PROVIDER="" TRANSPORT="cli" bash "$SCRIPT"
	assert_success
	assert_output --partial "no CLI binary"
}

@test "install-ai-review-cli: rejects non-semver claude pin" {
	run env PROVIDER=anthropic TRANSPORT=cli CLAUDE_CODE_VERSION=latest bash "$SCRIPT"
	assert_failure
	assert_output --partial "exact X.Y.Z"
}

@test "install-ai-review-cli: rejects non-semver codex pin" {
	run env PROVIDER=openai TRANSPORT=cli CODEX_VERSION='^0.1.0' bash "$SCRIPT"
	assert_failure
	assert_output --partial "exact X.Y.Z"
}

@test "install-ai-review-cli: Cursor download uses download_with_retries" {
	run grep -F "download_with_retries" "$SCRIPT"
	assert_success
	run grep -F "lib/network/download.sh" "$SCRIPT"
	assert_success
}
