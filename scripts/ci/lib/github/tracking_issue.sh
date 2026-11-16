#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Keep one tracking issue in step with a scheduled check's result.
#
# Shared by the scheduled maintenance checks that open, update and close one
# tracking issue (results-hosts-drift.sh #1498, egress-dns-check.sh #1548).
#
# The tracking issue is the lowest-numbered open issue opened by
# github-actions[bot] whose body carries TRACKING_ISSUE_MARKER. Every page of
# the issues API is read (not the search index, which lags).
#
# Usage:
#   source "$SCRIPT_DIR/../lib/github/tracking_issue.sh"
#   TRACKING_ISSUE_MARKER="<!-- lgtm-ci:my-check -->"
#   TRACKING_ISSUE_TITLE="fix(...): ..."
#   TRACKING_ISSUE_NAME="my check"        # "Opened the <name> tracking issue"
#   TRACKING_ISSUE_CHECK="my check"       # "The <check> wrote no issue body"
#   tracking_issue_close "<log line when there is nothing to close>" "<comment>"
#   tracking_issue_upsert "$body_file" "<subject of the comment on a change>"
#
# Every function needs GH_TOKEN and GITHUB_REPOSITORY. A listing or read error
# exits 2 before any write, so a transient API error never opens a duplicate.

[[ -n "${_LGTM_CI_GITHUB_TRACKING_ISSUE_LOADED:-}" ]] && return 0
readonly _LGTM_CI_GITHUB_TRACKING_ISSUE_LOADED=1

# shellcheck source=../log.sh
source "$(dirname "${BASH_SOURCE[0]}")/../log.sh"

# The login GitHub shows for issues opened with GITHUB_TOKEN.
readonly TRACKING_ISSUE_AUTHOR="github-actions[bot]"

# Print the link to this run, or "(local run)" outside Actions.
tracking_issue_run_url() {
	if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
		echo "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
	else
		echo "(local run)"
	fi
}

# Print the number of the open tracking issue, or nothing. Every page of
# open issues is read (`gh api --paginate`, which follows the Link header to
# the last page and fails on any page error), so the tracker cannot fall
# outside a listing limit. Only an issue that GITHUB_TOKEN itself opened
# (TRACKING_ISSUE_AUTHOR, a Bot) counts, so nobody else can plant the marker.
# The lowest matching number wins. Any listing error or unexpected output
# exits 2 before a write.
tracking_issue_find() {
	local filter listing number lowest=""
	local marker_shape='^<!-- [a-z0-9:-]+ -->$'
	if [[ ! "${TRACKING_ISSUE_MARKER:-}" =~ $marker_shape ]]; then
		log_error "TRACKING_ISSUE_MARKER is missing or malformed"
		exit 2
	fi
	# The marker (checked above) and author contain no `"` or `\`, so they
	# embed verbatim.
	filter="$(printf '.[] | select(.pull_request == null and .user.login == "%s" and .user.type == "Bot" and ((.body // "") | contains("%s"))) | .number' \
		"$TRACKING_ISSUE_AUTHOR" "$TRACKING_ISSUE_MARKER")"
	if ! listing="$(gh api --paginate \
		"repos/${GITHUB_REPOSITORY}/issues?state=open&per_page=100" \
		--jq "$filter")"; then
		log_error "Could not list every open issue in ${GITHUB_REPOSITORY}"
		exit 2
	fi
	while IFS= read -r number; do
		[[ -z "$number" ]] && continue
		if [[ ! "$number" =~ ^[0-9]+$ ]]; then
			log_error "Unexpected issue listing output: ${number}"
			exit 2
		fi
		if [[ -z "$lowest" ]] || ((number < lowest)); then
			lowest="$number"
		fi
	done <<<"$listing"
	printf '%s' "$lowest"
}

# tracking_issue_close <nothing-to-close log line> <closing comment>
# Close the open tracking issue, if any. The run link is appended to the
# comment.
tracking_issue_close() {
	local clean_log="$1" comment="$2"
	local number
	number="$(tracking_issue_find)"
	if [[ -z "$number" ]]; then
		log_info "$clean_log"
		return 0
	fi
	gh issue close "$number" \
		--repo "$GITHUB_REPOSITORY" \
		--reason completed \
		--comment "${comment} Closed by $(tracking_issue_run_url)." >/dev/null
	log_success "Closed tracking issue #${number}"
}

# tracking_issue_upsert <body file> <subject>
# Open the tracking issue with the body, or replace the open one's body when
# it differs and comment that "the <subject> changed". An identical body is
# left alone, so an unchanged result never adds noise.
tracking_issue_upsert() {
	local body_file="$1" subject="$2"
	local number current
	# Unset under `set -u` would abort with status 1, which callers read as
	# "the check found a difference".
	if [[ -z "${TRACKING_ISSUE_TITLE:-}" || -z "${TRACKING_ISSUE_NAME:-}" ]]; then
		log_error "TRACKING_ISSUE_TITLE and TRACKING_ISSUE_NAME are required"
		exit 2
	fi
	if [[ ! -s "$body_file" ]]; then
		log_error "The ${TRACKING_ISSUE_CHECK:-check} wrote no issue body; no issue was changed"
		exit 2
	fi
	number="$(tracking_issue_find)"
	if [[ -z "$number" ]]; then
		gh issue create \
			--repo "$GITHUB_REPOSITORY" \
			--title "$TRACKING_ISSUE_TITLE" \
			--body-file "$body_file" >/dev/null
		log_success "Opened the ${TRACKING_ISSUE_NAME} tracking issue"
		return 0
	fi
	if ! current="$(gh issue view "$number" --repo "$GITHUB_REPOSITORY" --json body --jq .body)"; then
		log_error "Could not read tracking issue #${number}"
		exit 2
	fi
	if [[ "$current" == "$(cat "$body_file")" ]]; then
		log_info "Tracking issue #${number} already lists this ${subject}"
		return 0
	fi
	gh issue edit "$number" --repo "$GITHUB_REPOSITORY" --body-file "$body_file" >/dev/null
	gh issue comment "$number" \
		--repo "$GITHUB_REPOSITORY" \
		--body "The ${subject} changed; the issue body lists it as of $(tracking_issue_run_url)." >/dev/null
	log_success "Updated tracking issue #${number}"
}
