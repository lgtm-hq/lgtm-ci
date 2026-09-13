#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/npm/publish-set.sh (#965)
#
# npm is mocked; node is real (package.json fixtures). Call-log assertions
# read the mock's journal file.

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/npm/publish-set.sh"

setup() {
	setup_temp_dir
	save_path
	export PROJECT_ROOT
	export SCRIPT
	export CALLS="${BATS_TEST_TMPDIR}/npm_calls.log"
	: >"$CALLS"
	# Deterministic and instant: no real sleeping in tests.
	export RETRY_DELAY=0
	export MAX_DELAY=0
	# Package fixtures: two platform packages and a meta package.
	export PACKAGES_DIR="${BATS_TEST_TMPDIR}/npm-dist"
	mkdir -p "$PACKAGES_DIR/platform-a" "$PACKAGES_DIR/platform-b" "$PACKAGES_DIR/meta"
	printf '{"name":"@lgtm-hq/pkg-platform-a","version":"1.2.3"}\n' >"$PACKAGES_DIR/platform-a/package.json"
	printf '{"name":"@lgtm-hq/pkg-platform-b","version":"1.2.3"}\n' >"$PACKAGES_DIR/platform-b/package.json"
	printf '{"name":"@lgtm-hq/pkg","version":"1.2.3"}\n' >"$PACKAGES_DIR/meta/package.json"
}

teardown() {
	restore_path
	teardown_temp_dir
}

# Journal one line per npm invocation: "<verb> <args...>".
make_npm_mock() {
	local case_body="$1"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/npm" <<NPMMOCK
#!/usr/bin/env bash
echo "npm [\$PWD] \$*" >> '${CALLS}'
case "\$*" in
${case_body}
	*) echo "npm: unexpected call: \$*" >&2; exit 99;;
esac
NPMMOCK
	chmod +x "${mock_bin}/npm"
	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

not_published_reply() {
	# Mirrors npm's 404 shape: the E404 text must arrive on stderr for the
	# script's redirect-order-sensitive capture.
	echo "npm error code E404" >&2
	echo "npm error 404 Not Found - GET https://registry.npmjs.org/$1" >&2
	exit 1
}

@test "publish-set: passes bash syntax check" {
	run bash -n "$SCRIPT"
	assert_success
}

@test "publish-set: dry-run publishes every package with --dry-run and never inspects the registry" {
	export ORDER='["platform-a", "platform-b", "meta"]'
	export DRYRUN_PROOF=1
	make_npm_mock '
			*publish*--dry-run*) echo "npm notice; exit 0";;
			*view*|*dist-tag*) echo "unexpected registry read in dry-run" >&2; exit 99;;
	'

	run bash "$SCRIPT"
	assert_success
	run grep -c "publish --access" "$CALLS"
	assert_output 3
	# Order matters: platform packages first, meta package last (the mock
	# journals $PWD, since publish args never name the package directory).
	run awk '/\/platform-a/{a=NR} /\/platform-b/{b=NR} /\/meta/{m=NR} END{exit !(a && b && m && a < b && b < m)}' "$CALLS"
	assert_success
	refute_output --partial "Skipping"
}

@test "publish-set: comma-separated order works and bad entries fail loudly" {
	export ORDER="platform-a, meta"
	make_npm_mock '
			*publish*--dry-run*) exit 0;;
			*view*|*dist-tag*) exit 99;;
	'
	run bash "$SCRIPT"
	assert_success
	run grep -c "publish --access" "$CALLS"
	assert_output 2

	export ORDER="platform-a missing-pkg"
	make_npm_mock '*publish*) exit 0;;'
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "missing-pkg/package.json not found"
}

@test "publish-set: live rerun skips published packages and reconciles without a write when the tag already matches" {
	export ORDER='["platform-a", "meta"]'
	export LIVE=1
	make_npm_mock '
			*@lgtm-hq/pkg-platform-a@1.2.3*version*) exit 0;;
			*@lgtm-hq/pkg@1.2.3*version*) exit 0;;
			*dist-tag\ ls*platform-a*) echo "latest: 1.2.3";;
			*dist-tag\ ls*@lgtm-hq/pkg*) echo "latest: 1.2.3";;
			*dist-tag\ add*) echo "unexpected dist-tag write" >&2; exit 99;;
			*publish*) echo "unexpected publish" >&2; exit 99;;
			*view*dist.integrity*) echo sha512-integrity-skipped;;
	'

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Skipping @lgtm-hq/pkg-platform-a@1.2.3"
	assert_output --partial "nothing to reconcile"
	run grep -c "] dist-tag add" "$CALLS"
	assert_output 0
	run grep -c "publish --access" "$CALLS"
	assert_output 0
	refute_output --partial "npm error"
}

@test "publish-set: conflict is an idempotent success and reconciles the tag with a write" {
	export ORDER='["platform-a"]'
	export LIVE=1
	make_npm_mock '
			*@lgtm-hq/pkg-platform-a@1.2.3*version*) not_published_reply @lgtm-hq/pkg-platform-a;;
			*dist-tag\ ls*) echo "latest: 1.0.0";;
			*dist-tag\ add*) exit 0;;
			*publish*) echo "npm error code EPUBLISHCONFLICT"; echo "npm error cannot publish over the previously published versions"; exit 1;;
			*view*dist.integrity*) echo sha512-abc;;
	'

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "idempotent success"
	assert_output --partial "Reconciling dist-tag 'latest' for @lgtm-hq/pkg-platform-a@1.2.3"
	run grep -c "publish --access" "$CALLS"
	assert_output 1
}

@test "publish-set: transient publish failure retries and succeeds" {
	export ORDER='["platform-a"]'
	export LIVE=1
	local -i attempt=0
	make_npm_mock '
			*@lgtm-hq/pkg-platform-a@1.2.3*version*) not_published_reply @lgtm-hq/pkg-platform-a;;
			*publish*)
				if [ -f "'"$CALLS"'.p1" ]; then exit 0; fi
				touch "'"$CALLS"'.p1"
				echo "npm error code TLOG_CREATE_ENTRY_ERROR"; exit 1;;
			*dist-tag\ ls*) echo "latest: 1.2.3";;
			*dist-tag\ add*) exit 0;;
	'

	run bash "$SCRIPT"
	assert_success
	run grep -c "publish --access" "$CALLS"
	assert_output 2
}

@test "publish-set: non-retryable auth failure stops without retrying" {
	export ORDER='["platform-a"]'
	export LIVE=1
	make_npm_mock '
			*@lgtm-hq/pkg-platform-a@1.2.3*version*) not_published_reply @lgtm-hq/pkg-platform-a;;
			*publish*) echo "npm error code E403" >&2; echo "npm error forbidden" >&2; exit 1;;
			*) exit 0;;
	'

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "non-retryable auth/validation error"
	run grep -c "publish --access" "$CALLS"
	assert_output 1
}

@test "publish-set: OIDC dist-tag write rejection records drift, publishes the rest, then fails" {
	export ORDER='["platform-a", "meta"]'
	export LIVE=1
	make_npm_mock '
			*@lgtm-hq/pkg-platform-a@1.2.3*version*) exit 0;;
			*dist-tag\ ls*platform-a*) echo "latest: 1.0.0";;
			*dist-tag\ add*) echo "npm error code E403" >&2; echo "npm error forbidden" >&2; exit 1;;
			*publish*) exit 0;;
			*view*) exit 1;;
	'

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "npm trusted publishing (OIDC) tokens are publish-scoped"
	# The meta package still published after platform-a's drift.
	run grep -c "publish --access" "$CALLS"
	assert_output 1
}

@test "publish-set: writes published JSON and drift flag to GITHUB_OUTPUT" {
	local output_file="${BATS_TEST_TMPDIR}/github-output"
	: >"$output_file"
	export GITHUB_OUTPUT="$output_file"
	export ORDER='["platform-a"]'
	export LIVE=1
	make_npm_mock '
			*@lgtm-hq/pkg-platform-a@1.2.3*version*) exit 0;;
			*dist-tag\ ls*) echo "latest: 1.2.3";;
			*publish*) exit 0;;
			*view*dist.integrity*) echo sha512-out;;
	'

	run bash "$SCRIPT"
	assert_success
	run grep -F 'published=[{"name":"@lgtm-hq/pkg-platform-a","version":"1.2.3","status":"skipped","integrity":"sha512-out"}]' "$output_file"
	assert_success
	run grep -F "dist_tag_drift=false" "$output_file"
	assert_success
}

@test "publish-set: manifest of results marks skipped packages" {
	local output_file="${BATS_TEST_TMPDIR}/github-output"
	: >"$output_file"
	export GITHUB_OUTPUT="$output_file"
	export ORDER='["platform-a"]'
	export LIVE=1
	make_npm_mock '
			*@lgtm-hq/pkg-platform-a@1.2.3*version*) exit 0;;
			*dist-tag\ ls*) echo "latest: 1.2.3";;
			*view*dist.integrity*) echo sha512-skip;;
			*publish*) echo "unexpected" >&2; exit 99;;
	'

	run bash "$SCRIPT"
	assert_success
	run grep -F '"status":"skipped"' "$output_file"
	assert_success
}
