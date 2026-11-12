#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Compare GitHub's /meta results storage hosts with the egress presets
# and keep one tracking issue in step with the result (#1498).
#
# Steps:
#   1. Fetch GET /meta with `gh api meta`.
#   2. Run check-results-hosts-drift.py against it.
#   3. Match: close the open tracking issue, if any. Difference: open the
#      tracking issue, or update its body when the difference changed, then
#      exit 1 so the scheduled run is red. Error (unrecognised /meta shape,
#      unreadable preset): exit non-zero without touching any issue.
#
# The tracking issue is the lowest-numbered open issue opened by
# github-actions[bot] whose body carries ISSUE_MARKER. Every page of the
# issues API is read (not the search index, which lags).
#
# Required environment variables:
#   GH_TOKEN          - GitHub token with issues: write on GITHUB_REPOSITORY
#   GITHUB_REPOSITORY - Repository that holds the tracking issue (owner/name)
#
# Optional environment variables:
#   META_FILE         - Read /meta from this file instead of `gh api meta`
#   PYTHON            - Python interpreter (default: python3)
#   GITHUB_SERVER_URL, GITHUB_RUN_ID - used for the run link in comments

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"

readonly ISSUE_MARKER="<!-- lgtm-ci:results-hosts-drift -->"
readonly ISSUE_TITLE="fix(egress): GitHub results storage hosts differ from /meta"
readonly CHECK_SCRIPT="$SCRIPT_DIR/check-results-hosts-drift.py"
# The login GitHub shows for issues opened with GITHUB_TOKEN.
readonly ISSUE_AUTHOR="github-actions[bot]"

if [[ -z "${GH_TOKEN:-}" ]]; then
	log_error "GH_TOKEN is required"
	exit 2
fi
if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
	log_error "GITHUB_REPOSITORY is required"
	exit 2
fi

run_url() {
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
# (ISSUE_AUTHOR, a Bot) counts, so nobody else can plant the marker. The
# lowest matching number wins. Any listing error or unexpected output exits
# 2 before a write, so a transient API error never opens a duplicate.
find_tracking_issue() {
	local filter listing number lowest=""
	# The marker and author contain no `"` or `\`, so they embed verbatim.
	filter="$(printf '.[] | select(.pull_request == null and .user.login == "%s" and .user.type == "Bot" and ((.body // "") | contains("%s"))) | .number' \
		"$ISSUE_AUTHOR" "$ISSUE_MARKER")"
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

close_tracking_issue() {
	local number
	number="$(find_tracking_issue)"
	if [[ -z "$number" ]]; then
		log_info "Results storage hosts match /meta; no tracking issue to close"
		return 0
	fi
	gh issue close "$number" \
		--repo "$GITHUB_REPOSITORY" \
		--reason completed \
		--comment "The results storage hosts in \`/meta\` match \`egress_github_results_storage_endpoints\` again. Closed by $(run_url)." >/dev/null
	log_success "Closed tracking issue #${number}"
}

upsert_tracking_issue() {
	local body_file="$1"
	local number current
	if [[ ! -s "$body_file" ]]; then
		log_error "The drift check wrote no issue body; no issue was changed"
		exit 2
	fi
	number="$(find_tracking_issue)"
	if [[ -z "$number" ]]; then
		gh issue create \
			--repo "$GITHUB_REPOSITORY" \
			--title "$ISSUE_TITLE" \
			--body-file "$body_file" >/dev/null
		log_success "Opened the results storage hosts tracking issue"
		return 0
	fi
	if ! current="$(gh issue view "$number" --repo "$GITHUB_REPOSITORY" --json body --jq .body)"; then
		log_error "Could not read tracking issue #${number}"
		exit 2
	fi
	if [[ "$current" == "$(cat "$body_file")" ]]; then
		log_info "Tracking issue #${number} already lists this difference"
		return 0
	fi
	gh issue edit "$number" --repo "$GITHUB_REPOSITORY" --body-file "$body_file" >/dev/null
	gh issue comment "$number" \
		--repo "$GITHUB_REPOSITORY" \
		--body "The difference changed; the issue body lists it as of $(run_url)." >/dev/null
	log_success "Updated tracking issue #${number}"
}

main() {
	local workdir meta body status=0
	workdir="$(mktemp -d)"
	# shellcheck disable=SC2064 # expand now: workdir is local
	trap "rm -rf '$workdir'" EXIT
	meta="${META_FILE:-$workdir/meta.json}"
	body="$workdir/issue-body.md"

	if [[ -z "${META_FILE:-}" ]]; then
		if ! gh api meta >"$meta"; then
			log_error "Could not fetch GET /meta"
			exit 2
		fi
	fi

	"${PYTHON:-python3}" "$CHECK_SCRIPT" --meta "$meta" --issue-body "$body" || status=$?
	case "$status" in
	0)
		close_tracking_issue
		;;
	1)
		upsert_tracking_issue "$body"
		log_error "Results storage hosts differ from /meta; see the tracking issue"
		exit 1
		;;
	*)
		log_error "Drift check failed closed (exit ${status}); no issue was changed"
		exit "$status"
		;;
	esac
}

main "$@"
