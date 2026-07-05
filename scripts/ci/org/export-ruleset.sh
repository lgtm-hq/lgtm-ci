#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Export a live org ruleset via the GitHub API (read-only)
#
# Usage:
#   export-ruleset.sh <name> <id> [-o <file>]
#
# Arguments:
#   name - Expected ruleset name (safety check against the fetched payload)
#   id   - Numeric GitHub ruleset id (see docs/org-rulesets.md)
#
# Options:
#   -o <file> - Write JSON to <file> instead of stdout (for local edits only)
#
# Environment variables:
#   LGTM_ORG - GitHub organization (default: lgtm-hq)
#
# Requires org-admin `gh` auth. Prints the ruleset JSON to stdout by
# default. Never commit exported JSON to the repository — GitHub is the
# source of truth for full ruleset payloads (see docs/org-rulesets.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"

usage() {
	echo "Usage: $(basename "$0") <name> <id> [-o <file>]" >&2
}

if [[ $# -lt 2 ]]; then
	usage
	exit 2
fi

RULESET_NAME="$1"
RULESET_ID="$2"
shift 2

OUTPUT_FILE=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	-o)
		if [[ $# -lt 2 ]]; then
			log_error "-o requires a file argument"
			exit 2
		fi
		OUTPUT_FILE="$2"
		shift 2
		;;
	*)
		log_error "Unknown argument: $1"
		usage
		exit 2
		;;
	esac
done

if [[ ! "$RULESET_ID" =~ ^[0-9]+$ ]]; then
	log_error "Ruleset id must be numeric, got: ${RULESET_ID}"
	exit 2
fi

for tool in gh jq; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		log_error "Required tool not found: ${tool}"
		exit 1
	fi
done

LGTM_ORG="${LGTM_ORG:-lgtm-hq}"
readonly ENDPOINT="orgs/${LGTM_ORG}/rulesets/${RULESET_ID}"

log_info "Fetching ruleset ${RULESET_ID} from ${LGTM_ORG} (read-only)"

if ! payload="$(gh api "$ENDPOINT")"; then
	log_error "Failed to fetch ${ENDPOINT} (check gh auth and ruleset id)"
	exit 1
fi

fetched_name="$(jq -r '.name // empty' <<<"$payload")"
if [[ "$fetched_name" != "$RULESET_NAME" ]]; then
	log_error "Ruleset name mismatch: expected '${RULESET_NAME}', got '${fetched_name}'"
	exit 1
fi

if [[ -n "$OUTPUT_FILE" ]]; then
	jq '.' <<<"$payload" >"$OUTPUT_FILE"
	log_success "Wrote ruleset '${RULESET_NAME}' to ${OUTPUT_FILE} (do not commit)"
else
	jq '.' <<<"$payload"
fi
