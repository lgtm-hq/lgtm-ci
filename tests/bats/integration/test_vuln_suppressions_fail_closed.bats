#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: End-to-end fail-closed cases for check-vuln-suppressions.sh (#1613):
# the real script with osv-scanner and gh stubs. Nothing the scanner keeps in
# effect, nothing the check does not fully read, and nothing from an
# incomplete scan may be removed; nothing from the suppression file may reach
# the log as a runner command.

load "../../helpers/common"
load "../../helpers/mocks"
load "../../helpers/github_env"
load "../../helpers/vuln_suppressions"

bats_require_minimum_version 1.5.0

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

# Commit stdin as the suppression file and remember it for unchanged_toml.
commit_and_keep() {
	setup_suppression_repo
	commit_toml
	cp "$MOCK_GIT_REPO/.osv-scanner.toml" "${BATS_TEST_TMPDIR}/toml.before"
}

unchanged_toml() {
	cmp -s "$MOCK_GIT_REPO/.osv-scanner.toml" "${BATS_TEST_TMPDIR}/toml.before"
}

no_cleanup_commit() {
	! grep -qE "graphql|pr create" "$MOCK_GH_LOG"
}

@test "fail-closed: a block with id and ID keeps both, and is listed (#1613)" {
	commit_and_keep <<'EOF'
[[IgnoredVulns]]
id = "STALE"
ID = "CVE-2018-18074"
reason = "osv-scanner reads ID as id"
EOF
	mock_osv_probe "$(probe_json CVE-2018-18074)"
	mock_gh_for_cleanup_pr

	run_check_script
	assert_success
	assert_output --partial "Left alone, not understood: entry 1, id 'STALE': key 'ID' differs from 'id' only by case"
	refute_output --partial "Stale:"
	unchanged_toml
	no_cleanup_commit
	grep -qF "## Vulnerability suppressions left alone (not understood)" "$GITHUB_STEP_SUMMARY"
	grep -qF -- "- \`entry 1, id 'STALE': key 'ID' differs from 'id' only by case\`" "$GITHUB_STEP_SUMMARY"
}

@test "fail-closed: a lapsed effectiveUntil is expired, not removed (#1613)" {
	commit_and_keep <<'EOF'
[[IgnoredVulns]]
id = "GHSA-x"
effectiveUntil = 2020-01-01
EOF
	mock_osv_probe '{"results":[]}'
	mock_gh_for_cleanup_pr

	run_check_script
	assert_failure 1
	assert_output --partial "GHSA-x (until 2020-01-01)"
	refute_output --partial "Stale:"
	unchanged_toml
	no_cleanup_commit
	grep -qF '| `GHSA-x` | 2020-01-01 |' "$GITHUB_STEP_SUMMARY"
}

@test "fail-closed: an extraction error with exit 1 removes nothing (#1613)" {
	commit_and_keep <<'EOF'
[[IgnoredVulns]]
id = "GHSA-other"

[[IgnoredVulns]]
id = "GHSA-in-unread-file"
EOF
	mock_osv_probe "$(probe_json GHSA-other)" 1 \
		"Scanned /repo/package-lock.json file and found 3 packages
Error during extraction: (extracting as php/composerlock) /repo/composer.lock: could not extract: invalid character ',' looking for beginning of object key string"
	mock_gh_for_cleanup_pr

	run_check_script
	assert_failure 1
	assert_output --partial "ERROR: osv-scanner reported an error, so the scan may be incomplete"
	assert_output --partial "Suppressions were not classified; nothing was removed"
	unchanged_toml
	no_cleanup_commit
}

@test "fail-closed: a failed resolution with exit 1 removes nothing (#1613)" {
	commit_and_keep <<'EOF'
[[IgnoredVulns]]
id = "GHSA-other"

[[IgnoredVulns]]
id = "GHSA-transitive"
EOF
	mock_osv_probe "$(probe_json GHSA-other)" 1 \
		"failed resolution for /repo/requirements.txt: dial tcp: lookup pypi.org: no such host"
	mock_gh_for_cleanup_pr

	run_check_script
	assert_failure 1
	assert_output --partial "osv-scanner reported an error"
	unchanged_toml
	no_cleanup_commit
}

@test "fail-closed: exit 1 with a clean scan removes nothing (#1613)" {
	commit_and_keep <<'EOF'
[[IgnoredVulns]]
id = "GHSA-stale-2222"
EOF
	mock_osv_probe '{"results":[]}' 1
	mock_gh_for_cleanup_pr

	run_check_script
	assert_failure 1
	assert_output --partial "osv-scanner exited 1 but its output implies 0; the scan is inconsistent"
	unchanged_toml
	no_cleanup_commit
}

@test "fail-closed: exit 0 with a finding removes nothing (#1613)" {
	commit_and_keep <<'EOF'
[[IgnoredVulns]]
id = "GHSA-stale-2222"
EOF
	mock_osv_probe "$(probe_json GHSA-other)" 0
	mock_gh_for_cleanup_pr

	run_check_script
	assert_failure 1
	assert_output --partial "osv-scanner exited 0 but its output implies 1; the scan is inconsistent"
	unchanged_toml
	no_cleanup_commit
}

@test "fail-closed: a file left with only comments is kept, not deleted (#1613)" {
	commit_and_keep <<'EOF'
# Suppressions for this repository

[[IgnoredVulns]]
id = "GHSA-stale-2222"
EOF
	mock_osv_probe '{"results":[]}'
	mock_gh_for_cleanup_pr "https://github.com/test-org/test-repo/pull/80"

	run_check_script
	assert_success
	refute_output --partial "removing file"
	[ "$(_commit_input | jq -r '.fileChanges | has("deletions")')" = "false" ]
	[ "$(_committed_toml)" = "# Suppressions for this repository" ]
}

@test "fail-closed: an inline comment on a removed line is reported (#1613)" {
	commit_and_keep <<'EOF'
[[IgnoredVulns]]
id = "GHSA-keep"

[[IgnoredVulns]]
id = "GHSA-stale-2222"
reason = "gone" # KEEP must be reviewed manually
EOF
	mock_osv_probe "$(probe_json GHSA-keep)"
	mock_gh_for_cleanup_pr "https://github.com/test-org/test-repo/pull/81"

	run_check_script
	assert_success
	assert_output --partial 'Removed comment line 6: "# KEEP must be reviewed manually"'
	grep -qxF 'line 6: "# KEEP must be reviewed manually"' "$MOCK_GH_LOG"
}

@test "fail-closed: ##[ in an id or a comment never reaches the log (#1613)" {
	commit_and_keep <<'EOF'
[[IgnoredVulns]]
id = "GHSA-keep"

# ##[error]forged
[[IgnoredVulns]]
id = "X##[error]forged-id"
EOF
	mock_osv_probe "$(probe_json GHSA-keep)"
	mock_gh_for_cleanup_pr "https://github.com/test-org/test-repo/pull/82"

	run_check_script
	assert_success
	assert_output --partial 'Removed: "X#\u0023[error]forged-id"'
	assert_output --partial 'Removed comment line 4: "# #\u0023[error]forged"'
	refute_output --partial "##["
	! grep -qF "##[" "$MOCK_GH_LOG"
	! grep -qF "##[" "$GITHUB_STEP_SUMMARY"
}

@test "fail-closed: the PR body lists at most 50 stale ids (#1613)" {
	local id toml="${BATS_TEST_TMPDIR}/many.toml"
	{
		for id in $(seq -f 'GHSA-stale-%03g' 1 60); do
			printf '[[IgnoredVulns]]\nid = "%s"\n\n' "$id"
		done
		printf '[[IgnoredVulns]]\nid = "GHSA-keep"\n'
	} >"$toml"
	commit_and_keep <"$toml"
	mock_osv_probe "$(probe_json GHSA-keep)"
	mock_gh_for_cleanup_pr "https://github.com/test-org/test-repo/pull/83"

	run_check_script
	assert_success
	grep -qF -- '- `GHSA-stale-050` (stale' "$MOCK_GH_LOG"
	! grep -qF -- '- `GHSA-stale-051` (stale' "$MOCK_GH_LOG"
	grep -qF -- "- ... and 10 more; the job log lists every one" "$MOCK_GH_LOG"
	assert_output --partial "Stale: GHSA-stale-060"
	_committed_toml | grep -qx 'id = "GHSA-keep"'
	run bash -c "jq -r '.variables.input.fileChanges.additions[0].contents' '$MOCK_GH_GRAPHQL_PAYLOAD' | base64 -d | grep -c 'GHSA-stale'"
	assert_output "0"
}
