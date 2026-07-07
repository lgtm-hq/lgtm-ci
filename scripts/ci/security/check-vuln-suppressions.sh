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
#   GH_TOKEN           - GitHub token for PR creation (required)
#   CONFIG_PATH        - Suppression TOML path (default: .osv-scanner.toml)
#   WORKFLOW_FILE      - Caller workflow filename for PR footer link (optional)
#   CLEANUP_PR_LABELS  - Comma-separated PR labels (default when unset: security,dependencies,automation; empty opts out)

set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	cat <<'EOF'
Usage: check-vuln-suppressions.sh

Detect stale or expired vulnerability suppressions in .osv-scanner.toml.

Runs osv-scanner recursively without suppressions to scan all
supported lockfiles and see which suppressed vulnerabilities are still
present. Opens a PR removing entries that are stale (vuln resolved) or
expired (past ignoreUntil).

Requires GH_TOKEN for PR management.
EOF
	exit 0
fi

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$SCRIPTS_DIR/../../.." && pwd)}"
LIB_DIR="$SCRIPTS_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github/output.sh
source "$LIB_DIR/github/output.sh"

cd "$REPO_ROOT"

OSV_TOML="${CONFIG_PATH:-.osv-scanner.toml}"
# Default labels only when unset; explicit "" opts out of labeling.
CLEANUP_PR_LABELS="${CLEANUP_PR_LABELS-security,dependencies,automation}"

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

REMOVE_IDS=("${STALE_IDS[@]+"${STALE_IDS[@]}"}" "${EXPIRED_IDS[@]+"${EXPIRED_IDS[@]}"}")

for id in "${ACTIVE_IDS[@]+"${ACTIVE_IDS[@]}"}"; do
	log_success "Active: $id"
done
for id in "${STALE_IDS[@]+"${STALE_IDS[@]}"}"; do
	log_warning "Stale: $id"
done
for id in "${EXPIRED_IDS[@]+"${EXPIRED_IDS[@]}"}"; do
	log_warning "Expired: $id"
done

if [[ ${#REMOVE_IDS[@]} -eq 0 ]]; then
	log_success "All suppressions are active. Nothing to do."
	exit 0
fi

# Check for an existing cleanup PR. If one exists and the current run found
# new expired suppressions, fail instead of silently masking them.
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
	if [[ ${#EXPIRED_IDS[@]} -gt 0 ]]; then
		log_error "Cleanup PR #${PR_LIST_OUTPUT} already open, but new expired suppressions found. Manual review required."
		exit 1
	fi
	log_info "Cleanup PR #${PR_LIST_OUTPUT} already open. Skipping."
	exit 0
fi

export REMOVE_IDS_JSON
REMOVE_IDS_JSON=$(printf '%s\n' "${REMOVE_IDS[@]}" | python3 -c "
import json, sys
print(json.dumps([line.strip() for line in sys.stdin if line.strip()]))
")

python3 "$SCRIPTS_DIR/remove_stale_suppressions.py" "$OSV_TOML"

if [[ -f "$OSV_TOML" ]]; then
	if ! grep -qEv '^[[:space:]]*(#.*)?$' "$OSV_TOML"; then
		log_info "No substantive content left in $OSV_TOML, removing file"
		rm -f "$OSV_TOML"
	fi
fi

if ! git diff --quiet; then
	STALE_LIST=""
	for id in "${STALE_IDS[@]+"${STALE_IDS[@]}"}"; do
		STALE_LIST="${STALE_LIST}- \`${id}\` (stale — vulnerability resolved)
"
	done
	EXPIRED_LIST=""
	for id in "${EXPIRED_IDS[@]+"${EXPIRED_IDS[@]}"}"; do
		EXPIRED_LIST="${EXPIRED_LIST}- \`${id}\` (expired — past ignoreUntil date)
"
	done
	REMOVED_LIST="${STALE_LIST}${EXPIRED_LIST}"

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

	PR_BODY="## Summary
- Remove stale/expired vulnerability suppressions that are no longer needed
"
	if [[ -n "$STALE_LIST" ]]; then
		PR_BODY="${PR_BODY}
### Removed (stale)
${STALE_LIST}"
	fi
	if [[ -n "$EXPIRED_LIST" ]]; then
		PR_BODY="${PR_BODY}
### Removed (expired)
${EXPIRED_LIST}"
	fi
	PR_BODY="${PR_BODY}
## Test plan
- [ ] CI security audit passes without these suppressions
- [ ] osv-scanner scan passes without these suppressions

---
*Auto-created by [vuln-suppression-check](${WF_URL}).*"

	gh_pr_label_args=()
	if [[ -n "${CLEANUP_PR_LABELS}" ]]; then
		IFS=',' read -ra _cleanup_labels <<<"${CLEANUP_PR_LABELS}"
		for label in "${_cleanup_labels[@]}"; do
			label="${label#"${label%%[![:space:]]*}"}"
			label="${label%"${label##*[![:space:]]}"}"
			[[ -n "$label" ]] && gh_pr_label_args+=(--label "$label")
		done
	fi

	if ((${#gh_pr_label_args[@]} > 0)); then
		gh pr create \
			--title "chore(security): remove stale vulnerability suppressions" \
			"${gh_pr_label_args[@]}" \
			--body "$PR_BODY"
	else
		gh pr create \
			--title "chore(security): remove stale vulnerability suppressions" \
			--body "$PR_BODY"
	fi

	log_success "Cleanup PR created on branch $BRANCH"

	# Expired suppressions may indicate still-active vulnerabilities
	# past their ignoreUntil date. Fail the workflow so the team
	# reviews the PR before the next scan.
	if [[ ${#EXPIRED_IDS[@]} -gt 0 ]]; then
		log_error "Expired suppression(s) removed; review the cleanup PR before merging"
		exit 1
	fi
else
	log_info "No file changes needed."
fi
