#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# check-vuln-suppressions.sh — Detect stale or expired vulnerability
# suppressions in .osv-scanner.toml and open a cleanup PR removing them.
#
# Usage:
#   check-vuln-suppressions.sh
#
# Environment:
#   GH_TOKEN     - GitHub token for PR creation (required)
#   CONFIG_PATH  - Suppression TOML path (default: .osv-scanner.toml)
#   WORKFLOW_FILE - Caller workflow filename for PR footer link (optional)

set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	cat <<'EOF'
Usage: check-vuln-suppressions.sh

Detect stale or expired vulnerability suppressions in .osv-scanner.toml.

Runs osv-scanner recursively without suppressions to scan all
supported lockfiles and see which suppressed vulnerabilities are still
present. Opens a PR removing entries that are stale (vuln resolved).

Requires GH_TOKEN for PR management.
EOF
	exit 0
fi

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$SCRIPTS_DIR/../../../.." && pwd)}"
LIB_DIR="$SCRIPTS_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github/output.sh
source "$LIB_DIR/github/output.sh"

cd "$REPO_ROOT"

OSV_TOML="${CONFIG_PATH:-.osv-scanner.toml}"

if [[ ! -f "$OSV_TOML" ]]; then
	log_success "No $OSV_TOML found. Nothing to check."
	exit 0
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
	log_error "GH_TOKEN is required"
	exit 1
fi

log_info "Probing osv-scanner without suppressions..."
PROBE_EXIT=0
PROBE_OUTPUT=$(
	osv-scanner scan --recursive --format json --config /dev/null \
		.
) || PROBE_EXIT=$?

if [[ "$PROBE_EXIT" -gt 1 ]]; then
	log_error "osv-scanner failed with exit code $PROBE_EXIT"
	echo "$PROBE_OUTPUT" >&2
	exit "$PROBE_EXIT"
fi

log_info "Classifying suppressions..."
export CONFIG_PATH="$OSV_TOML"
CLASSIFICATION_JSON=$(echo "$PROBE_OUTPUT" | python3 "$SCRIPTS_DIR/classify-suppressions.py")

STALE_IDS=()
EXPIRED_IDS=()
ACTIVE_IDS=()
while IFS= read -r line; do
	category="${line%%:*}"
	vid="${line#*:}"
	case "$category" in
	STALE) STALE_IDS+=("$vid") ;;
	EXPIRED) EXPIRED_IDS+=("$vid") ;;
	ACTIVE) ACTIVE_IDS+=("$vid") ;;
	esac
done < <(echo "$CLASSIFICATION_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for k in ('stale', 'expired', 'active'):
    for i in d.get(k, []):
        print(f'{k.upper()}:{i}')
")

REMOVE_IDS=("${STALE_IDS[@]+"${STALE_IDS[@]}"}")

for id in "${ACTIVE_IDS[@]+"${ACTIVE_IDS[@]}"}"; do
	log_success "Active: $id"
done
for id in "${STALE_IDS[@]+"${STALE_IDS[@]}"}"; do
	log_warning "Stale: $id"
done
for id in "${EXPIRED_IDS[@]+"${EXPIRED_IDS[@]}"}"; do
	log_warning "Expired: $id"
done

if [[ ${#REMOVE_IDS[@]} -eq 0 && ${#EXPIRED_IDS[@]} -eq 0 ]]; then
	log_success "All suppressions are active. Nothing to do."
	exit 0
fi

PR_LIST_OUTPUT=""
PR_LIST_EXIT=0
PR_LIST_OUTPUT=$(
	gh pr list --state open \
		--search "chore(security): remove stale vulnerability" \
		--json number --jq '.[0].number // empty' 2>&1
) || PR_LIST_EXIT=$?
if [[ "$PR_LIST_EXIT" -ne 0 ]]; then
	log_error "gh pr list failed: $PR_LIST_OUTPUT"
	exit 1
fi
if [[ -n "$PR_LIST_OUTPUT" ]]; then
	log_info "Cleanup PR #${PR_LIST_OUTPUT} already open. Skipping."
	exit 0
fi

if [[ ${#REMOVE_IDS[@]} -eq 0 ]]; then
	log_info "No stale suppressions to remove."
else
	export REMOVE_IDS_JSON
	REMOVE_IDS_JSON=$(printf '%s\n' "${REMOVE_IDS[@]}" | python3 -c "
import json, sys
print(json.dumps([line.strip() for line in sys.stdin if line.strip()]))
")

	python3 "$SCRIPTS_DIR/remove_stale_suppressions.py" "$OSV_TOML"

	if [[ -f "$OSV_TOML" ]]; then
		if ! grep -qE '^\[' "$OSV_TOML"; then
			log_info "No entries left in $OSV_TOML, removing file"
			rm -f "$OSV_TOML"
		fi
	fi

	if ! git diff --quiet; then
		REMOVED_LIST=""
		for id in "${REMOVE_IDS[@]+"${REMOVE_IDS[@]}"}"; do
			REMOVED_LIST="${REMOVED_LIST}- \`${id}\`
"
		done

		EXPIRED_LIST=""
		for id in "${EXPIRED_IDS[@]+"${EXPIRED_IDS[@]}"}"; do
			EXPIRED_LIST="${EXPIRED_LIST}- \`${id}\`
"
		done

		BRANCH="chore/remove-stale-vulns-$(date +%Y%m%d%H%M%S)"
		configure_git_ci_user
		git checkout -b "$BRANCH"
		git add -A -- "$OSV_TOML"
		git commit -m "$(
			cat <<EOF
chore(security): remove stale vulnerability suppressions

The following suppressions are no longer needed:
${REMOVED_LIST}
Detected by the weekly vuln-suppression-check workflow.
EOF
		)"

		git push -u origin "$BRANCH"

		WF_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions"
		if [[ -n "${WORKFLOW_FILE:-}" ]]; then
			WF_URL="${WF_URL}/workflows/${WORKFLOW_FILE}"
		fi

		gh pr create \
			--title "chore(security): remove stale vulnerability suppressions" \
			--body "$(
				cat <<EOF
## Summary
- Remove stale vulnerability suppressions (vuln resolved upstream)
${REMOVED_LIST:+
### Removed (stale)
${REMOVED_LIST}}${EXPIRED_LIST:+
### ⚠️ Expired (needs manual review)
The following suppressions have passed their ignoreUntil date but
the vulnerability may still be present. Renew or fix:
${EXPIRED_LIST}}
## Test plan
- [ ] CI security audit passes without these suppressions
- [ ] osv-scanner scan passes without these suppressions

---
*Auto-created by [vuln-suppression-check](${WF_URL}).*
EOF
			)"

		log_success "Cleanup PR created on branch $BRANCH"
	else
		log_info "No file changes needed."
	fi
fi

if [[ ${#EXPIRED_IDS[@]} -gt 0 ]]; then
	log_error "Expired suppressions need manual review — renew or fix:"
	for id in "${EXPIRED_IDS[@]}"; do
		log_error "  $id"
	done
	exit 1
fi
