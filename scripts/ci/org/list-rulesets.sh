#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: List org rulesets as a compact discovery table (read-only)
#
# Usage:
#   list-rulesets.sh [-q]
#
# Options:
#   -q  Quiet: print the table only (no informational log lines)
#
# Environment variables:
#   LGTM_ORG - GitHub organization (default: lgtm-hq)
#
# Requires org-admin `gh` auth. Prints a table of ruleset id, name,
# enforcement level, and target repositories to stdout. Use this as
# the discovery step before export → edit → sync (see docs/org-rulesets.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"

QUIET="false"
while [[ $# -gt 0 ]]; do
	case "$1" in
	-q | --quiet)
		QUIET="true"
		shift
		;;
	-h | --help)
		echo "Usage: $(basename "$0") [-q]" >&2
		exit 0
		;;
	*)
		log_error "Unknown argument: $1"
		echo "Usage: $(basename "$0") [-q]" >&2
		exit 2
		;;
	esac
done

for tool in gh jq column; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		log_error "Required tool not found: ${tool}"
		exit 1
	fi
done

LGTM_ORG="${LGTM_ORG:-lgtm-hq}"
readonly ENDPOINT="orgs/${LGTM_ORG}/rulesets"

if [[ "$QUIET" != "true" ]]; then
	log_info "Fetching rulesets for ${LGTM_ORG}"
fi

if ! payload="$(gh api --paginate "${ENDPOINT}?per_page=100" | jq -s 'add // []')"; then
	log_error "Failed to fetch ${ENDPOINT} (check gh auth and org permissions)"
	exit 1
fi

if ! jq -e 'type == "array"' <<<"$payload" >/dev/null 2>&1; then
	log_error "Unexpected response: expected a JSON array"
	exit 1
fi

count="$(jq 'length' <<<"$payload")"
if [[ "$count" -eq 0 ]]; then
	if [[ "$QUIET" != "true" ]]; then
		log_info "No rulesets found for ${LGTM_ORG}"
	fi
	exit 0
fi

jq -r '
  ["ID","NAME","ENFORCEMENT","REPOS"],
  ["--","----","-----------","-----"],
  (.[] |
    [
      (.id | tostring),
      .name,
      .enforcement,
      ((.conditions.repository_name.include // []) | join(", "))
    ]
  )
  | @tsv
' <<<"$payload" | column -t -s $'\t'

if [[ "$QUIET" != "true" ]]; then
	log_info "${count} ruleset(s) found"
fi
