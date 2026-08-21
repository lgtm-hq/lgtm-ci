#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/ai_review_matrix.sh

load "../../../helpers/common"

MATRIX="${PROJECT_ROOT}/scripts/ci/lib/ai_review_matrix.sh"

@test "ai_review_credential_env: matrix rows" {
	run bash -c "source '$MATRIX' && ai_review_credential_env anthropic api"
	assert_output "ANTHROPIC_API_KEY"
	run bash -c "source '$MATRIX' && ai_review_credential_env anthropic cli"
	assert_output "CLAUDE_CODE_OAUTH_TOKEN"
	run bash -c "source '$MATRIX' && ai_review_credential_env cursor cli"
	assert_output "CURSOR_API_KEY"
	run bash -c "source '$MATRIX' && ai_review_credential_env openai api"
	assert_output "OPENAI_API_KEY"
	run bash -c "source '$MATRIX' && ai_review_credential_env openai cli"
	assert_output "CODEX_API_KEY"
}

@test "ai_review_credential_env: empty for incomplete or unknown pairs" {
	run bash -c "source '$MATRIX' && ai_review_credential_env anthropic"
	assert_success
	assert_output ""
	run bash -c "source '$MATRIX' && ai_review_credential_env cursor api"
	assert_success
	assert_output ""
	run bash -c "source '$MATRIX' && ai_review_credential_env '' cli"
	assert_success
	assert_output ""
}

@test "ai_review_cli_binary: only cli transport" {
	run bash -c "source '$MATRIX' && ai_review_cli_binary anthropic cli"
	assert_output "claude"
	run bash -c "source '$MATRIX' && ai_review_cli_binary cursor cli"
	assert_output "agent"
	run bash -c "source '$MATRIX' && ai_review_cli_binary openai cli"
	assert_output "codex"
	run bash -c "source '$MATRIX' && ai_review_cli_binary anthropic api"
	assert_output ""
}

@test "ai_review_normalize: case fold" {
	run bash -c "source '$MATRIX' && ai_review_normalize AnThRoPiC"
	assert_output "anthropic"
}
