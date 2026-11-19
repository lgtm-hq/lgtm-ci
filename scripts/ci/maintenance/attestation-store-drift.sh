#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Check that GitHub still serves attestation bundles from the host
# the release-recover preset allows, and keep one tracking issue in step with
# the result (#1644).
#
# Steps:
#   1. Fetch the latest release of SUBJECT_REPO and the attestations of up
#      to MAX_SUBJECTS of its assets (by asset name), by sha256 digest, with
#      `gh api`. Only api.github.com is reached: the bundles themselves are
#      never downloaded.
#   2. Run check-attestation-store-host.py on those answers.
#   3. Match: close the open tracking issue, if any. Mismatch: open the
#      tracking issue, or update its body when the mismatch changed, then
#      exit 1 so the scheduled run is red. Error (an API call failed, no
#      asset with a digest, an unrecognised answer, no Python 3.11 or
#      newer): exit 2 without touching any issue.
#
# Exit status: 0 match, 1 mismatch, 2 error. Nothing else: a checker or
# interpreter status other than 0 and 1 (69 from lib/python.sh included)
# is reported as 2.
#
# Required environment variables:
#   GH_TOKEN          - GitHub token with issues: write on GITHUB_REPOSITORY;
#                       it reads SUBJECT_REPO's public release and
#                       attestations, which need no extra permission
#   GITHUB_REPOSITORY - Repository that holds the tracking issue (owner/name)
#
# Optional environment variables:
#   SUBJECT_REPO      - Public repository whose release assets carry GitHub
#                       artifact attestations (default: cli/cli, the GitHub
#                       CLI, which attests every release asset)
#   MAX_SUBJECTS      - Assets to check (default: 3)
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

readonly TRACKING_ISSUE_MARKER="<!-- lgtm-ci:attestation-store-host -->"
readonly TRACKING_ISSUE_TITLE="fix(egress): attestation bundle host differs from the release-recover preset"
readonly TRACKING_ISSUE_NAME="attestation store host"
readonly TRACKING_ISSUE_CHECK="attestation store check"
readonly CHECK_SCRIPT="$SCRIPT_DIR/check-attestation-store-host.py"
readonly REPO_SHAPE='^[A-Za-z0-9][A-Za-z0-9_-]*/[A-Za-z0-9._-]+$'
readonly DIGEST_SHAPE='^sha256:[0-9a-f]{64}$'

if [[ -z "${GH_TOKEN:-}" ]]; then
	log_error "GH_TOKEN is required"
	exit 2
fi
if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
	log_error "GITHUB_REPOSITORY is required"
	exit 2
fi
SUBJECT_REPO="${SUBJECT_REPO:-cli/cli}"
MAX_SUBJECTS="${MAX_SUBJECTS:-3}"
if [[ ! "$SUBJECT_REPO" =~ $REPO_SHAPE ]]; then
	log_error "SUBJECT_REPO is not owner/name: ${SUBJECT_REPO}"
	exit 2
fi
if [[ ! "$MAX_SUBJECTS" =~ ^[1-9][0-9]?$ ]]; then
	log_error "MAX_SUBJECTS must be a number from 1 to 99: ${MAX_SUBJECTS}"
	exit 2
fi

main() {
	local workdir release body digest n=0 status=0
	local -a answers=()
	workdir="$(mktemp -d)"
	# shellcheck disable=SC2064 # expand now: workdir is local
	trap "rm -rf '$workdir'" EXIT
	release="$workdir/release.json"
	body="$workdir/issue-body.md"

	if ! gh api "repos/${SUBJECT_REPO}/releases/latest" >"$release"; then
		log_error "Could not fetch the latest release of ${SUBJECT_REPO}"
		exit 2
	fi
	while IFS= read -r digest; do
		[[ -n "$digest" ]] || continue
		if [[ ! "$digest" =~ $DIGEST_SHAPE ]]; then
			log_error "Unexpected asset digest: ${digest}"
			exit 2
		fi
		n=$((n + 1))
		if ! gh api "repos/${SUBJECT_REPO}/attestations/${digest}" >"$workdir/attestations-$n.json"; then
			log_error "Could not fetch the attestations of ${SUBJECT_REPO} ${digest}"
			exit 2
		fi
		answers+=("$workdir/attestations-$n.json")
		((n < MAX_SUBJECTS)) || break
	done < <(jq -r '[.assets[]? | select((.digest // "") | startswith("sha256:"))]
		| sort_by(.name) | .[].digest' "$release")
	if ((${#answers[@]} == 0)); then
		log_error "The latest release of ${SUBJECT_REPO} has no asset with a sha256 digest"
		exit 2
	fi

	# An interpreter older than 3.11 exits 69: the error branch (exit 2),
	# never a mismatch.
	run_python "$CHECK_SCRIPT" --release "$release" --subject-repo "$SUBJECT_REPO" \
		--issue-body "$body" --attestations "${answers[@]}" || status=$?
	case "$status" in
	0)
		tracking_issue_close \
			"Attestation bundles are on the allowed host; no tracking issue to close" \
			"Every attestation \`bundle_url\` is on the host \`egress_github_attestation_store_endpoints\` allows again."
		;;
	1)
		tracking_issue_upsert "$body" mismatch
		log_error "Attestation bundle host differs from the release-recover preset; see the tracking issue"
		exit 1
		;;
	*)
		log_error "Attestation store check failed closed (exit ${status}); no issue was changed"
		exit 2
		;;
	esac
}

main "$@"
