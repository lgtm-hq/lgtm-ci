#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Sync an operator-edited org ruleset payload back to GitHub
#
# Usage:
#   sync-ruleset.sh [--apply] [--id <ruleset-id>] <path-to-local-json | ->
#
# Arguments:
#   path-to-local-json - Local JSON file with the ruleset payload, or `-`
#                        to read from stdin (operator workflow:
#                        export-ruleset.sh → edit → sync-ruleset.sh)
#
# Options:
#   --apply          - Actually PUT the payload to GitHub. Without this
#                      flag the script is a dry run: it validates the
#                      payload, strips read-only fields, and prints the
#                      sanitized payload without contacting GitHub.
#   --id <id>        - Numeric ruleset id; defaults to `.id` (or
#                      `.ruleset_id`) from the payload
#
# Environment variables:
#   LGTM_ORG - GitHub organization (default: lgtm-hq)
#
# Requires org-admin `gh` auth for --apply. Payloads are operator-supplied
# local files; never commit ruleset JSON to the repository — GitHub is the
# source of truth (see docs/org-rulesets.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"

# JSON fields returned by GET that the PUT endpoint does not accept.
readonly READONLY_FIELDS_FILTER='del(
	.id, .ruleset_id, .node_id, .source, .source_type,
	.created_at, .updated_at, ._links, .current_user_can_bypass
)'

usage() {
	echo "Usage: $(basename "$0") [--apply] [--id <ruleset-id>] <path-to-local-json | ->" >&2
}

APPLY="false"
RULESET_ID=""
INPUT_PATH=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--apply)
		APPLY="true"
		shift
		;;
	--id)
		if [[ $# -lt 2 ]]; then
			log_error "--id requires an argument"
			exit 2
		fi
		RULESET_ID="$2"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		if [[ -n "$INPUT_PATH" ]]; then
			log_error "Unexpected argument: $1"
			usage
			exit 2
		fi
		INPUT_PATH="$1"
		shift
		;;
	esac
done

if [[ -z "$INPUT_PATH" ]]; then
	usage
	exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
	log_error "Required tool not found: jq"
	exit 1
fi

if [[ "$INPUT_PATH" == "-" ]]; then
	payload="$(cat)"
else
	if [[ ! -f "$INPUT_PATH" ]]; then
		log_error "Payload file not found: ${INPUT_PATH}"
		exit 1
	fi
	payload="$(cat "$INPUT_PATH")"
fi

if ! jq -e 'type == "object"' <<<"$payload" >/dev/null 2>&1; then
	log_error "Payload is not a valid JSON object"
	exit 1
fi

if [[ -z "$RULESET_ID" ]]; then
	RULESET_ID="$(jq -r '.id // .ruleset_id // empty' <<<"$payload")"
fi

if [[ ! "$RULESET_ID" =~ ^[0-9]+$ ]]; then
	log_error "Could not resolve a numeric ruleset id (pass --id or include .id in the payload)"
	exit 2
fi

sanitized="$(jq "$READONLY_FIELDS_FILTER" <<<"$payload")"

LGTM_ORG="${LGTM_ORG:-lgtm-hq}"
readonly ENDPOINT="orgs/${LGTM_ORG}/rulesets/${RULESET_ID}"

if [[ "$APPLY" != "true" ]]; then
	log_info "Dry run: would PUT the following payload to ${ENDPOINT}"
	log_info "Re-run with --apply to update the live ruleset"
	printf '%s\n' "$sanitized"
	exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
	log_error "Required tool not found: gh"
	exit 1
fi

# Identity check: refuse to overwrite a ruleset whose live name does not
# match the payload (guards against a wrong --id or stale LGTM_ORG).
payload_name="$(jq -r '.name // empty' <<<"$sanitized")"
if [[ -z "$payload_name" ]]; then
	log_error "Payload has no .name; cannot verify ruleset identity"
	exit 1
fi
if ! live_name="$(gh api "$ENDPOINT" --jq '.name')"; then
	log_error "Failed to fetch live ruleset ${ENDPOINT} for identity check"
	exit 1
fi
if [[ "$live_name" != "$payload_name" ]]; then
	log_error "Ruleset identity mismatch: live ruleset ${RULESET_ID} is named '${live_name}' but payload is '${payload_name}' (check --id and LGTM_ORG)"
	exit 1
fi

log_info "Applying ruleset payload to ${ENDPOINT}"
if ! gh api --method PUT "$ENDPOINT" --input - <<<"$sanitized" >/dev/null; then
	log_error "Failed to update ${ENDPOINT}"
	exit 1
fi

log_success "Updated ruleset ${RULESET_ID} in ${LGTM_ORG}"
