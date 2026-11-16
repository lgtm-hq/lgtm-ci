#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve every egress allow-listed host the way the harden-runner
# agent does and keep one tracking issue in step with the result (#1548).
#
# Steps:
#   1. Run check-egress-dns.py: every preset host plus the allow-list entries
#      in docs/ and examples/, resolved over DNS over HTTPS (dns.google, as
#      the agent does at start-up).
#   2. Every host resolves: close the open tracking issue, if any. A host
#      fails: open the tracking issue, or update its body when the failing
#      set changed, then exit 1 so the scheduled run is red. Error (resolver
#      unreachable, unreadable presets, no Python 3.11 or newer): exit 2
#      without touching any issue; the log line keeps the original status.
#
# Exit status: 0 clean, 1 hosts fail, 2 error. Nothing else: a checker or
# interpreter status other than 0 and 1 (69 from lib/python.sh included)
# is reported as 2.
#
# EXTRA_HOSTS (the workflow_dispatch input) adds hosts to the check, so a
# maintainer can prove the failure path live with a `.invalid` name. Such a
# run only reports: it never opens, edits or closes the tracking issue, so a
# test cannot disturb the real tracker. It still exits 1 when a host fails.
#
# Required environment variables:
#   GH_TOKEN          - GitHub token with issues: write on GITHUB_REPOSITORY
#   GITHUB_REPOSITORY - Repository that holds the tracking issue (owner/name)
#
# Optional environment variables:
#   EXTRA_HOSTS        - Space-separated host:port entries; report-only run
#   DNS_RESPONSES_FILE - Replay recorded resolver answers (tests)
#   PYTHON             - Python interpreter (default: python3; 3.11 or
#                        newer, see lib/python.sh)
#   GITHUB_SERVER_URL, GITHUB_RUN_ID - used for the run link in comments

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"
# shellcheck source=../lib/github/tracking_issue.sh
source "$SCRIPT_DIR/../lib/github/tracking_issue.sh"
# shellcheck source=../lib/python.sh
source "$SCRIPT_DIR/../lib/python.sh"

readonly TRACKING_ISSUE_MARKER="<!-- lgtm-ci:egress-dns-check -->"
readonly TRACKING_ISSUE_TITLE="fix(egress): allow-listed hosts do not resolve; harden-runner would revert"
readonly TRACKING_ISSUE_NAME="egress DNS"
readonly TRACKING_ISSUE_CHECK="DNS check"
readonly CHECK_SCRIPT="$SCRIPT_DIR/check-egress-dns.py"
# A lower-case DNS name with a dot, then a port. No wildcard, no expression.
readonly EXTRA_HOST_TOKEN='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+:[0-9]{1,5}$'
readonly EXTRA_HOSTS_MAX=20

if [[ -z "${GH_TOKEN:-}" ]]; then
	log_error "GH_TOKEN is required"
	exit 2
fi
if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
	log_error "GITHUB_REPOSITORY is required"
	exit 2
fi

# Validate EXTRA_HOSTS strictly and print it normalised (single spaces).
validated_extra_hosts() {
	local token count=0 out=""
	local -a tokens
	if [[ "${EXTRA_HOSTS:-}" == *[![:alnum:].:\ -]* ]]; then
		log_error "extra-hosts holds a character other than a-z, 0-9, '.', '-', ':' or space"
		exit 2
	fi
	read -r -a tokens <<<"${EXTRA_HOSTS:-}"
	for token in "${tokens[@]}"; do
		if [[ ! "$token" =~ $EXTRA_HOST_TOKEN ]] || ((10#${token##*:} < 1 || 10#${token##*:} > 65535)); then
			log_error "extra-hosts entry is not a lower-case host:port: ${token}"
			exit 2
		fi
		count=$((count + 1))
		out+="${out:+ }${token}"
	done
	# Blank input must not fall through to the scheduled path, which writes
	# the tracking issue.
	if [[ -n "${EXTRA_HOSTS:-}" ]] && ((count == 0)); then
		log_error "extra-hosts is blank; leave it empty or give host:port entries"
		exit 2
	fi
	if ((count > EXTRA_HOSTS_MAX)); then
		log_error "extra-hosts takes at most ${EXTRA_HOSTS_MAX} entries"
		exit 2
	fi
	printf '%s' "$out"
}

# Tell the workflow how the check ended (clean, hosts-fail or error), so the
# failure notifier can skip a run whose failing hosts the tracking issue
# already reports.
report_result() {
	[[ -z "${GITHUB_OUTPUT:-}" ]] || echo "result=$1" >>"$GITHUB_OUTPUT"
}

# Run one tracking-issue function. Any failure in it (listing, reading,
# creating, editing, closing) is an error, exit 2: the result must not say
# hosts-fail or clean when the tracking issue does not show it. The subshell
# keeps errexit on inside the function; a plain `if !` would switch it off.
reconcile() {
	local rc=0
	set +e
	(
		set -e
		"$@"
	)
	rc=$?
	set -e
	if ((rc != 0)); then
		report_result error
		log_error "Could not reconcile the tracking issue (exit ${rc})"
		exit 2
	fi
}

main() {
	local workdir body extra status=0
	local -a args
	extra="$(validated_extra_hosts)"
	workdir="$(mktemp -d)"
	# shellcheck disable=SC2064 # expand now: workdir is local
	trap "rm -rf '$workdir'" EXIT
	body="$workdir/issue-body.md"

	args=(--issue-body "$body")
	[[ -z "$extra" ]] || args+=(--extra-hosts "$extra")
	[[ -z "${DNS_RESPONSES_FILE:-}" ]] || args+=(--responses "$DNS_RESPONSES_FILE")

	# The checker only reads files and queries the resolvers: it gets no token.
	# The token is cleared by assignment and by the external /usr/bin/env -u,
	# not by `unset`, which an exported function of that name could replace:
	#   - a readonly token, which no assignment can clear, is an error, found
	#     in a throwaway subshell (a failed assignment ends it non-zero);
	#   - the subshell assigns both tokens the empty string, so the version
	#     probe never sees a value, and checks they are empty;
	#   - the checker runs through /usr/bin/env -u, as before, by the absolute
	#     path require_python accepted. A function name cannot contain a
	#     slash, so /usr/bin/env is always the binary.
	# A shadowed `exit` or `return` can only make the run fail, never pass a
	# token on. Any status other than 0 and 1 (a refused interpreter exits
	# 69) lands in the error branch below and never reads as hosts-fail.
	if [[ ! -x /usr/bin/env ]]; then
		# Checked here: on bash 3.2 a missing command in the subshell below
		# would surface as status 1, which means hosts-fail.
		report_result error
		log_error "/usr/bin/env is missing; the DNS check needs it to drop the token"
		exit 2
	fi
	if ! (GH_TOKEN='' GITHUB_TOKEN='') 2>/dev/null; then
		report_result error
		log_error "GH_TOKEN or GITHUB_TOKEN is readonly; the DNS check must run without it"
		exit 2
	fi
	(
		GH_TOKEN=''
		GITHUB_TOKEN=''
		[[ -z "${GH_TOKEN}${GITHUB_TOKEN}" ]] || exit 2
		require_python || exit
		/usr/bin/env -u GH_TOKEN -u GITHUB_TOKEN \
			"$LGTM_CI_PYTHON_PATH" "$CHECK_SCRIPT" "${args[@]}"
	) || status=$?
	if [[ -n "${EXTRA_HOSTS:-}" ]]; then
		case "$status" in
		0)
			report_result clean
			log_success "Every host resolves, extra hosts included (report only)"
			;;
		1)
			report_result hosts-fail
			log_error "Hosts fail to resolve (report only: extra-hosts run, no issue changed)"
			;;
		*)
			report_result error
			log_error "DNS check failed closed (exit ${status}); no issue was changed"
			exit 2
			;;
		esac
		exit "$status"
	fi
	case "$status" in
	0)
		reconcile tracking_issue_close \
			"Every allow-listed host resolves; no tracking issue to close" \
			"Every allow-listed host resolves through DNS over HTTPS again."
		report_result clean
		;;
	1)
		reconcile tracking_issue_upsert "$body" "set of failing hosts"
		# Only now: the tracking issue really reports these hosts.
		report_result hosts-fail
		log_error "Allow-listed hosts fail to resolve; see the tracking issue"
		exit 1
		;;
	*)
		report_result error
		log_error "DNS check failed closed (exit ${status}); no issue was changed"
		exit 2
		;;
	esac
}

main "$@"
