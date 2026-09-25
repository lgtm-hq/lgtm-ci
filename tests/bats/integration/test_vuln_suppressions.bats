#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for check-vuln-suppressions.sh

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/security/check-vuln-suppressions.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
	export SCRIPT
	export GH_TOKEN="fake-token"
	export GITHUB_REPOSITORY="test-org/test-repo"
	export GITHUB_SERVER_URL="https://github.com"
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

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

mock_osv_probe() {
	local probe_json="$1"
	mock_command_multi "osv-scanner" "
		*scan*) printf '%s' '$probe_json';;
		*) exit 1;;
	"
}

run_check_script() {
	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_WORKSPACE='$MOCK_GIT_REPO'
		export GH_TOKEN='$GH_TOKEN'
		export CLEANUP_PR_LABELS='${CLEANUP_PR_LABELS-security,dependencies,automation}'
		export PATH='$PATH'
		'$SCRIPT' 2>&1
	"
}

@test "vuln-suppressions: exits cleanly when config file is missing" {
	setup_mock_git_repo
	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_WORKSPACE='$MOCK_GIT_REPO'
		export GH_TOKEN='$GH_TOKEN'
		'$SCRIPT' 2>&1
	"
	assert_success
	assert_output --partial "Nothing to check"
}

@test "vuln-suppressions: exits cleanly when all suppressions are active" {
	setup_suppression_repo
	cat >"$MOCK_GIT_REPO/.osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-active-1111"
ignoreUntil = 2099-12-31
reason = "still present"
EOF
	(
		cd "$MOCK_GIT_REPO" || exit 1
		git add .osv-scanner.toml
		git commit -q --amend --no-edit
	)

	mock_osv_probe '{"results":[{"packages":[{"vulnerabilities":[{"id":"GHSA-active-1111"}]}]}]}'

	run_check_script
	assert_success
	assert_output --partial "All suppressions are active"
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

# Write a TOML with a single stale suppression and commit it.
write_stale_only_toml() {
	cat >"$MOCK_GIT_REPO/.osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-stale-2222"
ignoreUntil = 2099-12-31
reason = "resolved upstream"
EOF
	(
		cd "$MOCK_GIT_REPO" || exit 1
		git add .osv-scanner.toml
		git commit -q --amend --no-edit
	)
}

# Write a TOML with one stale and one active suppression and commit it, so the
# cleanup edits the file instead of removing it.
write_stale_and_active_toml() {
	cat >"$MOCK_GIT_REPO/.osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-stale-2222"
ignoreUntil = 2099-12-31
reason = "resolved upstream"

[[IgnoredVulns]]
id = "GHSA-active-1111"
ignoreUntil = 2099-12-31
reason = "still present"
EOF
	(
		cd "$MOCK_GIT_REPO" || exit 1
		git add .osv-scanner.toml
		git commit -q --amend --no-edit
	)
}

_commit_input() {
	jq -c '.variables.input' "$MOCK_GH_GRAPHQL_PAYLOAD"
}

@test "vuln-suppressions: removes stale suppressions via cleanup PR" {
	setup_suppression_repo
	write_stale_only_toml

	mock_osv_probe '{"results":[{"packages":[{"vulnerabilities":[]}]}]}'
	mock_gh_for_cleanup_pr "https://github.com/test-org/test-repo/pull/42"

	run_check_script
	assert_success
	assert_output --partial "Cleanup PR created"
	assert_output --partial "https://github.com/test-org/test-repo/pull/42"

	[[ ! -f "$MOCK_GIT_REPO/.osv-scanner.toml" ]] || ! grep -q 'GHSA-stale-2222' "$MOCK_GIT_REPO/.osv-scanner.toml"
}

@test "vuln-suppressions: commits an edited TOML through create-signed-commit reset mode" {
	setup_suppression_repo
	write_stale_and_active_toml
	local head_before
	head_before=$(git -C "$MOCK_GIT_REPO" rev-parse HEAD)

	mock_osv_probe '{"results":[{"packages":[{"vulnerabilities":[{"id":"GHSA-active-1111"}]}]}]}'
	mock_gh_for_cleanup_pr "https://github.com/test-org/test-repo/pull/50"

	run_check_script
	assert_success
	assert_output --partial "Created signed commit abc123abc123abc123abc123abc123abc123abc1"

	# Reset mode: the commit is made on a temporary branch created at the
	# default branch head, then the cleanup branch is created at the commit.
	[ "$(_commit_input | jq -r '.expectedHeadOid')" = "$BASE_SHA" ]
	[ "$(_commit_input | jq -r '.branch.repositoryNameWithOwner')" = "test-org/test-repo" ]
	[[ "$(_commit_input | jq -r '.branch.branchName')" == signed-commit-tmp/* ]]
	[ "$(_commit_input | jq -r '.message.headline')" = "chore(security): remove stale vulnerability suppressions" ]
	[[ "$(_commit_input | jq -r '.message.body')" == *'GHSA-stale-2222'* ]]
	[ "$(_commit_input | jq -r '.fileChanges.additions | length')" = "1" ]
	[ "$(_commit_input | jq -r '.fileChanges.additions[0].path')" = ".osv-scanner.toml" ]
	[ "$(_commit_input | jq -r '.fileChanges | has("deletions")')" = "false" ]
	_commit_input | jq -r '.fileChanges.additions[0].contents' | base64 -d | grep -q 'GHSA-active-1111'
	run bash -c "jq -r '.variables.input.fileChanges.additions[0].contents' '$MOCK_GH_GRAPHQL_PAYLOAD' | base64 -d | grep -q 'GHSA-stale-2222'"
	assert_failure

	run grep -E "git/refs -f ref=refs/heads/chore/remove-stale-vulns-[0-9]{14}-[A-Za-z0-9]+-[0-9]+-[0-9]+ -f sha=abc123abc123abc123abc123abc123abc123abc1" "$MOCK_GH_LOG"
	assert_success
	run grep -E "pr create --repo test-org/test-repo --head chore/remove-stale-vulns-[0-9]{14}-[A-Za-z0-9]+-[0-9]+-[0-9]+ --base main" "$MOCK_GH_LOG"
	assert_success

	# Nothing is committed or pushed with the git CLI.
	[ "$(git -C "$MOCK_GIT_REPO" rev-parse HEAD)" = "$head_before" ]
	run git -C "${BATS_TEST_TMPDIR}/bare.git" for-each-ref --format='%(refname)' 'refs/heads/chore/'
	assert_success
	assert_output ""
}

@test "vuln-suppressions: deletes the TOML through create-signed-commit when nothing remains" {
	setup_suppression_repo
	write_stale_only_toml

	mock_osv_probe '{"results":[{"packages":[{"vulnerabilities":[]}]}]}'
	mock_gh_for_cleanup_pr "https://github.com/test-org/test-repo/pull/51"

	run_check_script
	assert_success

	[ "$(_commit_input | jq -r '.fileChanges.deletions[0].path')" = ".osv-scanner.toml" ]
	[ "$(_commit_input | jq -r '.fileChanges | has("additions")')" = "false" ]
}

@test "vuln-suppressions: aborts before any write when the default branch changed the TOML" {
	setup_suppression_repo
	write_stale_only_toml

	mock_osv_probe '{"results":[{"packages":[{"vulnerabilities":[]}]}]}'
	mock_gh_for_cleanup_pr
	export MOCK_CONTENTS_SHA="0000000000000000000000000000000000000000"

	run_check_script
	assert_failure
	assert_output --partial "differs from the checked-out version"

	run grep -E "graphql|git/refs|pr create" "$MOCK_GH_LOG"
	assert_failure
}

@test "vuln-suppressions: adds each cleanup label separately after the PR exists" {
	setup_suppression_repo
	write_stale_only_toml

	mock_osv_probe '{"results":[{"packages":[{"vulnerabilities":[]}]}]}'
	mock_gh_for_cleanup_pr "https://github.com/test-org/test-repo/pull/55"

	run_check_script
	assert_success

	run grep -F "pr create" "$MOCK_GH_LOG"
	assert_success
	refute_output --partial "--label"

	local pr_edit="pr edit https://github.com/test-org/test-repo/pull/55 --repo test-org/test-repo --add-label"
	grep -qxF "${pr_edit} security" "$MOCK_GH_LOG"
	grep -qxF "${pr_edit} dependencies" "$MOCK_GH_LOG"
	grep -qxF "${pr_edit} automation" "$MOCK_GH_LOG"
	run grep -F -- "--add-label security,dependencies,automation" "$MOCK_GH_LOG"
	assert_failure

	# PR is created before any label is applied.
	local create_line edit_line
	create_line=$(grep -n "pr create" "$MOCK_GH_LOG" | head -1 | cut -d: -f1)
	edit_line=$(grep -n "pr edit" "$MOCK_GH_LOG" | head -1 | cut -d: -f1)
	((create_line < edit_line))
}

@test "vuln-suppressions: a missing label still produces the PR and only warns" {
	setup_suppression_repo
	write_stale_only_toml

	mock_osv_probe '{"results":[{"packages":[{"vulnerabilities":[]}]}]}'
	mock_gh_for_cleanup_pr "https://github.com/test-org/test-repo/pull/57"
	export MOCK_MISSING_LABELS="automation"

	run_check_script
	assert_success
	assert_output --partial "Could not add label 'automation'"
	assert_output --partial "Cleanup PR created"

	# The other labels are still applied and the branch is kept.
	grep -qF -- "--add-label security" "$MOCK_GH_LOG"
	grep -qF -- "--add-label dependencies" "$MOCK_GH_LOG"
	run grep -F -- "-X DELETE repos/test-org/test-repo/git/refs/heads/chore/" "$MOCK_GH_LOG"
	assert_failure
}

@test "vuln-suppressions: creates unlabeled cleanup PR when labels are empty" {
	setup_suppression_repo
	write_stale_only_toml

	mock_osv_probe '{"results":[{"packages":[{"vulnerabilities":[]}]}]}'
	mock_gh_for_cleanup_pr "https://github.com/test-org/test-repo/pull/56"

	run bash -c "
		cd '$MOCK_GIT_REPO'
		export GITHUB_WORKSPACE='$MOCK_GIT_REPO'
		export GH_TOKEN='$GH_TOKEN'
		export CLEANUP_PR_LABELS=''
		export PATH='$PATH'
		'$SCRIPT' 2>&1
	"
	assert_success
	assert_output --partial "Cleanup PR created"

	run grep -F "pr create" "$MOCK_GH_LOG"
	assert_success
	run grep -E -- "--label|--add-label|pr edit" "$MOCK_GH_LOG"
	assert_failure
}

@test "vuln-suppressions: PR creation failure deletes the branch and exits non-zero" {
	setup_suppression_repo
	write_stale_only_toml

	mock_osv_probe '{"results":[{"packages":[{"vulnerabilities":[]}]}]}'
	mock_gh_for_cleanup_pr
	export MOCK_PR_CREATE_FAIL=true

	run_check_script
	assert_failure
	assert_output --partial "Failed to create the cleanup PR"
	refute_output --partial "Cleanup PR created"

	run grep -E -- "-X DELETE repos/test-org/test-repo/git/refs/heads/chore/remove-stale-vulns-[0-9]{14}-[A-Za-z0-9]+-[0-9]+-[0-9]+$" "$MOCK_GH_LOG"
	assert_success
	run grep -F "pr edit" "$MOCK_GH_LOG"
	assert_failure

	grep -qF "Stale vulnerability suppression cleanup failed" "$GITHUB_STEP_SUMMARY"
	grep -qE 'chore/remove-stale-vulns-[0-9]{14}-[A-Za-z0-9]+-[0-9]+-[0-9]+` \(deleted\)' "$GITHUB_STEP_SUMMARY"
}

@test "vuln-suppressions: PR creation failure surfaces a compare URL when the branch cannot be deleted" {
	setup_suppression_repo
	write_stale_only_toml

	mock_osv_probe '{"results":[{"packages":[{"vulnerabilities":[]}]}]}'
	mock_gh_for_cleanup_pr
	export MOCK_PR_CREATE_FAIL=true
	export MOCK_DELETE_FAIL=true

	run_check_script
	assert_failure
	assert_output --partial "Could not delete branch"

	grep -qE 'chore/remove-stale-vulns-[0-9]{14}-[A-Za-z0-9]+-[0-9]+-[0-9]+` \(left in place\)' "$GITHUB_STEP_SUMMARY"
	grep -qE 'https://github.com/test-org/test-repo/compare/main\.\.\.chore/remove-stale-vulns-[0-9]{14}-[A-Za-z0-9]+-[0-9]+-[0-9]+\?expand=1' "$GITHUB_STEP_SUMMARY"
}

@test "vuln-suppressions: keeps the branch when the create error cannot be checked" {
	setup_suppression_repo
	write_stale_only_toml

	mock_osv_probe '{"results":[{"packages":[{"vulnerabilities":[]}]}]}'
	mock_gh_for_cleanup_pr
	export MOCK_PR_CREATE_FAIL=true
	export MOCK_PR_LIST_HEAD_FAIL=true

	run_check_script
	assert_failure
	assert_output --partial "also failed; leaving the branch in place"

	run grep -F -- "-X DELETE repos/test-org/test-repo/git/refs/heads/chore/" "$MOCK_GH_LOG"
	assert_failure
	grep -qE 'chore/remove-stale-vulns-[0-9]{14}-[A-Za-z0-9]+-[0-9]+-[0-9]+` \(left in place\)' "$GITHUB_STEP_SUMMARY"
}

@test "vuln-suppressions: refuses an absolute suppression path before any write" {
	setup_suppression_repo
	write_stale_only_toml

	mock_osv_probe '{"results":[{"packages":[{"vulnerabilities":[]}]}]}'
	mock_gh_for_cleanup_pr
	export CONFIG_PATH="$MOCK_GIT_REPO/.osv-scanner.toml"

	run_check_script
	assert_failure
	assert_output --partial "must be a plain repo-relative path"

	run grep -E "graphql|git/refs|pr create" "$MOCK_GH_LOG"
	assert_failure
}

@test "vuln-suppressions: keeps the branch when the PR exists despite a create error" {
	setup_suppression_repo
	write_stale_only_toml

	mock_osv_probe '{"results":[{"packages":[{"vulnerabilities":[]}]}]}'
	mock_gh_for_cleanup_pr
	export MOCK_PR_CREATE_FAIL=true
	export MOCK_PR_AFTER_FAIL="https://github.com/test-org/test-repo/pull/58"

	run_check_script
	assert_success
	assert_output --partial "Cleanup PR created"

	run grep -F -- "-X DELETE repos/test-org/test-repo/git/refs/heads/chore/" "$MOCK_GH_LOG"
	assert_failure
	grep -qF "pr edit https://github.com/test-org/test-repo/pull/58" "$MOCK_GH_LOG"
}

@test "vuln-suppressions: script never commits or pushes with the git CLI" {
	run grep -nE '(^|[[:space:];&|(])git[[:space:]]+(commit|push|checkout)([[:space:]]|$)|configure_git_ci_user' "$SCRIPT"
	assert_failure
}

@test "vuln-suppressions: flags expired-only for review without a PR and exits 1" {
	setup_suppression_repo
	cat >"$MOCK_GIT_REPO/.osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-expired-3333"
ignoreUntil = 2020-01-01
reason = "past due"
EOF
	(
		cd "$MOCK_GIT_REPO" || exit 1
		git add .osv-scanner.toml
		git commit -q --amend --no-edit
	)

	mock_osv_probe '{"results":[{"packages":[{"vulnerabilities":[{"id":"GHSA-expired-3333"}]}]}]}'
	mock_gh_for_cleanup_pr "https://github.com/test-org/test-repo/pull/43"

	run_check_script
	assert_failure
	assert_output --partial "Expired suppression(s) require manual review"
	assert_output --partial "GHSA-expired-3333 (ignoreUntil 2020-01-01)"
	refute_output --partial "Cleanup PR created"

	# Expired entry is left untouched in the TOML.
	grep -q 'GHSA-expired-3333' "$MOCK_GIT_REPO/.osv-scanner.toml"

	# No cleanup PR is opened for an expired-only run.
	local calls
	calls=$(cat "$BATS_TEST_TMPDIR/mock_calls_gh")
	[[ "$calls" != *"pr create"* ]]
}

@test "vuln-suppressions: removes only stale in cleanup PR, retains expired, exits 1" {
	setup_suppression_repo
	cat >"$MOCK_GIT_REPO/.osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-stale-2222"
ignoreUntil = 2099-12-31
reason = "resolved upstream"

[[IgnoredVulns]]
id = "GHSA-expired-3333"
ignoreUntil = 2020-01-01
reason = "past due"
EOF
	(
		cd "$MOCK_GIT_REPO" || exit 1
		git add .osv-scanner.toml
		git commit -q --amend --no-edit
	)

	mock_osv_probe '{"results":[{"packages":[{"vulnerabilities":[{"id":"GHSA-expired-3333"}]}]}]}'
	mock_gh_for_cleanup_pr "https://github.com/test-org/test-repo/pull/44"

	run_check_script
	assert_failure
	assert_output --partial "Cleanup PR created"
	assert_output --partial "Expired suppression(s) require manual review"

	# Stale entry removed, expired entry retained.
	run grep -q 'GHSA-stale-2222' "$MOCK_GIT_REPO/.osv-scanner.toml"
	assert_failure
	grep -q 'GHSA-expired-3333' "$MOCK_GIT_REPO/.osv-scanner.toml"
}

@test "vuln-suppressions: skips when cleanup PR already open for stale-only" {
	setup_suppression_repo
	cat >"$MOCK_GIT_REPO/.osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-stale-2222"
ignoreUntil = 2099-12-31
reason = "resolved upstream"
EOF
	(
		cd "$MOCK_GIT_REPO" || exit 1
		git add .osv-scanner.toml
		git commit -q --amend --no-edit
	)

	mock_osv_probe '{"results":[{"packages":[{"vulnerabilities":[]}]}]}'
	mock_command_multi "gh" '
		*pr\ list*) echo -n "99";;
		*) exit 1;;
	'

	run_check_script
	assert_success
	assert_output --partial "Cleanup PR #99 already open"
}

@test "vuln-suppressions: flags expired for review even when a cleanup PR is open" {
	setup_suppression_repo
	cat >"$MOCK_GIT_REPO/.osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-stale-2222"
ignoreUntil = 2099-12-31
reason = "resolved upstream"

[[IgnoredVulns]]
id = "GHSA-expired-4444"
ignoreUntil = 2020-01-01
reason = "past due"
EOF
	(
		cd "$MOCK_GIT_REPO" || exit 1
		git add .osv-scanner.toml
		git commit -q --amend --no-edit
	)

	mock_osv_probe '{"results":[{"packages":[{"vulnerabilities":[{"id":"GHSA-expired-4444"}]}]}]}'
	mock_command_multi "gh" '
		*pr\ list*) echo -n "99";;
		*) exit 1;;
	'

	run_check_script
	assert_failure
	assert_output --partial "Cleanup PR #99 already open"
	assert_output --partial "Expired suppression(s) require manual review"
	assert_output --partial "GHSA-expired-4444 (ignoreUntil 2020-01-01)"

	# Nothing removed when a cleanup PR is already open.
	grep -q 'GHSA-stale-2222' "$MOCK_GIT_REPO/.osv-scanner.toml"
	grep -q 'GHSA-expired-4444' "$MOCK_GIT_REPO/.osv-scanner.toml"
}
