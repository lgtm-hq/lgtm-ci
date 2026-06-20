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
		export CLEANUP_PR_LABELS='${CLEANUP_PR_LABELS:-security,dependencies,automation}'
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

mock_gh_for_cleanup_pr() {
	local pr_url="${1:-https://github.com/test-org/test-repo/pull/1}"
	mock_command_multi "gh" "
		*pr\ list*) :;;
		*pr\ create*) echo '$pr_url';;
		*) exit 1;;
	"
}

@test "vuln-suppressions: removes stale suppressions via cleanup PR" {
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
	mock_gh_for_cleanup_pr "https://github.com/test-org/test-repo/pull/42"

	run_check_script
	assert_success
	assert_output --partial "Cleanup PR created"

	[[ ! -f "$MOCK_GIT_REPO/.osv-scanner.toml" ]] || ! grep -q 'GHSA-stale-2222' "$MOCK_GIT_REPO/.osv-scanner.toml"
}

@test "vuln-suppressions: removes expired suppressions via cleanup PR" {
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
	assert_success
	assert_output --partial "Cleanup PR created"
	refute_output --partial "need manual review"

	[[ ! -f "$MOCK_GIT_REPO/.osv-scanner.toml" ]] || ! grep -q 'GHSA-expired-3333' "$MOCK_GIT_REPO/.osv-scanner.toml"
}

@test "vuln-suppressions: removes stale and expired in one cleanup PR" {
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

	mock_osv_probe '{"results":[{"packages":[{"vulnerabilities":[]}]}]}'
	mock_gh_for_cleanup_pr "https://github.com/test-org/test-repo/pull/44"

	run_check_script
	assert_success
	assert_output --partial "Cleanup PR created"

	[[ ! -f "$MOCK_GIT_REPO/.osv-scanner.toml" ]] || {
		! grep -q 'GHSA-stale-2222' "$MOCK_GIT_REPO/.osv-scanner.toml"
		! grep -q 'GHSA-expired-3333' "$MOCK_GIT_REPO/.osv-scanner.toml"
	}
}

@test "vuln-suppressions: skips when cleanup PR already open" {
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
