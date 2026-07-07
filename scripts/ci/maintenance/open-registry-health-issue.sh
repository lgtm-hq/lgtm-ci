#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Open a GitHub issue when registry health check fails
#
# Required environment variables:
#   GH_TOKEN - GitHub token with issues: write
#   GITHUB_REPOSITORY - Target repository (owner/name)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"

if [[ -z "${GH_TOKEN:-}" ]]; then
	log_error "GH_TOKEN is required"
	exit 1
fi

if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
	log_error "GITHUB_REPOSITORY is required"
	exit 1
fi

readonly DEDUP_LABEL="registry-health-check"
readonly GH_REPO="${GITHUB_REPOSITORY}"

title="Registry health check: unreachable container image digest(s)"
body="$(
	cat <<EOF
The scheduled registry health check found digest-pinned container images that no longer resolve.

Workflow run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-unknown}

## Next steps

1. Inspect the workflow logs for the failing image reference(s).
2. Update the digest pin to a current manifest in the affected workflow or action file.
3. Re-run the registry health check workflow to confirm recovery.
EOF
)"

ensure_issue_label() {
	local label="$1"
	local color="$2"
	local description="${3:-}"

	if gh label view "$label" --repo "$GH_REPO" >/dev/null 2>&1; then
		return 0
	fi

	if [[ -n "$description" ]]; then
		gh label create "$label" \
			--repo "$GH_REPO" \
			--color "$color" \
			--description "$description" 2>/dev/null || true
	else
		gh label create "$label" \
			--repo "$GH_REPO" \
			--color "$color" 2>/dev/null || true
	fi

	if gh label view "$label" --repo "$GH_REPO" >/dev/null 2>&1; then
		return 0
	fi

	log_error "Failed to ensure issue label exists: $label"
	exit 1
}

existing_count="$(gh issue list \
	--repo "$GH_REPO" \
	--label "$DEDUP_LABEL" \
	--state open \
	--json number \
	--jq 'length' 2>/dev/null || true)"

if [[ ! "$existing_count" =~ ^[0-9]+$ ]]; then
	log_error "Could not check for existing registry health issues"
	exit 1
fi

if [[ "$existing_count" -gt 0 ]]; then
	log_info "Open registry health issue already exists; skipping duplicate creation"
	exit 0
fi

ensure_issue_label "$DEDUP_LABEL" "1D76DB" "Auto-opened by the registry health check workflow"

label_args=(--label "$DEDUP_LABEL")
if [[ -n "${ISSUE_LABELS:-}" ]]; then
	IFS=',' read -ra labels <<<"$ISSUE_LABELS"
	for label in "${labels[@]}"; do
		label="$(echo "$label" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		if [[ -z "$label" || "$label" == "$DEDUP_LABEL" ]]; then
			continue
		fi
		ensure_issue_label "$label" "ededed" ""
		label_args+=(--label "$label")
	done
fi

gh issue create \
	--repo "$GH_REPO" \
	--title "$title" \
	--body "$body" \
	"${label_args[@]}"

log_success "Opened registry health issue"
