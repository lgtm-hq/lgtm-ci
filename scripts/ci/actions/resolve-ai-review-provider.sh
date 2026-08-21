#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve the (provider, transport) pair for reusable-ai-review.yml.
#
# Resolution order (no baked-in default):
#   input env → Actions variable env → consuming repo .lintro-config.yaml
# If nothing resolves, outputs stay empty and `resolved=false`. The workflow
# still maps inputs onto LINTRO_AI_* and lets lintro fail with its own
# guidance — this script only gates binary install, credential injection, and
# extra egress.
#
# Environment:
#   PROVIDER_INPUT     workflow `provider` input (may be empty)
#   TRANSPORT_INPUT    workflow `transport` input (may be empty)
#   VAR_PROVIDER       vars.LINTRO_AI_PROVIDER (may be empty)
#   VAR_TRANSPORT      vars.LINTRO_AI_TRANSPORT (may be empty)
#   CONFIG_PATH        lintro config to read (default: .lintro-config.yaml)
#   GITHUB_OUTPUT      Actions output file (optional; always prints a summary)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/github/output.sh
source "${SCRIPT_DIR}/../lib/github/output.sh"
# shellcheck source=../lib/ai_review_matrix.sh
source "${SCRIPT_DIR}/../lib/ai_review_matrix.sh"
# shellcheck source=../lib/egress/presets.sh
source "${SCRIPT_DIR}/../lib/egress/presets.sh"

# Read ai.provider / ai.transport from a lintro YAML config without PyYAML.
# Only the top-level `ai:` mapping is considered; nested mappings stop the scan.
_ai_review_config_field() {
	local field="$1"
	local path="$2"
	local in_ai=false
	local line value

	[[ -f "$path" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" =~ ^ai:[[:space:]]*$ ]]; then
			in_ai=true
			continue
		fi
		if [[ "$in_ai" == true && "$line" =~ ^[^[:space:]#] ]]; then
			break
		fi
		if [[ "$in_ai" != true ]]; then
			continue
		fi
		stripped="${line#"${line%%[![:space:]]*}"}"
		if [[ "$stripped" != "${field}:"* ]]; then
			continue
		fi
		value="${stripped#"${field}:"}"
		value="${value#"${value%%[![:space:]]*}"}"
		value="${value%%#*}"
		value="${value%"${value##*[![:space:]]}"}"
		value="${value%\"}"
		value="${value#\"}"
		value="${value%\'}"
		value="${value#\'}"
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

extra_endpoints="$(egress_ai_review_provider_endpoints "$provider" "$transport" | paste -sd' ' - || true)"

resolved="false"
if [[ -n "$provider" ]]; then
	resolved="true"
fi

set_github_output "provider" "$provider"
set_github_output "transport" "$transport"
set_github_output "credential-env" "$credential_env"
set_github_output "needs-cli" "$needs_cli"
set_github_output "cli-binary" "$cli_binary"
set_github_output "extra-endpoints" "$extra_endpoints"
set_github_output "resolved" "$resolved"

echo "ai-review resolve: provider=${provider:-<unset>} transport=${transport:-<unset>} credential=${credential_env:-<none>} needs-cli=${needs_cli}"
if [[ "$resolved" != "true" ]]; then
	echo "ai-review resolve: provider unset. Set the workflow provider input, the LINTRO_AI_PROVIDER Actions variable, or ai.provider in the repo lintro config."
fi
