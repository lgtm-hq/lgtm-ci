#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/ai_review_matrix.sh

load "../../../helpers/common"

MATRIX="${PROJECT_ROOT}/scripts/ci/lib/ai_review_matrix.sh"

@test "ai_review_credential_env: matrix rows" {
	run bash -c "source '$MATRIX' && ai_review_credential_env anthropic api"
	assert_success
	assert_output "ANTHROPIC_API_KEY"
	run bash -c "source '$MATRIX' && ai_review_credential_env anthropic cli"
	assert_success
	assert_output "CLAUDE_CODE_OAUTH_TOKEN"
	run bash -c "source '$MATRIX' && ai_review_credential_env cursor cli"
	assert_success
	assert_output "CURSOR_API_KEY"
	run bash -c "source '$MATRIX' && ai_review_credential_env openai api"
	assert_success
	assert_output "OPENAI_API_KEY"
	run bash -c "source '$MATRIX' && ai_review_credential_env openai cli"
	assert_success
	assert_output "CODEX_AUTH_JSON"
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
	assert_success
	assert_output "claude"
	run bash -c "source '$MATRIX' && ai_review_cli_binary cursor cli"
	assert_success
	assert_output "agent"
	run bash -c "source '$MATRIX' && ai_review_cli_binary openai cli"
	assert_success
	assert_output "codex"
	run bash -c "source '$MATRIX' && ai_review_cli_binary anthropic api"
	assert_success
	assert_output ""
	run bash -c "source '$MATRIX' && ai_review_cli_binary unknown cli"
	assert_success
	assert_output ""
}

@test "ai_review_normalize: case fold" {
	run bash -c "source '$MATRIX' && ai_review_normalize AnThRoPiC"
	assert_success
	assert_output "anthropic"
	run bash -c "source '$MATRIX' && ai_review_normalize ''"
	assert_success
	assert_output ""
}

@test "ai_review_needs_cli: true only for cli pairs" {
	run bash -c "source '$MATRIX' && ai_review_needs_cli cursor cli && echo yes"
	assert_success
	assert_output "yes"
	run bash -c "source '$MATRIX' && ai_review_needs_cli anthropic api || echo no"
	assert_success
	assert_output "no"
	run bash -c "source '$MATRIX' && ai_review_needs_cli '' cli || echo no"
	assert_success
	assert_output "no"
}

@test "auth defaults: subscription CLI and metered API/Cursor" {
    for pair in 'anthropic cli oauth' 'openai cli oauth' 'cursor cli api_key' 'anthropic api api_key' 'openai api api_key'; do
        read -r provider transport expected <<<"$pair"
        run bash -c 'source "$1"; ai_review_default_auth "$2" "$3"' matrix "$MATRIX" "$provider" "$transport"
        assert_success
        assert_output "$expected"
    done
}

@test "auth matrix: each supported tuple has one credential and rejected tuples have none" {
    for tuple in 'anthropic cli api_key ANTHROPIC_API_KEY' 'openai cli api_key CODEX_API_KEY' 'openai cli oauth CODEX_AUTH_JSON'; do
        read -r provider transport auth expected <<<"$tuple"
        run bash -c 'source "$1"; ai_review_credential_env "$2" "$3" "$4"' matrix "$MATRIX" "$provider" "$transport" "$auth"
        assert_output "$expected"
    done
    for tuple in 'openai api oauth' 'anthropic api oauth' 'cursor cli oauth' 'cursor api api_key' 'openai cli bogus'; do
        read -r provider transport auth <<<"$tuple"
        run bash -c 'source "$1"; ai_review_credential_env "$2" "$3" "$4"' matrix "$MATRIX" "$provider" "$transport" "$auth"
        assert_output ""
    done
}
