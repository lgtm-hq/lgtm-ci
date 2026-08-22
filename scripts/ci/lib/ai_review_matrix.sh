#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: (provider, transport) → credential / CLI binary for reusable-ai-review.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/ai_review_matrix.sh"
#   ai_review_credential_env anthropic api    # → ANTHROPIC_API_KEY
#   ai_review_cli_binary cursor cli           # → agent
#
# Providers are listed alphabetically. There is no default provider or
# transport — empty inputs stay empty.

[[ -n "${_LGTM_CI_AI_REVIEW_MATRIX_LOADED:-}" ]] && return 0
readonly _LGTM_CI_AI_REVIEW_MATRIX_LOADED=1

# Normalize a provider or transport token to lowercase. Empty stays empty.
ai_review_normalize() {
	printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

# Credential environment variable for one (provider, transport) pair.
# Prints nothing when the pair is incomplete or unknown.
ai_review_credential_env() {
	local provider transport
	provider="$(ai_review_normalize "${1:-}")"
	transport="$(ai_review_normalize "${2:-}")"
	case "${provider}:${transport}" in
	anthropic:api) printf '%s\n' ANTHROPIC_API_KEY ;;
	anthropic:cli) printf '%s\n' CLAUDE_CODE_OAUTH_TOKEN ;;
	cursor:cli) printf '%s\n' CURSOR_API_KEY ;;
	openai:api) printf '%s\n' OPENAI_API_KEY ;;
	openai:cli) printf '%s\n' CODEX_API_KEY ;;
	esac
}

# CLI binary name for one (provider, transport) pair. Empty when transport
# is not cli or the pair is unknown.
ai_review_cli_binary() {
	local provider transport
	provider="$(ai_review_normalize "${1:-}")"
	transport="$(ai_review_normalize "${2:-}")"
	[[ "$transport" == "cli" ]] || return 0
	case "$provider" in
	anthropic) printf '%s\n' claude ;;
	cursor) printf '%s\n' agent ;;
	openai) printf '%s\n' codex ;;
	esac
}

# True when the pair needs a pinned CLI binary installed.
ai_review_needs_cli() {
	local binary
	binary="$(ai_review_cli_binary "${1:-}" "${2:-}")"
	[[ -n "$binary" ]]
}

export -f ai_review_normalize ai_review_credential_env
export -f ai_review_cli_binary ai_review_needs_cli
