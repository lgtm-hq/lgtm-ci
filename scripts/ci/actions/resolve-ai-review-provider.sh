#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve the (provider, transport) pair for reusable-ai-review.yml.
#
# Resolution order (no baked-in default):
#   input env → Actions variable env → consuming repo .lintro-config.yaml
# If nothing resolves, outputs stay empty and `resolved=false`. The workflow
# still maps inputs onto LINTRO_AI_* and lets lintro fail with its own
# guidance — this script only gates binary install and credential injection,
# and guards egress visibility (below).
#
# Egress visibility guard: harden-runner hardens as the FIRST job step, before
# any checkout, so only the input/var pair can reach its allowlist. A provider
# resolved solely from the repo config is therefore never allowlisted; under
# egress-policy "block" the review would die net-blocked mid-call. That is a
# caller misconfiguration, not a review outcome — this script fails loudly
# (mirroring the unconditional App-credential guard) instead of letting a
# doomed provider call burn spend and report "no review".
#
# Environment:
#   PROVIDER_INPUT     workflow `provider` input (may be empty)
#   TRANSPORT_INPUT    workflow `transport` input (may be empty)
#   VAR_PROVIDER       vars.LINTRO_AI_PROVIDER (may be empty)
#   VAR_TRANSPORT      vars.LINTRO_AI_TRANSPORT (may be empty)
#   EGRESS_POLICY      harden-runner egress policy; the guard fires on "block"
#   CONFIG_PATH        lintro config to read (default: .lintro-config.yaml)
#   GITHUB_OUTPUT      Actions output file (optional; always prints a summary)

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
		key="$(_ai_review_trim "${pair%%:*}")"
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
		if [[ "$line" =~ ^ai:[[:space:]]*(.*)$ ]]; then
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
		if [[ "$stripped" != "${field}:"* ]]; then
			continue
		fi
		value="$(_ai_review_unquote "${stripped#"${field}:"}")"
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

credential_env="$(ai_review_credential_env "$provider" "$transport")"
cli_binary="$(ai_review_cli_binary "$provider" "$transport")"
needs_cli="false"
if [[ -n "$cli_binary" ]]; then
	needs_cli="true"
fi

resolved="false"
if [[ -n "$provider" && -n "$credential_env" ]]; then
	resolved="true"
fi

# Egress visibility guard (see header). Fires only when the workflow says the
# runner egress is blocked AND the provider came solely from the repo config.
if [[ "$resolved" == "true" && "${EGRESS_POLICY:-}" == "block" ]]; then
	visible_provider="$(first_nonempty "${PROVIDER_INPUT:-}" "${VAR_PROVIDER:-}")"
	if [[ -z "$visible_provider" ]]; then
		echo "::error::ai-review resolve: provider '${provider}' comes only from ${config_path}, which harden-runner cannot see (it hardens before any checkout). Under egress-policy 'block' the provider hosts were not allowlisted, so the review cannot reach ${provider}. Set the LINTRO_AI_PROVIDER Actions variable or the workflow provider input; egress-policy 'audit' also lifts this."
		exit 1
	fi
fi

set_github_output "provider" "$provider"
set_github_output "transport" "$transport"
set_github_output "credential-env" "$credential_env"
set_github_output "needs-cli" "$needs_cli"
set_github_output "cli-binary" "$cli_binary"
set_github_output "resolved" "$resolved"

echo "ai-review resolve: provider=${provider:-<unset>} transport=${transport:-<unset>} credential=${credential_env:-<none>} needs-cli=${needs_cli}"
if [[ "$resolved" != "true" ]]; then
	if [[ -n "$provider" ]]; then
		echo "ai-review resolve: unsupported pair provider=${provider} transport=${transport:-<unset>}. Supported pairs: anthropic/api, anthropic/cli, cursor/cli, openai/api, openai/cli."
	else
		echo "ai-review resolve: provider unset. Set the workflow provider input, the LINTRO_AI_PROVIDER Actions variable, or ai.provider in the repo lintro config."
	fi
fi
