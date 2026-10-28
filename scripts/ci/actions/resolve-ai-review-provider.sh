#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve the (provider, transport, auth) tuple for reusable-ai-review.yml.
#
# Provider/transport: input → Actions variable → consuming repo config.
# Auth: AUTH_INPUT → VAR_AUTH → static tuple default (no product ai.auth).
# Secrets are never inspected here. Empty/unsupported tuples fail closed.
#
# Harden-runner's first-step allowlist sees only inputs, variables and static
# defaults. Under block egress, config-only tuple components fail visibly.
# MODEL_INPUT/VAR_MODEL and MAX_COST_INPUT/VAR_MAX_COST preserve scalar overlays;
# arbitrary PR configuration does not cross into the credentialed invocation.
# CONFIG_PATH defaults to .lintro-config.yaml; GITHUB_OUTPUT is optional.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/github/output.sh
source "${SCRIPT_DIR}/../lib/github/output.sh"
# shellcheck source=../lib/ai_review_matrix.sh
source "${SCRIPT_DIR}/../lib/ai_review_matrix.sh"

# Trim leading and trailing whitespace from a scalar.
_ai_review_trim() {
	local value="${1:-}"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

# Strip a trailing YAML comment. Values we read (provider/transport) have no `#`.
_ai_review_strip_comment() {
	local value="${1:-}"
	printf '%s' "${value%%#*}"
}

# Unquote a single- or double-quoted YAML scalar.
_ai_review_unquote() {
	local value
	value="$(_ai_review_trim "${1:-}")"
	if [[ "$value" == \"*\" ]]; then
		value="${value#\"}"
		value="${value%\"}"
	elif [[ "$value" == \'*\' ]]; then
		value="${value#\'}"
		value="${value%\'}"
	fi
	printf '%s' "$value"
}

# Extract `field` from a YAML flow mapping blob that contains `{...}`.
_ai_review_flow_field() {
	local field="$1"
	local blob="$2"
	local inside pair key value
	local -a pairs

	inside="${blob#*\{}"
	inside="${inside%%\}*}"
	inside="${inside//$'\n'/,}"

	local IFS=','
	read -ra pairs <<<"$inside" || true

	for pair in "${pairs[@]}"; do
		pair="$(_ai_review_trim "$(_ai_review_strip_comment "$pair")")"
		[[ -n "$pair" && "$pair" == *:* ]] || continue
		# Keys may be quoted (`{"provider": cursor}` is valid YAML) — unquote
		# before matching or the field never resolves.
		key="$(_ai_review_unquote "${pair%%:*}")"
		value="$(_ai_review_unquote "$(_ai_review_strip_comment "${pair#*:}")")"
		if [[ "$key" == "$field" ]]; then
			printf '%s' "$value"
			return 0
		fi
	done
}

# Read ai.provider / ai.transport from a lintro YAML config without PyYAML.
# Accepts a top-level block mapping (`ai:\n  provider: ...`), `ai: # comment`
# then children, and a flow mapping (`ai: {provider: ..., transport: ...}`),
# including a wrapped `{` / `}` pair. Nested mappings stop the block scan.
_ai_review_config_field() {
	local field="$1"
	local path="$2"
	local in_ai=false
	local line rest value stripped

	[[ -f "$path" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line%$'\r'}"
		# The top-level key may be quoted (`"ai":` is valid YAML).
		if [[ "$line" =~ ^[\"\']?ai[\"\']?:[[:space:]]*(.*)$ ]]; then
			rest="$(_ai_review_trim "${BASH_REMATCH[1]}")"
			if [[ "$rest" == \{* ]]; then
				while [[ "$rest" != *\}* ]]; do
					IFS= read -r line || break
					rest+=$'\n'"${line%$'\r'}"
				done
				_ai_review_flow_field "$field" "$rest"
				return 0
			fi
			in_ai=true
			continue
		fi
		if [[ "$in_ai" == true && "$line" =~ ^[^[:space:]#] ]]; then
			break
		fi
		if [[ "$in_ai" != true ]]; then
			continue
		fi
		stripped="$(_ai_review_trim "$(_ai_review_strip_comment "$line")")"
		# Child keys may be quoted too — unquote before comparing, mirroring
		# the flow-mapping path, so the whole quoted-key class stays closed.
		[[ "$stripped" == *:* ]] || continue
		if [[ "$(_ai_review_unquote "${stripped%%:*}")" != "$field" ]]; then
			continue
		fi
		value="$(_ai_review_unquote "${stripped#*:}")"
		printf '%s' "$value"
		return 0
	done <"$path"
}

first_nonempty() {
	local candidate
	for candidate in "$@"; do
		candidate="$(ai_review_normalize "$candidate")"
		if [[ -n "$candidate" ]]; then
			printf '%s' "$candidate"
			return 0
		fi
	done
}

# Harden-runner compares the raw input / Actions variable to lowercase
# literals and cannot fold case. Reject mixed-case overlays; config-file
# values may still be normalized because they never expand that allowlist.
require_lowercase_overlay() {
	local name="$1"
	local value="${2:-}"
	local lowered

	[[ -z "$value" ]] && return 0
	lowered="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
	if [[ "$value" != "$lowered" ]]; then
		echo "ERROR: ${name} must be lowercase (got '${value}'). The harden-runner allowlist compares the raw input or Actions variable and cannot fold case." >&2
		exit 1
	fi
}

require_lowercase_overlay AUTH_INPUT "${AUTH_INPUT:-}"
require_lowercase_overlay VAR_AUTH "${VAR_AUTH:-}"
require_lowercase_overlay PROVIDER_INPUT "${PROVIDER_INPUT:-}"
require_lowercase_overlay TRANSPORT_INPUT "${TRANSPORT_INPUT:-}"
require_lowercase_overlay VAR_PROVIDER "${VAR_PROVIDER:-}"
require_lowercase_overlay VAR_TRANSPORT "${VAR_TRANSPORT:-}"

config_path="${CONFIG_PATH:-.lintro-config.yaml}"
config_provider=""
config_transport=""
if [[ -f "$config_path" ]]; then
	config_provider="$(_ai_review_config_field provider "$config_path")"
	config_transport="$(_ai_review_config_field transport "$config_path")"
fi

provider="$(first_nonempty "${PROVIDER_INPUT:-}" "${VAR_PROVIDER:-}" "$config_provider")"
transport="$(first_nonempty "${TRANSPORT_INPUT:-}" "${VAR_TRANSPORT:-}" "$config_transport")"

auth="${AUTH_INPUT:-${VAR_AUTH:-$(ai_review_default_auth "$provider" "$transport")}}"
auth_source=default
if [[ -n "${AUTH_INPUT:-}" ]]; then
	auth_source=input
elif [[ -n "${VAR_AUTH:-}" ]]; then
	auth_source=var
fi
credential_env="$(ai_review_credential_env "$provider" "$transport" "$auth")"
if [[ -z "$credential_env" ]]; then
	echo "::error::Unsupported review tuple '${provider:-<empty>}/${transport:-<empty>}/${auth:-<empty>}'. Supported choices: $(ai_review_supported_choices)" >&2
	exit 1
fi
cli_binary="$(ai_review_cli_binary "$provider" "$transport" "$auth")"
needs_cli=false
[[ -z "$cli_binary" ]] || needs_cli=true
resolved=true

# Every component that changes egress must be visible before checkout.
if [[ "${EGRESS_POLICY:-}" == block ]]; then
	visible_provider="${PROVIDER_INPUT:-${VAR_PROVIDER:-}}"
	visible_transport="${TRANSPORT_INPUT:-${VAR_TRANSPORT:-}}"
	visible_auth="${AUTH_INPUT:-${VAR_AUTH:-$(ai_review_default_auth "$visible_provider" "$visible_transport")}}"
	if [[ "$provider/$transport/$auth" != "$visible_provider/$visible_transport/$visible_auth" ]]; then
		echo "::error::harden-runner cannot see the config-only tuple '$provider/$transport/$auth'. Set LINTRO_AI_PROVIDER and LINTRO_AI_TRANSPORT Actions variables or workflow inputs before using block egress." >&2
		exit 1
	fi
fi
model="${MODEL_INPUT:-${VAR_MODEL:-$(_ai_review_config_field model "$config_path")}}"
model_source=default
if [[ -n "${MODEL_INPUT:-}" ]]; then
	model_source=input
elif [[ -n "${VAR_MODEL:-}" ]]; then
	model_source=var
elif [[ -n "$model" ]]; then
	model_source=config
fi
max_cost="${MAX_COST_INPUT:-${VAR_MAX_COST:-$(_ai_review_config_field max_cost_usd "$config_path")}}"
set_github_output auth "$auth"
set_github_output auth-source "$auth_source"
set_github_output cli-bare "$(ai_review_matrix_field "$provider" "$transport" "$auth" 7)"
set_github_output model "$model"
set_github_output model-source "$model_source"
set_github_output max-cost-usd "$max_cost"
set_github_output "provider" "$provider"
set_github_output "transport" "$transport"
set_github_output "credential-env" "$credential_env"
set_github_output "needs-cli" "$needs_cli"
set_github_output "cli-binary" "$cli_binary"
set_github_output "resolved" "$resolved"

summary="ai-review resolve: requested=${PROVIDER_INPUT:-${VAR_PROVIDER:-<config>}}/${TRANSPORT_INPUT:-${VAR_TRANSPORT:-<config>}}/${AUTH_INPUT:-${VAR_AUTH:-<default>}} resolved=$provider/$transport/$auth auth-source=$auth_source model=${model:-<CLI/provider default>} model-source=$model_source credential=$credential_env purpose=review"
echo "$summary"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$summary" >>"$GITHUB_STEP_SUMMARY"; fi
