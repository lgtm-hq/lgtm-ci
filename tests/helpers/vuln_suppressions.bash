#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Shared helpers for the check-vuln-suppressions.sh integration suites
# (test_vuln_suppressions.bats and test_vuln_suppressions_fail_closed.bats):
# a committed suppression repository, osv-scanner and gh mocks, and a runner
# for the real script. Load after common, mocks and github_env.

setup_suppression_repo() {
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO" || exit 1
		printf '' >.osv-scanner.toml
		git add .osv-scanner.toml
		git commit -q -m "chore: add suppressions"
		local bare_dir="${BATS_TEST_TMPDIR}/bare.git"
		git init -q --bare "$bare_dir"
		git -C "$bare_dir" config receive.denyCurrentBranch ignore
		git remote add origin "$bare_dir"
		git push -q origin HEAD:main 2>/dev/null
	)
}

# Print osv-scanner 2.7.1 JSON reporting each argument as a present
# vulnerability (one package and one group per ID); no argument is a clean
# scan. The shape is what `osv-scanner scan --recursive --format json` prints.
probe_json() {
	local packages="" id
	for id in "$@"; do
		packages+="${packages:+,}{\"package\":{\"name\":\"pkg\",\"version\":\"1.0.0\",\"ecosystem\":\"npm\"},\"vulnerabilities\":[{\"id\":\"${id}\"}],\"groups\":[{\"ids\":[\"${id}\"],\"aliases\":[\"${id}\"],\"max_severity\":\"\"}]}"
	done
	if [[ -z "$packages" ]]; then
		printf '{"results":[]}'
		return
	fi
	printf '{"results":[{"source":{"path":"/repo/package-lock.json","type":"lockfile"},"packages":[%s]}]}' "$packages"
}

# osv-scanner mock: every scan prints <json> on stdout and <stderr> on stderr
# and exits <status>. The default status is the one osv-scanner 2.7.1 uses:
# 1 when the JSON reports a vulnerability, otherwise 0.
# Usage: mock_osv_probe <json> [status] [stderr]
mock_osv_probe() {
	local probe_json="$1" status="${2:-}" stderr="${3:-}"
	if [[ -z "$status" ]]; then
		status=0
		[[ "$probe_json" != *'"vulnerabilities"'* ]] || status=1
	fi
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	printf '%s' "$probe_json" >"${BATS_TEST_TMPDIR}/probe.json"
	printf '%s' "$stderr" >"${BATS_TEST_TMPDIR}/probe.stderr"
	cat >"${mock_bin}/osv-scanner" <<EOF
#!/usr/bin/env bash
case " \$* " in
*" scan "*)
	cat '${BATS_TEST_TMPDIR}/probe.json'
	cat '${BATS_TEST_TMPDIR}/probe.stderr' >&2
	exit ${status}
	;;
esac
exit 1
EOF
	chmod +x "${mock_bin}/osv-scanner"
	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

# Optional first argument: bats' expected-status flag, e.g. -127, for runs
# that end in a scanner error.
run_check_script() {
	run "$@" bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_WORKSPACE='$MOCK_GIT_REPO'
		export GH_TOKEN='$GH_TOKEN'
		export CLEANUP_PR_LABELS='${CLEANUP_PR_LABELS-security,dependencies,automation}'
		export PATH='$PATH'
		'$SCRIPT' 2>&1
	"
}

BASE_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

# Recording gh mock covering the cleanup flow, including the gh api calls made
# by the real scripts/ci/git/create-signed-commit.sh (reset mode):
#   - pr list --search: no open cleanup PR
#   - pr list --head: MOCK_PR_AFTER_FAIL (a PR that exists despite an error);
#     exits 1 when MOCK_PR_LIST_HEAD_FAIL=true
#   - pr create: prints the PR URL, or fails when MOCK_PR_CREATE_FAIL=true
#   - pr edit --add-label: fails for labels listed in MOCK_MISSING_LABELS
#   - api repos/<repo> --jq .default_branch: main
#   - api .../branches/main: MOCK_BASE_SHA (BASE_SHA); any other branch: HTTP 404
#   - api .../contents/<path>: blob SHA of HEAD:<path> in the checkout, or
#     MOCK_CONTENTS_SHA when set
#   - api graphql: saves the payload to MOCK_GH_GRAPHQL_PAYLOAD
#   - api -X DELETE: succeeds unless MOCK_DELETE_FAIL=true
mock_gh_for_cleanup_pr() {
	local pr_url="${1:-https://github.com/test-org/test-repo/pull/1}"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	export MOCK_GH_LOG="${BATS_TEST_TMPDIR}/mock_calls_gh"
	export MOCK_GH_GRAPHQL_PAYLOAD="${BATS_TEST_TMPDIR}/graphql-payload.json"
	export MOCK_PR_URL="$pr_url"
	export MOCK_BASE_SHA="$BASE_SHA"
	: >"$MOCK_GH_LOG"

	cat >"${mock_bin}/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >>"$MOCK_GH_LOG"
args=" $* "
case "$args" in
*" pr list "*"--search"*) exit 0 ;;
*" pr list "*"--head"*)
	if [[ "${MOCK_PR_LIST_HEAD_FAIL:-false}" == "true" ]]; then
		echo "gh: Server Error (HTTP 502)" >&2
		exit 1
	fi
	[[ -n "${MOCK_PR_AFTER_FAIL:-}" ]] && echo "$MOCK_PR_AFTER_FAIL"
	exit 0
	;;
*" pr create "*)
	if [[ "${MOCK_PR_CREATE_FAIL:-false}" == "true" ]]; then
		echo "pull request create failed: GraphQL: something broke" >&2
		exit 1
	fi
	echo "$MOCK_PR_URL"
	exit 0
	;;
*" pr edit "*)
	label="${args##*--add-label }"
	label="${label%% *}"
	if [[ ",${MOCK_MISSING_LABELS:-}," == *",${label},"* ]]; then
		echo "could not add label: '${label}' not found" >&2
		exit 1
	fi
	exit 0
	;;
*" graphql "*)
	cat >"$MOCK_GH_GRAPHQL_PAYLOAD"
	echo '{"data":{"createCommitOnBranch":{"commit":{"oid":"abc123abc123abc123abc123abc123abc123abc1","url":"https://github.com/test-org/test-repo/commit/abc123"}}}}'
	exit 0
	;;
*"--jq .default_branch"*)
	echo "main"
	exit 0
	;;
*"/branches/main "*)
	echo "$MOCK_BASE_SHA"
	exit 0
	;;
*"/branches/"*)
	echo "gh: Branch not found (HTTP 404)" >&2
	exit 1
	;;
*"/contents/"*)
	if [[ -n "${MOCK_CONTENTS_SHA:-}" ]]; then
		echo "$MOCK_CONTENTS_SHA"
		exit 0
	fi
	path="${args#*/contents/}"
	path="${path%%\?*}"
	git rev-parse "HEAD:${path}"
	exit $?
	;;
*" -X DELETE "*)
	[[ "${MOCK_DELETE_FAIL:-false}" == "true" ]] && exit 1
	echo '{}'
	exit 0
	;;
*"/git/refs "*)
	echo '{}'
	exit 0
	;;
esac
echo "unexpected gh call: $*" >&2
exit 2
MOCK
	chmod +x "${mock_bin}/gh"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

_commit_input() {
	jq -c '.variables.input' "$MOCK_GH_GRAPHQL_PAYLOAD"
}

# Replace the committed suppression file with stdin (#1613).
commit_toml() {
	cat >"$MOCK_GIT_REPO/.osv-scanner.toml"
	(
		cd "$MOCK_GIT_REPO" || exit 1
		git add .osv-scanner.toml
		git commit -q --amend --no-edit
	)
}

_committed_toml() {
	_commit_input | jq -r '.fileChanges.additions[0].contents' | base64 -d
}
