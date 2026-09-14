#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Record a release recovery run on the release-failure issue the
#          notifier (#964) opened, and close it when the recovery succeeded.
#
# Self-contained on purpose: it only needs the #964 issue contract (title
# `fix(release): tag publish failed: <tag> (<workflow-key>)`, tracking key
# `release-failure:<workflow-key>:<tag>`), so the recovery workflow does not
# have to depend on the notifier's implementation details.
#
# Runs on success AND failure (`if: always()`): a failed recovery is exactly
# what the issue needs to show — the tier-three hand-off — while a success
# closes the issue after its final comment.
#
# The issue is closed ONLY when the run was live, the resolve stage
# succeeded, every channel detected as missing has a successful resume
# result, and no missing channel is unresumable (PyPI by policy, Docker for
# now). A dry run records the table and leaves the issue open; so does any
# failed, cancelled, or unresumable channel.
#
# Environment:
#   TAG               Recovered tag (required)
#   WORKFLOW_KEY      Notifier workflow key the issue was filed under (required)
#   Either the per-job results (the workflow passes these):
#   DRY_RUN           1 when the run was a dry run (default 0)
#   RESOLVE_RESULT    needs.resolve.result
#   NPM_RESULT, RELEASE_RESULT, HOMEBREW_RESULT
#                     needs.resume-*.result (success|failure|cancelled|skipped)
#   MISSING_SET       The detected missing (resumable) set, JSON
#   UNRESUMABLE_SET   The detected missing channels no job can resume, JSON
#   or an explicit outcome (takes precedence when set):
#   RECOVERY_STATUS   success | failure | dry-run
#   RECOVERY_SUMMARY  Markdown summary (the channel table + outcome)
#   GITHUB_REPOSITORY, GH_TOKEN, GITHUB_RUN_ID, GITHUB_SERVER_URL
#   GH_CMD            gh binary override (default gh)

set -euo pipefail

: "${TAG:?TAG is required}"
: "${WORKFLOW_KEY:?WORKFLOW_KEY is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
GH="${GH_CMD:-gh}"

DRY_RUN="${DRY_RUN:-0}"
MISSING_SET="${MISSING_SET:-[]}"
UNRESUMABLE_SET="${UNRESUMABLE_SET:-[]}"
NPM_RESULT="${NPM_RESULT:-skipped}"
RELEASE_RESULT="${RELEASE_RESULT:-skipped}"
HOMEBREW_RESULT="${HOMEBREW_RESULT:-skipped}"

# The resume result for a detected-missing channel; a channel with no resume
# job (anything not listed here) can never be marked done by this run.
_result_for() {
	case "$1" in
	npm) echo "$NPM_RESULT" ;;
	github-release) echo "$RELEASE_RESULT" ;;
	homebrew) echo "$HOMEBREW_RESULT" ;;
	*) echo "no-resume-job" ;;
	esac
}

reasons=()
if [[ -z "${RECOVERY_STATUS:-}" ]]; then
	: "${RESOLVE_RESULT:?RESOLVE_RESULT is required when RECOVERY_STATUS is not set}"
	if [[ "$DRY_RUN" == "1" ]]; then
		RECOVERY_STATUS="dry-run"
	else
		RECOVERY_STATUS="success"
		[[ "$RESOLVE_RESULT" == "success" ]] || {
			RECOVERY_STATUS="failure"
			reasons+=("resolve stage: ${RESOLVE_RESULT}")
		}
		# Every job that ran must have succeeded (a skipped job is a channel
		# that was not missing, or a gate that was not met).
		for pair in "npm:${NPM_RESULT}" "github-release:${RELEASE_RESULT}" "homebrew:${HOMEBREW_RESULT}"; do
			case "${pair#*:}" in
			success | skipped) ;;
			*)
				RECOVERY_STATUS="failure"
				reasons+=("${pair%%:*} resume: ${pair#*:}")
				;;
			esac
		done
		# Every detected-missing channel must have been resumed successfully;
		# a skipped resume for a missing channel means its gate was not met
		# (e.g. no artifact configured) and the channel is still missing.
		while IFS= read -r channel; do
			[[ -n "$channel" ]] || continue
			r="$(_result_for "$channel")"
			if [[ "$r" != "success" ]]; then
				RECOVERY_STATUS="failure"
				reasons+=("${channel} still missing (resume result: ${r})")
			fi
		done < <(printf '%s' "$MISSING_SET" | jq -r '.[]?' 2>/dev/null || true)
		# Unresumable missing channels (PyPI, Docker) keep the incident open.
		while IFS= read -r channel; do
			[[ -n "$channel" ]] || continue
			RECOVERY_STATUS="failure"
			reasons+=("${channel} is missing and cannot be resumed by this workflow")
		done < <(printf '%s' "$UNRESUMABLE_SET" | jq -r '.[]?' 2>/dev/null || true)
	fi
fi
if [[ -z "${RECOVERY_SUMMARY:-}" ]]; then
	RECOVERY_SUMMARY="| Channel resume | Result |
| --- | --- |
| resolve (tag, artifacts, detection) | ${RESOLVE_RESULT:-unknown} |
| npm | ${NPM_RESULT} |
| GitHub Release | ${RELEASE_RESULT} |
| Homebrew dispatch | ${HOMEBREW_RESULT} |

Missing set at detection: \`${MISSING_SET}\`
Unresumable at detection: \`${UNRESUMABLE_SET}\`"
	if ((${#reasons[@]} > 0)); then
		RECOVERY_SUMMARY+=$'\n\nStill open:'
		for reason in "${reasons[@]}"; do
			RECOVERY_SUMMARY+=$'\n'"- ${reason}"
		done
	fi
fi

[[ "$RECOVERY_STATUS" == "success" || "$RECOVERY_STATUS" == "failure" || "$RECOVERY_STATUS" == "dry-run" ]] ||
	{
		echo "ERROR: RECOVERY_STATUS must be 'success', 'failure' or 'dry-run' (got '$RECOVERY_STATUS')" >&2
		exit 1
	}

title="fix(release): tag publish failed: ${TAG} (${WORKFLOW_KEY})"
tracking_key="release-failure:${WORKFLOW_KEY}:${TAG}"

issue=""
if issue="$("$GH" issue list --repo "$GITHUB_REPOSITORY" --state open --limit 1 \
	--search "\"${title}\" in:title" --json number --jq '.[0].number // empty' 2>/dev/null)" && [[ -n "$issue" ]]; then
	:
elif issue="$("$GH" issue list --repo "$GITHUB_REPOSITORY" --state open --limit 1 \
	--search "\"${tracking_key}\"" --json number --jq '.[0].number // empty' 2>/dev/null)"; then
	:
else
	echo "WARNING: could not search for the release-failure issue; leaving it untouched" >&2
	exit 0
fi

if [[ -z "$issue" ]]; then
	echo "No open release-failure issue for tag '${TAG}'; nothing to record."
	exit 0
fi

run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-}"
body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT
{
	echo "## Release recovery run — ${RECOVERY_STATUS}"
	echo ""
	echo "$RECOVERY_SUMMARY"
	echo ""
	echo "- **Run:** ${run_url}"
	echo ""
	case "$RECOVERY_STATUS" in
	success) echo "All missing channels were published from the original attested artifacts. Closing this issue." ;;
	dry-run) echo "Dry run: detection only, nothing was resumed. Re-run with dry-run: false to resume the missing channels; this issue stays open." ;;
	*) echo "The recovery run did not complete the release; the channels listed above still need attention (see the run for tier guidance). This issue stays open." ;;
	esac
} >"$body_file"

"$GH" issue comment "$issue" --repo "$GITHUB_REPOSITORY" --body-file "$body_file" >/dev/null
echo "Recorded recovery outcome on issue #${issue}"

if [[ "$RECOVERY_STATUS" == "success" ]]; then
	"$GH" issue close "$issue" --repo "$GITHUB_REPOSITORY" >/dev/null
	echo "Closed release-failure issue #${issue} (recovery succeeded)."
fi
