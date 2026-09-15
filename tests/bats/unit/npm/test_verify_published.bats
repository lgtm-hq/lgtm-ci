#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/npm/verify-published.sh (#965)
#
# npm is mocked per test. The audit installs the exact published spec from
# the (mocked) registry, so the install branch must match name@version.

load "../../../helpers/common"
load "../../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/npm/verify-published.sh"

setup() {
	setup_temp_dir
	save_path
	export PROJECT_ROOT
	export SCRIPT
	export CALLS="${BATS_TEST_TMPDIR}/npm_calls.log"
	: >"$CALLS"
	export ATTEMPTS=5
	export DELAY=0
	export DELAY_START=0
	export DIST_TAG=latest
	# Journal the sleeps instead of sleeping: the backoff schedule is asserted.
	export SLEEPS="${BATS_TEST_TMPDIR}/sleeps.log"
	: >"$SLEEPS"
	export SLEEP_CMD="${BATS_TEST_TMPDIR}/fake-sleep"
	printf '#!/usr/bin/env bash\necho "$1" >> "%s"\n' "$SLEEPS" >"$SLEEP_CMD"
	chmod +x "$SLEEP_CMD"
	export PACKAGES_DIR="${BATS_TEST_TMPDIR}/npm-dist"
	mkdir -p "$PACKAGES_DIR/meta"
	printf '{"name":"@lgtm-hq/pkg","version":"1.2.3"}\n' >"$PACKAGES_DIR/meta/package.json"
}

teardown() {
	restore_path
	teardown_temp_dir
}

# Write an npm mock. $1 = path to a file whose contents are the case body;
# a heredoc (not a quoted string) so tests can write natural bash.
make_npm_mock_from() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	{
		printf '#!/usr/bin/env bash\n'
		printf 'echo "npm [$PWD] $*" >> '"'"'%s'"'"'\n' "$CALLS"
		printf 'case "$*" in\n'
		cat "$1"
		printf '	*) echo "npm: unexpected call: $*" >&2; exit 99;;\n'
		printf 'esac\n'
	} >"${mock_bin}/npm"
	chmod +x "${mock_bin}/npm"
	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}

# A registry where the publish succeeded and propagated: the attestation
# payload and a registry install of the exact spec are what the contract needs.
write_good_mock() {
	cat >"${BATS_TEST_TMPDIR}/mock_body" <<'BODY'
	*view*dist.attestations*) echo '{"dist.attestations":"https://registry.npmjs.org/-/npm/v1/attestations/","dist.integrity":"sha512-abc"}';;
	*view*dist-tags*) echo '{"latest":"1.2.3"}';;
	*audit*signatures*) exit 0;;
	*install*@lgtm-hq/pkg@1.2.3*) exit 0;;
BODY
	make_npm_mock_from "${BATS_TEST_TMPDIR}/mock_body"
}

@test "verify-published: passes bash syntax check" {
	run bash -n "$SCRIPT"
	assert_success
}

@test "verify-published: dry-run skips registry verification" {
	export ORDER='["meta"]'
	export DRY_RUN=1
	make_npm_mock_from /dev/null

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "post-publish registry verification skipped"
	run grep -c "] view" "$CALLS"
	assert_output 0
}

@test "verify-published: passes when attestations and integrity are present" {
	export ORDER='["meta"]'
	write_good_mock

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Post-publish verification passed"
	run grep -c "audit signatures" "$CALLS"
	assert_output 1
	# The audited package is the exact published spec installed from the
	# registry, never a local re-pack of the staged directory.
	run grep -c "install .*@lgtm-hq/pkg@1.2.3" "$CALLS"
	assert_output 1
	run grep -c "] pack" "$CALLS"
	assert_output 0
}

@test "verify-published: scratch install from the registry failing is recorded and fails the run" {
	export ORDER='["meta"]'
	cat >"${BATS_TEST_TMPDIR}/mock_body" <<'BODY'
	*view*dist.attestations*) echo '{"dist.attestations":"x","dist.integrity":"sha512-abc"}';;
	*view*dist-tags*) echo '{"latest":"1.2.3"}';;
	*install*@lgtm-hq/pkg@1.2.3*) echo "npm error E404" >&2; exit 1;;
	*audit*signatures*) echo "unexpected audit after a failed install" >&2; exit 99;;
BODY
	make_npm_mock_from "${BATS_TEST_TMPDIR}/mock_body"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "scratch install of @lgtm-hq/pkg@1.2.3 from the registry failed"
	assert_output --partial "post-publish verification failed"
	run grep -c "audit signatures" "$CALLS"
	assert_output 0
}

@test "verify-published: npm audit signatures failure is recorded and fails the run" {
	export ORDER='["meta"]'
	cat >"${BATS_TEST_TMPDIR}/mock_body" <<'BODY'
	*view*dist.attestations*) echo '{"dist.attestations":"x","dist.integrity":"sha512-abc"}';;
	*view*dist-tags*) echo '{"latest":"1.2.3"}';;
	*install*@lgtm-hq/pkg@1.2.3*) exit 0;;
	*audit*signatures*) echo "1 package has an invalid registry signature" >&2; exit 1;;
BODY
	make_npm_mock_from "${BATS_TEST_TMPDIR}/mock_body"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "npm audit signatures failed for @lgtm-hq/pkg@1.2.3"
}

@test "verify-published: fails a package missing dist.attestations" {
	export ORDER='["meta"]'
	cat >"${BATS_TEST_TMPDIR}/mock_body" <<'BODY'
	*view*dist.attestations*) echo '{"dist.integrity":"sha512-abc"}';;
	*audit*signatures*) exit 0;;
	*install*) exit 0;;
BODY
	make_npm_mock_from "${BATS_TEST_TMPDIR}/mock_body"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "missing dist.attestations/dist.integrity"
	assert_output --partial "post-publish verification failed"
}

@test "verify-published: visible immediately passes on the first poll with no sleep" {
	export ORDER='["meta"]'
	write_good_mock

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "visible with provenance attestation, integrity and dist-tag 'latest' after"
	assert_output --partial "(poll 1)"
	assert_output --partial "All packages visible on the registry after"
	assert_output --partial "Post-publish verification passed"
	run grep -c "" "$SLEEPS"
	assert_output 0
}

@test "verify-published: retries registry propagation before succeeding" {
	export ORDER='["meta"]'
	cat >"${BATS_TEST_TMPDIR}/mock_body" <<BODY
	*view*dist.attestations*)
		if [ -f "${CALLS}.seen" ]; then
			echo '{"dist.attestations":"x","dist.integrity":"sha512-abc"}'
			exit 0
		fi
		touch "${CALLS}.seen"
		echo "npm error 404" >&2
		exit 1;;
	*view*dist-tags*) echo '{"latest":"1.2.3"}';;
	*audit*signatures*) exit 0;;
	*install*) exit 0;;
BODY
	make_npm_mock_from "${BATS_TEST_TMPDIR}/mock_body"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "not visible yet"
	assert_output --partial "poll 2/5"
	assert_output --partial "(poll 2)"
}

@test "verify-published: visible after N polls reports the poll count and backs off up to the cap" {
	export ORDER='["meta"]'
	export ATTEMPTS=6
	export DELAY_START=5
	export DELAY=30
	# Visible on the fourth poll: three sleeps of 5, 10, 20 (the fifth would be capped at 30).
	cat >"${BATS_TEST_TMPDIR}/mock_body" <<BODY
	*view*dist.attestations*)
		n=\$(cat "${CALLS}.count" 2>/dev/null || echo 0)
		n=\$((n + 1))
		echo "\$n" > "${CALLS}.count"
		if [ "\$n" -ge 4 ]; then
			echo '{"dist.attestations":"x","dist.integrity":"sha512-abc"}'
			exit 0
		fi
		echo "npm error 404" >&2
		exit 1;;
	*view*dist-tags*) echo '{"latest":"1.2.3"}';;
	*audit*signatures*) exit 0;;
	*install*) exit 0;;
BODY
	make_npm_mock_from "${BATS_TEST_TMPDIR}/mock_body"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "(poll 4)"
	assert_output --partial "All packages visible on the registry after"
	run cat "$SLEEPS"
	assert_output $'5\n10\n20'
	# The scratch install happens only once the set is visible: after the polls.
	run awk '/view .*dist.attestations/ { last_view = NR } /install/ { inst = NR } END { exit !(inst > last_view) }' "$CALLS"
	assert_success
}

@test "verify-published: fails when the version never becomes visible" {
	export ORDER='["meta"]'
	export ATTEMPTS=2
	cat >"${BATS_TEST_TMPDIR}/mock_body" <<'BODY'
	*view*) echo "npm error 404" >&2; exit 1;;
BODY
	make_npm_mock_from "${BATS_TEST_TMPDIR}/mock_body"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "not visible on the registry after 2 attempts"
	assert_output --partial "post-publish verification failed"
	# Never visible: no scratch install, no audit, no smoke.
	run grep -c "install" "$CALLS"
	assert_output 0
	run grep -c "" "$SLEEPS"
	assert_output 1
}

@test "verify-published: caps the backoff at DELAY between polls" {
	export ORDER='["meta"]'
	export ATTEMPTS=5
	export DELAY_START=8
	export DELAY=20
	cat >"${BATS_TEST_TMPDIR}/mock_body" <<'BODY'
	*view*) echo "npm error 404" >&2; exit 1;;
BODY
	make_npm_mock_from "${BATS_TEST_TMPDIR}/mock_body"

	run bash "$SCRIPT"
	assert_failure
	run cat "$SLEEPS"
	assert_output $'8\n16\n20\n20'
}

@test "verify-published: waits for the dist-tag to point at the published version" {
	export ORDER='["meta"]'
	export DIST_TAG=next
	cat >"${BATS_TEST_TMPDIR}/mock_body" <<BODY
	*view*dist.attestations*) echo '{"dist.attestations":"x","dist.integrity":"sha512-abc"}';;
	*view*dist-tags*)
		if [ -f "${CALLS}.seen" ]; then
			echo '{"latest":"1.2.2","next":"1.2.3"}'
			exit 0
		fi
		touch "${CALLS}.seen"
		echo '{"latest":"1.2.2","next":"1.2.2"}';;
	*audit*signatures*) exit 0;;
	*install*) exit 0;;
BODY
	make_npm_mock_from "${BATS_TEST_TMPDIR}/mock_body"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "dist-tag 'next' does not point at it yet"
	assert_output --partial "dist-tag 'next' after"
}

@test "verify-published: a dist-tag that never moves fails after the budget" {
	export ORDER='["meta"]'
	export ATTEMPTS=2
	cat >"${BATS_TEST_TMPDIR}/mock_body" <<'BODY'
	*view*dist.attestations*) echo '{"dist.attestations":"x","dist.integrity":"sha512-abc"}';;
	*view*dist-tags*) echo '{"latest":"1.2.2"}';;
BODY
	make_npm_mock_from "${BATS_TEST_TMPDIR}/mock_body"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "dist-tag 'latest' does not point at @lgtm-hq/pkg@1.2.3 after 2 attempts"
	assert_output --partial "not tagged 'latest' after 2 propagation attempts"
	run grep -c "install" "$CALLS"
	assert_output 0
}

@test "verify-published: polls every package together and installs only after the whole set is visible" {
	mkdir -p "$PACKAGES_DIR/platform-a"
	printf '{"name":"@lgtm-hq/pkg-platform-a","version":"1.2.3"}\n' >"$PACKAGES_DIR/platform-a/package.json"
	export ORDER='["platform-a", "meta"]'
	# The meta package is visible at once; the platform package only on poll 3.
	cat >"${BATS_TEST_TMPDIR}/mock_body" <<BODY
	*view*pkg-platform-a@1.2.3*dist.attestations*)
		n=\$(cat "${CALLS}.count" 2>/dev/null || echo 0)
		n=\$((n + 1))
		echo "\$n" > "${CALLS}.count"
		if [ "\$n" -ge 3 ]; then
			echo '{"dist.attestations":"x","dist.integrity":"sha512-abc"}'
			exit 0
		fi
		echo "npm error 404" >&2
		exit 1;;
	*view*dist.attestations*) echo '{"dist.attestations":"x","dist.integrity":"sha512-abc"}';;
	*view*dist-tags*) echo '{"latest":"1.2.3"}';;
	*audit*signatures*) exit 0;;
	*install*) exit 0;;
BODY
	make_npm_mock_from "${BATS_TEST_TMPDIR}/mock_body"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "@lgtm-hq/pkg@1.2.3 visible with provenance attestation, integrity and dist-tag 'latest' after"
	assert_output --partial "(poll 1)"
	assert_output --partial "@lgtm-hq/pkg-platform-a@1.2.3 visible with provenance attestation, integrity and dist-tag 'latest' after"
	assert_output --partial "(poll 3)"
	# A package already visible is not probed again; the platform package is probed three times.
	run grep -c "view @lgtm-hq/pkg@1.2.3 dist.attestations" "$CALLS"
	assert_output 1
	run grep -c "view @lgtm-hq/pkg-platform-a@1.2.3 dist.attestations" "$CALLS"
	assert_output 3
	# The install follows the last probe.
	run awk '/view .*dist.attestations/ { last_view = NR } /install/ { inst = NR } END { exit !(inst > last_view) }' "$CALLS"
	assert_success
}

@test "verify-published: smoke command failure fails the run and keeps its output" {
	export ORDER='["meta"]'
	export SMOKE="echo smoke-diagnostic-line; false"
	write_good_mock

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "smoke command failed"
	# The smoke command's own output is the diagnostic; it must not be lost.
	assert_output --partial "smoke-diagnostic-line"
}

@test "verify-published: checks every package in order, meta last" {
	mkdir -p "$PACKAGES_DIR/platform-a"
	printf '{"name":"@lgtm-hq/pkg-platform-a","version":"1.2.3"}\n' >"$PACKAGES_DIR/platform-a/package.json"
	export ORDER='["platform-a", "meta"]'
	write_good_mock

	run bash "$SCRIPT"
	assert_success
	# Both registry reads are journaled; platform-a's must come before meta's,
	# and the meta audit must come after both.
	run awk '
		/view @lgtm-hq\/pkg-platform-a@1.2.3/ { a = NR }
		/view @lgtm-hq\/pkg@1.2.3/ { m = NR }
		/audit signatures/ { audit = NR }
		END { exit !(a && m && audit && a < m && m < audit) }
	' "$CALLS"
	assert_success
	run grep -c "audit signatures" "$CALLS"
	assert_output 1
}

@test "verify-published: retries when the version is visible before its attestation metadata" {
	export ORDER='["meta"]'
	cat >"${BATS_TEST_TMPDIR}/mock_body" <<BODY
	*view*dist.attestations*)
		if [ -f "${CALLS}.seen" ]; then
			echo '{"dist.attestations":"x","dist.integrity":"sha512-abc"}'
			exit 0
		fi
		touch "${CALLS}.seen"
		echo '{"dist.integrity":"sha512-abc"}'
		exit 0;;
	*view*dist-tags*) echo '{"latest":"1.2.3"}';;
	*audit*signatures*) exit 0;;
	*install*) exit 0;;
BODY
	make_npm_mock_from "${BATS_TEST_TMPDIR}/mock_body"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "not yet present"
	assert_output --partial "poll 2/5"
	assert_output --partial "Post-publish verification passed"
}

@test "verify-published: metadata still missing after all attempts fails with the attempt count" {
	export ORDER='["meta"]'
	export ATTEMPTS=3
	cat >"${BATS_TEST_TMPDIR}/mock_body" <<'BODY'
	*view*dist.attestations*) echo '{"dist.integrity":"sha512-abc"}';;
	*audit*signatures*) exit 0;;
	*install*) exit 0;;
BODY
	make_npm_mock_from "${BATS_TEST_TMPDIR}/mock_body"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "missing dist.attestations/dist.integrity after 3 propagation attempts"
	run grep -c "] view" "$CALLS"
	assert_output 3
	# Incomplete metadata never reaches the scratch install.
	run grep -c "install" "$CALLS"
	assert_output 0
}

@test "verify-published: rejects an empty DIST_TAG" {
	export ORDER='["meta"]'
	export DIST_TAG=""
	make_npm_mock_from /dev/null

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "DIST_TAG must be non-empty"
}

@test "verify-published: an order that resolves to no packages fails" {
	export ORDER='[]'
	make_npm_mock_from /dev/null

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "resolved to no packages"
}
