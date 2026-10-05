#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/release/run-version-update-hook.sh

load "../../../helpers/common"
load "../../../helpers/mocks"
load "../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/release/run-version-update-hook.sh"

setup() {
	setup_temp_dir
	setup_github_env
	setup_mock_git_repo
	(
		cd "$MOCK_GIT_REPO" || exit 1
		mkdir -p .github/workflows src
		echo "name: ci" >.github/workflows/ci.yml
		echo "1.0.0" >src/version.txt
		echo "# Changelog" >CHANGELOG.md
		git add -A
		git commit -q -m "chore: seed"
		# Prepared state: trusted code already edited the changelog.
		echo "## 2.0.0" >>CHANGELOG.md
		# A tooling checkout as the hook job has it: a nested git repo.
		mkdir -p .lgtm-ci-tooling/scripts/ci/release
		printf '#!/usr/bin/env bash\nset -euo pipefail\necho ok\n' \
			>.lgtm-ci-tooling/scripts/ci/release/check-version-files-changed.sh
		git -C .lgtm-ci-tooling init -q
		git -C .lgtm-ci-tooling config user.email t@t
		git -C .lgtm-ci-tooling config user.name t
		git -C .lgtm-ci-tooling config commit.gpgsign false
		git -C .lgtm-ci-tooling add -A
		git -C .lgtm-ci-tooling commit -q -m tooling
	)
	METADATA="${BATS_TEST_TMPDIR}/release-metadata.json"
	echo '{"schema":1,"next_version":"2.0.0","latest_release":null,"container":null}' >"$METADATA"
	OUTPUT_DIR="${BATS_TEST_TMPDIR}/out"
}

teardown() {
	chmod -R u+w "$MOCK_GIT_REPO" 2>/dev/null || true
	teardown_github_env
	teardown_temp_dir
}

write_hook() {
	local body="$1"
	HOOK="${BATS_TEST_TMPDIR}/hook.sh"
	printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$body" >"$HOOK"
	chmod +x "$HOOK"
}

run_hook() {
	run bash -c "cd '$MOCK_GIT_REPO' && env -u GH_TOKEN -u GITHUB_TOKEN \
		SCRIPT_PATH='$HOOK' NEXT_VERSION=2.0.0 \
		RELEASE_METADATA_PATH='$METADATA' OUTPUT_DIR='$OUTPUT_DIR' \
		bash '$SCRIPT' 2>&1"
}

@test "run-version-update-hook: fails without required variables" {
	run env -u SCRIPT_PATH bash "$SCRIPT"
	assert_failure
	assert_output --partial "SCRIPT_PATH is required"
	run env -u NEXT_VERSION SCRIPT_PATH=/bin/true bash "$SCRIPT"
	assert_failure
	assert_output --partial "NEXT_VERSION is required"
	run env -u RELEASE_METADATA_PATH SCRIPT_PATH=/bin/true NEXT_VERSION=1 bash "$SCRIPT"
	assert_failure
	assert_output --partial "RELEASE_METADATA_PATH is required"
	run env -u OUTPUT_DIR SCRIPT_PATH=/bin/true NEXT_VERSION=1 RELEASE_METADATA_PATH=/x bash "$SCRIPT"
	assert_failure
	assert_output --partial "OUTPUT_DIR is required"
}

@test "run-version-update-hook: refuses to run when a token is in the environment" {
	write_hook 'echo should-not-run'
	run bash -c "cd '$MOCK_GIT_REPO' && GH_TOKEN=leak SCRIPT_PATH='$HOOK' NEXT_VERSION=2.0.0 \
		RELEASE_METADATA_PATH='$METADATA' OUTPUT_DIR='$OUTPUT_DIR' bash '$SCRIPT' 2>&1"
	assert_failure
	assert_output --partial "must not carry one"
	refute_output --partial "should-not-run"
}

@test "run-version-update-hook: passes NEXT_VERSION and the metadata path, no token" {
	write_hook 'echo "hook NEXT_VERSION=${NEXT_VERSION} meta=$(jq -r .next_version "$RELEASE_METADATA_PATH") token=${GH_TOKEN:-none}/${GITHUB_TOKEN:-none}"'
	run_hook
	assert_success
	assert_output --partial "hook NEXT_VERSION=2.0.0 meta=2.0.0 token=none/none"
}

@test "run-version-update-hook: captures only the hook's own changes, including new files" {
	write_hook 'echo 2.0.0 >src/version.txt; echo new >src/extra.txt'
	run_hook
	assert_success
	assert_output --partial "changed 2 file(s)"
	assert_file_exists "$OUTPUT_DIR/version-update.diff"
	run grep -c '^diff --git' "$OUTPUT_DIR/version-update.diff"
	assert_output "2"
	run grep -F 'b/src/extra.txt' "$OUTPUT_DIR/version-update.diff"
	assert_success
	# The prepared CHANGELOG edit belongs to trusted code, not to the hook.
	run grep -F 'CHANGELOG.md' "$OUTPUT_DIR/version-update.diff"
	assert_failure
	run grep -F '.lgtm-ci-tooling' "$OUTPUT_DIR/version-update.diff"
	assert_failure
}

@test "run-version-update-hook: an idle hook yields an empty diff" {
	write_hook 'true'
	run_hook
	assert_success
	assert_output --partial "made no changes"
	assert_file_exists "$OUTPUT_DIR/version-update.diff"
	[[ ! -s "$OUTPUT_DIR/version-update.diff" ]]
}

@test "run-version-update-hook: propagates the hook's exit status" {
	write_hook 'echo boom >&2; exit 7'
	run_hook
	assert_failure
	assert_equal "$status" 7
	assert_output --partial "boom"
	assert_output --partial "exited with status 7"
}

@test "run-version-update-hook: the tooling checkout is read-only while the hook runs" {
	# The fixture's tamper hook shape: rewrite the next lgtm-ci script (#849).
	write_hook 'echo "echo TAMPERED" >>.lgtm-ci-tooling/scripts/ci/release/check-version-files-changed.sh'
	run_hook
	assert_failure
	assert_output --partial "Permission denied"
	run grep -c TAMPERED "$MOCK_GIT_REPO/.lgtm-ci-tooling/scripts/ci/release/check-version-files-changed.sh"
	assert_output "0"
	# Write access is restored for runner cleanup.
	[[ -w "$MOCK_GIT_REPO/.lgtm-ci-tooling/scripts/ci/release/check-version-files-changed.sh" ]]
}

@test "run-version-update-hook: a hook that forces a write into the tooling checkout fails the job" {
	write_hook 'chmod -R u+w .lgtm-ci-tooling; echo "echo TAMPERED" >>.lgtm-ci-tooling/scripts/ci/release/check-version-files-changed.sh'
	run_hook
	assert_failure
	assert_output --partial "::error title=version-update-script modified lgtm-ci tooling::"
	[[ ! -e "$OUTPUT_DIR/version-update.diff" ]]
}

@test "run-version-update-hook: a hook editing .github/workflows fails the scope check" {
	write_hook 'echo tampered >.github/workflows/ci.yml'
	run_hook
	assert_failure
	assert_output --partial "::error title=version-update-script out of scope::.github/workflows/ci.yml"
}

@test "run-version-update-hook: writes a step summary" {
	write_hook 'echo 2.0.0 >src/version.txt'
	run_hook
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "### Version update hook"
	assert_output --partial "Files changed: 1"
}
