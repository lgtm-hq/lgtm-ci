#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# check-vuln-suppressions.sh — Detect stale or expired vulnerability
# suppressions in .osv-scanner.toml. Stale entries (vulnerability resolved)
# are auto-removed via a cleanup PR; expired entries (past ignoreUntil) are
# left untouched and flagged for manual review with a non-zero exit.
#
# The cleanup commit is created through the GitHub API
# (scripts/ci/git/create-signed-commit.sh, reset mode on the default branch
# head), so GitHub signs it and it merges where required_signatures is
# enforced. Nothing is committed or pushed with the git CLI. Labels are added
# after the PR exists and failures only warn; if the PR cannot be created the
# new branch is deleted and the script exits non-zero.
#
# Usage:
#   check-vuln-suppressions.sh
#
# Environment:
#   GH_TOKEN           - GitHub token with contents:write and pull-requests:write (required)
#   GITHUB_REPOSITORY  - Target repository (owner/repo); required to open a cleanup PR
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
present. Opens a PR removing entries that are stale (vuln resolved),
committed through the GitHub API so the commit is signed by GitHub.
Labels are added best-effort after the PR is created.
Expired entries (past ignoreUntil) are left untouched and flagged for
manual review, causing a non-zero exit.

Requires GH_TOKEN (contents:write, pull-requests:write) and
GITHUB_REPOSITORY for the cleanup commit and PR.
EOF
	exit 0
fi

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$SCRIPTS_DIR/../../.." && pwd)}"
LIB_DIR="$SCRIPTS_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"

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
declare -A EXPIRED_UNTIL=()
while IFS=$'\t' read -r category vid expire_date; do
	case "$category" in
	STALE) STALE_IDS+=("$vid") ;;
	EXPIRED)
		EXPIRED_IDS+=("$vid")
		EXPIRED_UNTIL["$vid"]="$expire_date"
		;;
	ACTIVE) ACTIVE_IDS+=("$vid") ;;
	esac
done < <(echo "$CLASSIFICATION_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
details = d.get('expired_until', {})
for i in d.get('stale', []):
    print(f'STALE\t{i}\t')
for i in d.get('active', []):
    print(f'ACTIVE\t{i}\t')
for i in d.get('expired', []):
    print(f'EXPIRED\t{i}\t{details.get(i, \"\")}')
")

# Only stale suppressions are auto-removed. Expired entries are left untouched
# and flagged for manual review (see issue #377): expiry means the timebox
# lapsed and a human must re-evaluate, not that the vulnerability is gone.
REMOVE_IDS=("${STALE_IDS[@]+"${STALE_IDS[@]}"}")

for id in "${ACTIVE_IDS[@]+"${ACTIVE_IDS[@]}"}"; do
	log_success "Active: $id"
done
for id in "${STALE_IDS[@]+"${STALE_IDS[@]}"}"; do
	log_warning "Stale: $id"
done

# Emit expired suppressions to the log and job summary. Callers exit non-zero
# after invoking this so expired entries are surfaced as a failing check.
flag_expired_suppressions() {
	log_error "Expired suppression(s) require manual review (left untouched in $OSV_TOML):"
	local summary
	summary="## Expired vulnerability suppressions require manual review

The following suppressions in \`${OSV_TOML}\` are past their \`ignoreUntil\` date
and were **left untouched**. Expiry means the timebox lapsed, not that the
vulnerability is resolved. Re-evaluate each entry and either remediate the
vulnerability or renew the suppression with a new \`ignoreUntil\`.

| ID | ignoreUntil | Required action |
| --- | --- | --- |
"
	local id expire_date
	for id in "${EXPIRED_IDS[@]+"${EXPIRED_IDS[@]}"}"; do
		expire_date="${EXPIRED_UNTIL[$id]:-unknown}"
		log_error "  - ${id} (ignoreUntil ${expire_date}) — remediate the vulnerability or renew the suppression"
		summary="${summary}| \`${id}\` | ${expire_date} | Remediate the vulnerability or renew the suppression |
"
	done
	if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
		printf '%s\n' "$summary" >>"$GITHUB_STEP_SUMMARY"
	fi
}

if [[ ${#REMOVE_IDS[@]} -eq 0 ]]; then
	if [[ ${#EXPIRED_IDS[@]} -gt 0 ]]; then
		flag_expired_suppressions
		exit 1
	fi
	log_success "All suppressions are active. Nothing to do."
	exit 0
fi

# Check for an existing cleanup PR. Stale removal for one is already pending,
# so skip re-opening it, but still flag any expired entries for manual review.
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
	log_info "Cleanup PR #${PR_LIST_OUTPUT} already open. Skipping stale removal."
	if [[ ${#EXPIRED_IDS[@]} -gt 0 ]]; then
		flag_expired_suppressions
		exit 1
	fi
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

# Record the branch name and, while the branch still exists, a compare URL in
# the job summary so a failed cleanup never leaves an untracked branch behind.
write_cleanup_failure_summary() {
	local reason="$1"
	local branch_state="$2"
	[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
	{
		printf '## Stale vulnerability suppression cleanup failed\n\n'
		printf '%s\n\n' "$reason"
		printf -- "- Branch: \`%s\` (%s)\n" "$BRANCH" "$branch_state"
		if [[ "$branch_state" != "deleted" ]]; then
			printf -- '- Open the PR manually or delete the branch: %s\n' "$COMPARE_URL"
		fi
	} >>"$GITHUB_STEP_SUMMARY"
}

if ! git diff --quiet; then
	REPO="${GITHUB_REPOSITORY:-}"
	if [[ -z "$REPO" ]]; then
		log_error "GITHUB_REPOSITORY is required to create the cleanup commit"
		exit 1
	fi
	SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
	# createCommitOnBranch takes plain repo-relative paths.
	COMMIT_PATH="${OSV_TOML#./}"
	if [[ "$COMMIT_PATH" == /* || "/${COMMIT_PATH}/" == */../* ]]; then
		log_error "The suppression file must be a repo-relative path without '..' to be cleaned up automatically: $OSV_TOML"
		exit 1
	fi

	STALE_LIST=""
	for id in "${STALE_IDS[@]+"${STALE_IDS[@]}"}"; do
		STALE_LIST="${STALE_LIST}- \`${id}\` (stale — vulnerability resolved)
"
	done
	REMOVED_LIST="${STALE_LIST}"

	# Base the commit on the default branch head as GitHub sees it, not on the
	# local checkout: a workflow_dispatch run may be checked out on another ref.
	DEFAULT_BRANCH=$(gh api "repos/${REPO}" --jq '.default_branch' || true)
	BASE_SHA=""
	if [[ -n "$DEFAULT_BRANCH" ]]; then
		BASE_SHA=$(gh api "repos/${REPO}/branches/${DEFAULT_BRANCH}" --jq '.commit.sha' || true)
	fi
	if [[ -z "$DEFAULT_BRANCH" || -z "$BASE_SHA" ]]; then
		log_error "Could not resolve the default branch head of ${REPO}"
		exit 1
	fi

	# The commit uploads the whole edited file, so the edit must start from the
	# version the base holds. If the default branch changed the file since
	# checkout (or the run is on another ref), stop instead of clobbering it.
	LOCAL_BLOB=$(git rev-parse "HEAD:${COMMIT_PATH}" 2>/dev/null || true)
	BASE_BLOB=$(gh api "repos/${REPO}/contents/${COMMIT_PATH}?ref=${BASE_SHA}" --jq '.sha' 2>/dev/null || true)
	if [[ -z "$LOCAL_BLOB" || "$LOCAL_BLOB" != "$BASE_BLOB" ]]; then
		log_error "${COMMIT_PATH} on ${DEFAULT_BRANCH} (${BASE_SHA}) differs from the checked-out version; rerun on the current ${DEFAULT_BRANCH}"
		exit 1
	fi

	# Unique per run: two runs in the same second must never share a branch,
	# or reset mode would move one run's open PR onto the other's commit.
	BRANCH="chore/remove-stale-vulns-$(date +%Y%m%d%H%M%S)-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-${RANDOM}"
	COMPARE_URL="${SERVER_URL}/${REPO}/compare/${DEFAULT_BRANCH}...${BRANCH}?expand=1"
	COMMIT_HEADLINE="chore(security): remove stale vulnerability suppressions"
	COMMIT_BODY="The following suppressions are no longer needed:
${REMOVED_LIST}
Detected by the weekly vuln-suppression-check workflow."

	commit_args=(
		--repository "$REPO"
		--branch "$BRANCH"
		--mode reset
		--base "$BASE_SHA"
		--message "$COMMIT_HEADLINE"
		--body "$COMMIT_BODY"
	)
	if [[ -f "$OSV_TOML" ]]; then
		commit_args+=(--file "$COMMIT_PATH")
	else
		commit_args+=(--delete "$COMMIT_PATH")
	fi

	# GitHub creates and signs the commit (createCommitOnBranch), so it merges
	# where required_signatures is enforced. Reset mode creates the branch only
	# once the commit exists, so a failed commit never leaves a branch behind.
	if ! bash "$SCRIPTS_DIR/../git/create-signed-commit.sh" "${commit_args[@]}"; then
		log_error "Failed to create the signed cleanup commit; no branch was created"
		exit 1
	fi

	WF_URL="${SERVER_URL}/${REPO}/actions"
	if [[ -n "${WORKFLOW_FILE:-}" ]]; then
		WF_URL="${WF_URL}/workflows/${WORKFLOW_FILE}"
	fi

	PR_BODY="## Summary
- Remove stale vulnerability suppressions whose vulnerability is resolved
"
	if [[ -n "$STALE_LIST" ]]; then
		PR_BODY="${PR_BODY}
### Removed (stale)
${STALE_LIST}"
	fi
	PR_BODY="${PR_BODY}
## Test plan
- [ ] CI security audit passes without these suppressions
- [ ] osv-scanner scan passes without these suppressions

---
*Auto-created by [vuln-suppression-check](${WF_URL}).*"

	# Labels are applied after creation so a missing label can never block the
	# PR (creating a PR with an unknown label rejects the whole command).
	PR_URL=""
	if ! PR_URL=$(gh pr create \
		--repo "$REPO" \
		--head "$BRANCH" \
		--base "$DEFAULT_BRANCH" \
		--title "$COMMIT_HEADLINE" \
		--body "$PR_BODY"); then
		# The PR may exist even though gh reported an error; never delete its
		# branch. If the lookup itself fails we cannot tell, so leave the branch.
		if ! PR_URL=$(gh pr list --repo "$REPO" --head "$BRANCH" --state open \
			--json url --jq '.[0].url // empty'); then
			log_error "Creating the cleanup PR failed and checking for an existing PR on $BRANCH also failed; leaving the branch in place: $COMPARE_URL"
			write_cleanup_failure_summary "Creating the cleanup PR failed and it could not be verified whether a PR exists; the branch was left in place." "left in place"
			exit 1
		fi
		if [[ -z "$PR_URL" ]]; then
			log_error "Failed to create the cleanup PR for branch $BRANCH"
			if gh api -X DELETE "repos/${REPO}/git/refs/heads/${BRANCH}" >/dev/null; then
				log_info "Deleted branch $BRANCH"
				write_cleanup_failure_summary "Creating the cleanup PR failed; the branch was deleted. Rerun the workflow." "deleted"
			else
				log_error "Could not delete branch $BRANCH; open the PR or delete it manually: $COMPARE_URL"
				write_cleanup_failure_summary "Creating the cleanup PR failed and the branch could not be deleted." "left in place"
			fi
			exit 1
		fi
		log_warning "PR creation reported an error, but $PR_URL exists for $BRANCH"
	fi

	if [[ -n "${CLEANUP_PR_LABELS}" ]]; then
		IFS=',' read -ra _cleanup_labels <<<"${CLEANUP_PR_LABELS}"
		for label in "${_cleanup_labels[@]}"; do
			label="${label#"${label%%[![:space:]]*}"}"
			label="${label%"${label##*[![:space:]]}"}"
			[[ -n "$label" ]] || continue
			if ! gh pr edit "$PR_URL" --repo "$REPO" --add-label "$label" >/dev/null; then
				log_warning "Could not add label '$label' to $PR_URL (missing in ${REPO}?); continuing"
			fi
		done
	fi

	log_success "Cleanup PR created on branch $BRANCH: $PR_URL"
else
	log_info "No file changes needed."
fi

# Expired suppressions are left untouched. Flag them and fail the workflow so
# the team re-evaluates each one, independent of any stale cleanup PR above.
if [[ ${#EXPIRED_IDS[@]} -gt 0 ]]; then
	flag_expired_suppressions
	exit 1
fi
