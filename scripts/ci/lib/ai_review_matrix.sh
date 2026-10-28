#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Canonical review capabilities; generated workflow/docs consume these rows.

[[ -n "${_LGTM_CI_AI_REVIEW_MATRIX_LOADED:-}" ]] && return 0
readonly _LGTM_CI_AI_REVIEW_MATRIX_LOADED=1

ai_review_normalize() {
	printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

# provider|transport|auth|default|secret/env|binary|cli_bare|egress
# A session slot is decoded to CODEX_HOME/auth.json, never passed to Codex as env.
ai_review_matrix_rows() {
	cat <<'ROWS'
anthropic|api|api_key|yes|ANTHROPIC_API_KEY|||api.anthropic.com:443
anthropic|cli|oauth|yes|CLAUDE_CODE_OAUTH_TOKEN|claude|never|api.anthropic.com:443 nodejs.org:443 registry.npmjs.org:443
anthropic|cli|api_key|no|ANTHROPIC_API_KEY|claude|always|api.anthropic.com:443 nodejs.org:443 registry.npmjs.org:443
cursor|cli|api_key|yes|CURSOR_API_KEY|agent||downloads.cursor.com:443 api2.cursor.sh:443 api3.cursor.sh:443 agentn.global.api5.cursor.sh:443 repo42.cursor.sh:443
openai|api|api_key|yes|OPENAI_API_KEY|||api.openai.com:443
openai|cli|oauth|yes|CODEX_AUTH_JSON|codex||chatgpt.com:443 auth.openai.com:443 nodejs.org:443 registry.npmjs.org:443
openai|cli|api_key|no|CODEX_API_KEY|codex||api.openai.com:443 nodejs.org:443 registry.npmjs.org:443
ROWS
}

ai_review_default_auth() {
	ai_review_matrix_rows | awk -F '|' -v p="$(ai_review_normalize "${1:-}")" \
		-v t="$(ai_review_normalize "${2:-}")" '$1==p && $2==t && $4=="yes" {print $3}'
}

# Query a tuple; omitted auth uses its static default, never available secrets.
ai_review_matrix_field() {
	local provider transport auth
	provider="$(ai_review_normalize "${1:-}")"
	transport="$(ai_review_normalize "${2:-}")"
	auth="${3-$(ai_review_default_auth "$provider" "$transport")}"
	ai_review_matrix_rows | awk -F '|' -v p="$provider" -v t="$transport" \
		-v a="$auth" -v f="$4" '$1==p && $2==t && $3==a {print $f}'
}

ai_review_credential_env() { ai_review_matrix_field "${1:-}" "${2:-}" "${3-$(ai_review_default_auth "${1:-}" "${2:-}")}" 5; }
ai_review_cli_binary() { ai_review_matrix_field "${1:-}" "${2:-}" "${3-$(ai_review_default_auth "${1:-}" "${2:-}")}" 6; }
ai_review_needs_cli() { [[ -n "$(ai_review_cli_binary "$@")" ]]; }
ai_review_supported_choices() {
	ai_review_matrix_rows | awk -F '|' '
        {printf "%s%s/%s/%s", (NR > 1 ? ", " : ""), $1, $2, $3}
        END {print ""}'
}

export -f ai_review_normalize ai_review_matrix_rows ai_review_default_auth ai_review_matrix_field
export -f ai_review_credential_env ai_review_cli_binary ai_review_needs_cli ai_review_supported_choices
