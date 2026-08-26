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

@test "install-ai-review-cli: Cursor pin includes long-headless-session fix" {
	# Cursor 2026.08.11 fixed wedged uploads silently stalling long headless
	# sessions; older pins reproduce the AI review hang under larger PRs.
	run grep -F 'CURSOR_AGENT_VERSION="${CURSOR_AGENT_VERSION:-2026.08.11-e8db854}"' "$SCRIPT"
	assert_success
	run grep -F 'CURSOR_AGENT_SHA256_X64="${CURSOR_AGENT_SHA256_X64:-bfff4bf6f4e9dd30c1d0ef0a70b6077b074015dd2948e4c50685d53afdcfce5a}"' "$SCRIPT"
	assert_success
	run grep -F 'CURSOR_AGENT_SHA256_ARM64="${CURSOR_AGENT_SHA256_ARM64:-ea13f92e295f523a99ce8d8f57d6894d21e5d1e2d030ffad718ccd5955ca2eed}"' "$SCRIPT"
	assert_success
}

@test "install-ai-review-cli: EXIT trap is safe under set -u outside function scope" {
	# Regression (#889 pilot run): the EXIT trap fires at script exit, where a
	# function-local tmp is out of scope — set -u then kills the trap and the
	# step. tmp must not be declared local, and the trap must default-expand.
	run grep -F 'trap '\''rm -rf "${tmp:-}"'\'' EXIT' "$SCRIPT"
	assert_success
	# Match every local declaration form: bare (`local tmp`), listed
	# (`local a tmp b`), and assignment (`local tmp=...`).
	run bash -c "grep -E '\blocal\b[^#]*\btmp\b' '$SCRIPT'"
	assert_failure
}
