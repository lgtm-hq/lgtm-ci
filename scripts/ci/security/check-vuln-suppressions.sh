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
#
# Python: needs Python 3.11 or newer (classify-suppressions.py uses
# tomllib) as python3 on PATH; PYTHON from the environment is ignored,
# because this job holds a contents:write token (lib/python.sh,
# pin_python_from_path). Checked once, after the config and token checks and
# before osv-scanner runs.
#
# Exit status:
#   0   - no suppression file, or nothing expired (a cleanup PR may be open)
#   1   - expired suppressions flagged, or a token, git, API or PR error
#   69  - python3 is missing or older than 3.11 (one ::error:: line),
#         found before the scan
#   other non-zero - osv-scanner's own status on a scan error (passed
#         through), or the status of a helper (Python, git, gh) that failed
#
# Every Python call runs isolated (-I): PYTHONPATH and the other PYTHON*
# variables are ignored and neither the working directory nor the script's
# directory is importable, so nothing in the scanned checkout or the job's
# environment can add a module to a process that holds the write token.

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
# shellcheck source=../lib/python.sh
source "$LIB_DIR/python.sh"

cd "$REPO_ROOT"

# Text from the caller (CONFIG_PATH and other inputs), the scanned repository
# or a tool (IDs, comments, file, branch and package names) must never act as
# a runner command: the runner reads "##[cmd]" anywhere in a line and
# "::cmd::" at its start. Such text is printed with printf, never log.sh's
# echo -e (which would decode \n or \u0023 escapes), after safe_text turns
# control characters into "?" and breaks up "##[" and "::". Output replayed
# from a tool is also printed between ::stop-commands:: and a random token.
safe_text() {
	local text="$1"
	text="${text//[[:cntrl:]]/?}"
	text="${text//'##['/'#?['}"
	text="${text//'::'/':?'}"
	printf '%s' "$text"
}

log_plain() {
	printf '%s\n' "$(safe_text "$*")" >&2
}

OSV_TOML="${CONFIG_PATH:-.osv-scanner.toml}"
# Default labels only when unset; explicit "" opts out of labeling.
CLEANUP_PR_LABELS="${CLEANUP_PR_LABELS-security,dependencies,automation}"

if [[ ! -f "$OSV_TOML" ]]; then
	log_plain "[SUCCESS] No $OSV_TOML found. Nothing to check."
	exit 0
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
	log_error "GH_TOKEN is required"
	exit 1
fi

# This job holds a contents:write token: the interpreter never comes from
# the environment. python3 from PATH is checked once (3.11 or newer) and
# pinned to its absolute path for every run_python below (#1591).
pin_python_from_path || exit $?

# The probe ignores the caller's config. From osv-scanner 2.4.0 the Go
# toolchain version in go.mod is only scanned with ScanGoModVersion = true;
# without it a suppressed Go stdlib advisory looks resolved and would be
# removed as stale. Older releases scan it by default but reject the key as
# unknown, so the probe tries the key first and falls back to an empty config
# only on that error. No version parsing, so no version string can make the
# probe skip the key on a scanner that needs it.
PROBE_STDERR=""
CLASSIFIER_LOG=""
REMOVE_IDS_FILE=""
REMOVER_LOG=""
PROBE_CONFIG=$(mktemp)
trap 'rm -f "$PROBE_CONFIG" ${PROBE_STDERR:+"$PROBE_STDERR"} ${CLASSIFIER_LOG:+"$CLASSIFIER_LOG"} ${REMOVE_IDS_FILE:+"$REMOVE_IDS_FILE"} ${REMOVER_LOG:+"$REMOVER_LOG"}' EXIT
PROBE_STDERR=$(mktemp)
printf 'ScanGoModVersion = true\n' >"$PROBE_CONFIG"

replay_untrusted() {
	local token
	token="vuln-suppressions-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
	printf '::stop-commands::%s\n' "$token" >&2
	cat >&2
	printf '\n::%s::\n' "$token" >&2
}

# Sets PROBE_OUTPUT and PROBE_EXIT and leaves the scanner's stderr in
# PROBE_STDERR for the caller to check and replay.
run_probe() {
	PROBE_EXIT=0
	PROBE_OUTPUT=$(
		osv-scanner scan --recursive --format json --config "$1" \
			. 2>"$PROBE_STDERR"
	) || PROBE_EXIT=$?
}

log_info "Probing osv-scanner without suppressions..."
run_probe "$PROBE_CONFIG"
if [[ "$PROBE_EXIT" -gt 1 ]] && grep -q 'unknown keys in config file' "$PROBE_STDERR"; then
	log_info "osv-scanner rejected ScanGoModVersion (releases before 2.4.0 scan go.mod by default); probing again with an empty config"
	run_probe /dev/null
fi
replay_untrusted <"$PROBE_STDERR"

if [[ "$PROBE_EXIT" -gt 1 ]]; then
	log_plain "[ERROR] osv-scanner failed with exit code $PROBE_EXIT"
	printf '%s\n' "$PROBE_OUTPUT" | replay_untrusted
	exit "$PROBE_EXIT"
fi

# The classifier also checks the probe run: an exit status its output does
# not imply, or a stderr line naming an error (osv-scanner keeps exit status
# 1 when an extractor or enricher failed), means the scan may be incomplete,
# so nothing is classified or removed and the job fails.
log_info "Classifying suppressions..."
export CONFIG_PATH="$OSV_TOML"
CLASSIFIER_LOG=$(mktemp)
CLASSIFY_EXIT=0
CLASSIFICATION_JSON=$(printf '%s\n' "$PROBE_OUTPUT" |
	PROBE_EXIT="$PROBE_EXIT" PROBE_STDERR_FILE="$PROBE_STDERR" \
		run_python -I "$SCRIPTS_DIR/classify-suppressions.py" 2>"$CLASSIFIER_LOG") || CLASSIFY_EXIT=$?
replay_untrusted <"$CLASSIFIER_LOG"
if [[ "$CLASSIFY_EXIT" -ne 0 ]]; then
	log_error "Suppressions were not classified; nothing was removed"
	exit "$CLASSIFY_EXIT"
fi

# The remove list is the classifier's own stale array, passed on as JSON in a
# file (a long list would not fit in the environment): no text rows,
# splitting or trimming sit between the classification and the removal, so
# an ID with whitespace, a tab or a newline cannot turn into another ID. A
# conversion that fails stops the script here (set -e, pipefail); a loop that
# read nothing would report "all suppressions are active".
REMOVE_IDS_FILE=$(mktemp)
printf '%s\n' "$CLASSIFICATION_JSON" | run_python -I "$SCRIPTS_DIR/classify-suppressions.py" --stale-json >"$REMOVE_IDS_FILE"

# Rows for logs, the job summary and the PR body only. Every value in them is
# in a printable form (see classify-suppressions.py's shown): no tab, newline
# or other control character, nothing that breaks a Markdown code span or
# table, and nothing a runner reads as a command. Nothing read from these
# rows decides what is removed.
CLASSIFIED_ROWS=$(printf '%s\n' "$CLASSIFICATION_JSON" | run_python -I "$SCRIPTS_DIR/classify-suppressions.py" --rows)

STALE_IDS=()
EXPIRED_IDS=()
ACTIVE_IDS=()
NOT_UNDERSTOOD=()
declare -A EXPIRED_UNTIL=()
while IFS=$'\t' read -r category vid expire_date; do
	case "$category" in
	STALE) STALE_IDS+=("$vid") ;;
	EXPIRED)
		EXPIRED_IDS+=("$vid")
		EXPIRED_UNTIL["$vid"]="$expire_date"
		;;
	ACTIVE) ACTIVE_IDS+=("$vid") ;;
	NOT_UNDERSTOOD) NOT_UNDERSTOOD+=("$vid") ;;
	esac
done <<<"$CLASSIFIED_ROWS"

# Only stale suppressions are auto-removed. Expired entries are left untouched
# and flagged for manual review (see issue #377): expiry means the timebox
# lapsed and a human must re-evaluate, not that the vulnerability is gone.

for id in "${ACTIVE_IDS[@]+"${ACTIVE_IDS[@]}"}"; do
	log_plain "[SUCCESS] Active: $id"
done
for id in "${STALE_IDS[@]+"${STALE_IDS[@]}"}"; do
	log_plain "[WARN] Stale: $id"
done
for text in "${NOT_UNDERSTOOD[@]+"${NOT_UNDERSTOOD[@]}"}"; do
	log_plain "[WARN] Left alone, not understood: $text"
done

# Lists in the job summary and the PR body stop after this many items, so a
# huge file cannot push the PR body past GitHub's size limit; the job log
# above lists every item.
LIST_LIMIT=50

# Entries the classifier does not read exactly as osv-scanner does are never
# removed. They do not fail the job (the scanner may read them fine); the
# summary lists them for a person to check.
report_not_understood() {
	[[ ${#NOT_UNDERSTOOD[@]} -gt 0 && -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
	local text listed=0
	{
		printf '## Vulnerability suppressions left alone (not understood)\n\n'
		# shellcheck disable=SC2016 # the backticks are Markdown, not a command
		printf 'These entries in `%s` use a key, a value type or an ID form that this check does not read exactly as osv-scanner does. They were not classified and are never removed automatically, and they do not fail this job. Check each one by hand.\n\n' "$OSV_TOML"
		for text in "${NOT_UNDERSTOOD[@]}"; do
			if [[ "$listed" -ge "$LIST_LIMIT" ]]; then
				printf -- '- ... and %d more; the job log lists every one\n' "$((${#NOT_UNDERSTOOD[@]} - listed))"
				break
			fi
			# shellcheck disable=SC2016 # the backticks are Markdown, not a command
			printf -- '- `%s`\n' "$text"
			listed=$((listed + 1))
		done
		printf '\n'
	} >>"$GITHUB_STEP_SUMMARY"
}
report_not_understood

# Emit expired suppressions to the log and job summary. Called once, before
# any cleanup step can stop the run, so the summary is written on every path;
# every later exit path stays non-zero while expired entries exist.
flag_expired_suppressions() {
	log_plain "[ERROR] Expired suppression(s) require manual review (left untouched in $OSV_TOML):"
	local summary
	summary="## Expired vulnerability suppressions require manual review

The following suppressions in \`${OSV_TOML}\` are past their timebox
(\`effectiveUntil\`, or \`ignoreUntil\` when that is not set) and were
**left untouched**. Expiry means the timebox lapsed, not that the
vulnerability is resolved. Re-evaluate each entry and either remediate the
vulnerability or renew the suppression with a new \`effectiveUntil\`.

| ID | Expired at | Required action |
| --- | --- | --- |
"
	local id expire_date listed=0
	for id in "${EXPIRED_IDS[@]+"${EXPIRED_IDS[@]}"}"; do
		expire_date="${EXPIRED_UNTIL[$id]:-unknown}"
		log_plain "[ERROR]   - ${id} (until ${expire_date}) — remediate the vulnerability or renew the suppression"
		if [[ "$listed" -lt "$LIST_LIMIT" ]]; then
			summary="${summary}| \`${id}\` | ${expire_date} | Remediate the vulnerability or renew the suppression |
"
		fi
		listed=$((listed + 1))
	done
	if [[ "$listed" -gt "$LIST_LIMIT" ]]; then
		summary="${summary}
... and $((listed - LIST_LIMIT)) more; the job log lists every one.
"
	fi
	if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
		printf '%s\n' "$summary" >>"$GITHUB_STEP_SUMMARY"
	fi
}

if [[ ${#EXPIRED_IDS[@]} -gt 0 ]]; then
	flag_expired_suppressions
fi

if [[ "$(<"$REMOVE_IDS_FILE")" == "[]" ]]; then
	if [[ ${#EXPIRED_IDS[@]} -gt 0 ]]; then
		exit 1
	fi
	if [[ ${#NOT_UNDERSTOOD[@]} -gt 0 ]]; then
		log_plain "[SUCCESS] No stale suppressions to remove; ${#NOT_UNDERSTOOD[@]} left alone because they are not understood (see the job summary)."
	else
		log_success "All suppressions are active. Nothing to do."
	fi
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
	log_plain "[ERROR] gh pr list failed: $PR_LIST_OUTPUT"
	exit 1
fi
if [[ -n "$PR_LIST_OUTPUT" ]]; then
	log_plain "[INFO] Cleanup PR #${PR_LIST_OUTPUT} already open. Skipping stale removal."
	if [[ ${#EXPIRED_IDS[@]} -gt 0 ]]; then
		exit 1
	fi
	exit 0
fi

# The remover's stderr is kept to replay it and to list, in the PR body, the
# comments the edit deleted ("Removed comment line N: <JSON string>"). On a
# refusal it has written nothing and printed one ERROR line.
REMOVER_LOG=$(mktemp)
REMOVER_EXIT=0
REMOVE_IDS_FILE="$REMOVE_IDS_FILE" run_python -I "$SCRIPTS_DIR/remove_stale_suppressions.py" "$OSV_TOML" 2>"$REMOVER_LOG" || REMOVER_EXIT=$?
replay_untrusted <"$REMOVER_LOG"
if [[ "$REMOVER_EXIT" -ne 0 ]]; then
	log_plain "[ERROR] Stale suppressions were not removed; $OSV_TOML is unchanged"
	exit "$REMOVER_EXIT"
fi
# Each line reads 'line N: "<text>"', cut to 300 characters: it starts with
# "line" (or "..."), so it cannot close the fenced block it is shown in, and
# the JSON string holds no control characters, "##[" or "::".
REMOVED_COMMENTS=$(awk -v max="$LIST_LIMIT" '
	/^Removed comment / { n++; if (n <= max) print substr(substr($0, 17), 1, 300) }
	END { if (n > max) printf "... and %d more comment lines; the job log lists every one\n", n - max }
' "$REMOVER_LOG")

# Delete the file only when nothing but whitespace is left: a kept file
# header or section comment stays, so no comment is lost without a report.
if [[ -f "$OSV_TOML" ]] && ! grep -q '[^[:space:]]' "$OSV_TOML"; then
	log_plain "[INFO] Nothing left in $OSV_TOML, removing file"
	rm -f "$OSV_TOML"
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
	# Same rules as create-signed-commit.sh's validate_repo_path.
	if [[ "$COMMIT_PATH" == /* || "/${COMMIT_PATH}/" == */../* ||
		"/${COMMIT_PATH}/" == */./* || "$COMMIT_PATH" == *//* || "$COMMIT_PATH" == */ ]]; then
		log_plain "[ERROR] The suppression file must be a plain repo-relative path (no absolute path, '..', '.' or empty components) to be cleaned up automatically: $OSV_TOML"
		exit 1
	fi

	STALE_LIST=""
	listed=0
	for id in "${STALE_IDS[@]+"${STALE_IDS[@]}"}"; do
		if [[ "$listed" -ge "$LIST_LIMIT" ]]; then
			STALE_LIST="${STALE_LIST}- ... and $((${#STALE_IDS[@]} - listed)) more; the job log lists every one
"
			break
		fi
		STALE_LIST="${STALE_LIST}- \`${id}\` (stale — vulnerability resolved)
"
		listed=$((listed + 1))
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
		log_plain "[ERROR] Could not resolve the default branch head of ${REPO}"
		exit 1
	fi

	# The commit uploads the whole edited file, so the edit must start from the
	# version the base holds. If the default branch changed the file since
	# checkout (or the run is on another ref), stop instead of clobbering it.
	LOCAL_BLOB=$(git rev-parse "HEAD:${COMMIT_PATH}" 2>/dev/null || true)
	BASE_BLOB=$(gh api "repos/${REPO}/contents/${COMMIT_PATH}?ref=${BASE_SHA}" --jq '.sha' 2>/dev/null || true)
	if [[ -z "$LOCAL_BLOB" || "$LOCAL_BLOB" != "$BASE_BLOB" ]]; then
		log_plain "[ERROR] ${COMMIT_PATH} on ${DEFAULT_BRANCH} (${BASE_SHA}) differs from the checked-out version; rerun on the current ${DEFAULT_BRANCH}"
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
	if [[ -n "$REMOVED_COMMENTS" ]]; then
		PR_BODY="${PR_BODY}
### Comment lines removed with these entries
Check that none of them explained an entry that is still in the file.

\`\`\`text
${REMOVED_COMMENTS}
\`\`\`
"
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
			log_plain "[ERROR] Creating the cleanup PR failed and checking for an existing PR on $BRANCH also failed; leaving the branch in place: $COMPARE_URL"
			write_cleanup_failure_summary "Creating the cleanup PR failed and it could not be verified whether a PR exists; the branch was left in place." "left in place"
			exit 1
		fi
		if [[ -z "$PR_URL" ]]; then
			log_plain "[ERROR] Failed to create the cleanup PR for branch $BRANCH"
			if gh api -X DELETE "repos/${REPO}/git/refs/heads/${BRANCH}" >/dev/null; then
				log_plain "[INFO] Deleted branch $BRANCH"
				write_cleanup_failure_summary "Creating the cleanup PR failed; the branch was deleted. Rerun the workflow." "deleted"
			else
				log_plain "[ERROR] Could not delete branch $BRANCH; open the PR or delete it manually: $COMPARE_URL"
				write_cleanup_failure_summary "Creating the cleanup PR failed and the branch could not be deleted." "left in place"
			fi
			exit 1
		fi
		log_plain "[WARN] PR creation reported an error, but $PR_URL exists for $BRANCH"
	fi

	if [[ -n "${CLEANUP_PR_LABELS}" ]]; then
		IFS=',' read -ra _cleanup_labels <<<"${CLEANUP_PR_LABELS}"
		for label in "${_cleanup_labels[@]}"; do
			label="${label#"${label%%[![:space:]]*}"}"
			label="${label%"${label##*[![:space:]]}"}"
			[[ -n "$label" ]] || continue
			if ! gh pr edit "$PR_URL" --repo "$REPO" --add-label "$label" >/dev/null; then
				log_plain "[WARN] Could not add label '$label' to $PR_URL (missing in ${REPO}?); continuing"
			fi
		done
	fi

	log_plain "[SUCCESS] Cleanup PR created on branch $BRANCH: $PR_URL"
else
	log_info "No file changes needed."
fi

# Expired suppressions are left untouched and were flagged above. Fail the
# workflow so the team re-evaluates each one, independent of any stale
# cleanup PR.
if [[ ${#EXPIRED_IDS[@]} -gt 0 ]]; then
	exit 1
fi
