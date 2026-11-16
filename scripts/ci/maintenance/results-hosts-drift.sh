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
#      unreadable preset, no Python 3.11 or newer): exit 2 without touching
#      any issue; the log line keeps the original status.
#
# Exit status: 0 match, 1 drift found, 2 error. Nothing else: a checker or
# interpreter status other than 0 and 1 (69 from lib/python.sh included)
# is reported as 2.
#
# The tracking issue is the lowest-numbered open issue opened by
# github-actions[bot] whose body carries TRACKING_ISSUE_MARKER; finding,
# opening, updating and closing it live in lib/github/tracking_issue.sh.
#
# Required environment variables:
#   GH_TOKEN          - GitHub token with issues: write on GITHUB_REPOSITORY
#   GITHUB_REPOSITORY - Repository that holds the tracking issue (owner/name)
#
# Optional environment variables:
#   META_FILE         - Read /meta from this file instead of `gh api meta`
#   PYTHON            - Python interpreter (default: python3; 3.11 or
#                       newer, see lib/python.sh)
#   GITHUB_SERVER_URL, GITHUB_RUN_ID - used for the run link in comments

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"
# shellcheck source=../lib/github/tracking_issue.sh
source "$SCRIPT_DIR/../lib/github/tracking_issue.sh"
# shellcheck source=../lib/python.sh
source "$SCRIPT_DIR/../lib/python.sh"

readonly TRACKING_ISSUE_MARKER="<!-- lgtm-ci:results-hosts-drift -->"
readonly TRACKING_ISSUE_TITLE="fix(egress): GitHub results storage hosts differ from /meta"
readonly TRACKING_ISSUE_NAME="results storage hosts"
readonly TRACKING_ISSUE_CHECK="drift check"
readonly CHECK_SCRIPT="$SCRIPT_DIR/check-results-hosts-drift.py"

if [[ -z "${GH_TOKEN:-}" ]]; then
	log_error "GH_TOKEN is required"
	exit 2
fi
if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
	log_error "GITHUB_REPOSITORY is required"
	exit 2
fi

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

	# An interpreter older than 3.11 exits 69: the error branch (exit 2),
	# never drift.
	run_python "$CHECK_SCRIPT" --meta "$meta" --issue-body "$body" || status=$?
	case "$status" in
	0)
		tracking_issue_close \
			"Results storage hosts match /meta; no tracking issue to close" \
			"The results storage hosts in \`/meta\` match \`egress_github_results_storage_endpoints\` again."
		;;
	1)
		tracking_issue_upsert "$body" difference
		log_error "Results storage hosts differ from /meta; see the tracking issue"
		exit 1
		;;
	*)
		log_error "Drift check failed closed (exit ${status}); no issue was changed"
		exit 2
		;;
	esac
}

main "$@"
