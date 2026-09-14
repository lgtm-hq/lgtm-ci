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
# Environment:
#   TAG               Recovered tag (required)
#   WORKFLOW_KEY      Notifier workflow key the issue was filed under (required)
#   Either the per-job results (the workflow passes these):
#   RESOLVE_RESULT    needs.resolve.result
#   NPM_RESULT, RELEASE_RESULT, HOMEBREW_RESULT
#                     needs.resume-*.result (success|failure|cancelled|skipped)
#   MISSING_SET       The detected missing set (JSON) for the table
#   or an explicit outcome (takes precedence when set):
#   RECOVERY_STATUS   success | failure
#   RECOVERY_SUMMARY  Markdown summary (the channel table + outcome)
#   GITHUB_REPOSITORY, GH_TOKEN, GITHUB_RUN_ID, GITHUB_SERVER_URL
#   GH_CMD            gh binary override (default gh)

set -euo pipefail

: "${TAG:?TAG is required}"
: "${WORKFLOW_KEY:?WORKFLOW_KEY is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
GH="${GH_CMD:-gh}"

# A resume job counts as fine when it ran and succeeded or was skipped
# (channel already complete); anything else — failure, cancelled, or a
# resolve stage that did not succeed — is a failed recovery.
_job_ok() {
	[[ "$1" == "success" || "$1" == "skipped" ]]
}
if [[ -z "${RECOVERY_STATUS:-}" ]]; then
	: "${RESOLVE_RESULT:?RESOLVE_RESULT is required when RECOVERY_STATUS is not set}"
	NPM_RESULT="${NPM_RESULT:-skipped}"
	RELEASE_RESULT="${RELEASE_RESULT:-skipped}"
	HOMEBREW_RESULT="${HOMEBREW_RESULT:-skipped}"
	if [[ "$RESOLVE_RESULT" == "success" ]] && _job_ok "$NPM_RESULT" && _job_ok "$RELEASE_RESULT" && _job_ok "$HOMEBREW_RESULT"; then
		RECOVERY_STATUS="success"
	else
		RECOVERY_STATUS="failure"
	fi
fi
if [[ -z "${RECOVERY_SUMMARY:-}" ]]; then
	RECOVERY_SUMMARY="| Channel resume | Result |
| --- | --- |
| resolve (tag, artifacts, detection) | ${RESOLVE_RESULT:-unknown} |
| npm | ${NPM_RESULT:-skipped} |
| GitHub Release | ${RELEASE_RESULT:-skipped} |
| Homebrew dispatch | ${HOMEBREW_RESULT:-skipped} |

Missing set at detection: \`${MISSING_SET:-[]}\`"
fi

[[ "$RECOVERY_STATUS" == "success" || "$RECOVERY_STATUS" == "failure" ]] ||
	{
		echo "ERROR: RECOVERY_STATUS must be 'success' or 'failure' (got '$RECOVERY_STATUS')" >&2
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
	if [[ "$RECOVERY_STATUS" == "success" ]]; then
		echo "All missing channels were published from the original attested artifacts. Closing this issue."
	else
		echo "The recovery run failed; the remaining channels still need attention (see the run for tier guidance)."
	fi
} >"$body_file"

"$GH" issue comment "$issue" --repo "$GITHUB_REPOSITORY" --body-file "$body_file" >/dev/null
echo "Recorded recovery outcome on issue #${issue}"

if [[ "$RECOVERY_STATUS" == "success" ]]; then
	"$GH" issue close "$issue" --repo "$GITHUB_REPOSITORY" >/dev/null
	echo "Closed release-failure issue #${issue} (recovery succeeded)."
fi
