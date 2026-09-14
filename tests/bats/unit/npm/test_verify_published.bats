#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/npm/verify-published.sh (#965)
#
# npm is mocked per test. The pack branch of every "good registry" mock
# creates the tarball the scratch install step looks for.

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

# A registry where the publish succeeded and propagated. PACK and the
# attestation payload are what the script's contract needs.
write_good_mock() {
	cat >"${BATS_TEST_TMPDIR}/mock_body" <<'BODY'
	*view*dist.attestations*) echo '{"dist.attestations":"https://registry.npmjs.org/-/npm/v1/attestations/","dist.integrity":"sha512-abc"}';;
	*--pack-destination*)
		for a in "$@"; do
			case "$a" in /*) pack_dir="$a";; esac
		done
		touch "$pack_dir/@lgtm-hq__pkg-1.2.3.tgz"
		exit 0;;
	*audit*signatures*) exit 0;;
	*install*) exit 0;;
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
}

@test "verify-published: fails a package missing dist.attestations" {
	export ORDER='["meta"]'
	cat >"${BATS_TEST_TMPDIR}/mock_body" <<'BODY'
	*view*dist.attestations*) echo '{"dist.integrity":"sha512-abc"}';;
	*--pack-destination*)
		for a in "$@"; do
			case "$a" in /*) pack_dir="$a";; esac
		done
		touch "$pack_dir/@lgtm-hq__pkg-1.2.3.tgz"
		exit 0;;
	*audit*signatures*) exit 0;;
	*install*) exit 0;;
BODY
	make_npm_mock_from "${BATS_TEST_TMPDIR}/mock_body"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "missing dist.attestations/dist.integrity"
	assert_output --partial "post-publish verification failed"
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
	*--pack-destination*)
		for a in "\$@"; do
			case "\$a" in /*) pack_dir="\$a";; esac
		done
		touch "\$pack_dir/@lgtm-hq__pkg-1.2.3.tgz"
		exit 0;;
	*audit*signatures*) exit 0;;
	*install*) exit 0;;
BODY
	make_npm_mock_from "${BATS_TEST_TMPDIR}/mock_body"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "attempt 2/5"
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
	assert_output --partial "not visible on the registry"
}

@test "verify-published: smoke command failure fails the run" {
	export ORDER='["meta"]'
	export SMOKE="false"
	write_good_mock

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "smoke command failed"
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
	*--pack-destination*)
		for a in "\$@"; do
			case "\$a" in /*) pack_dir="\$a";; esac
		done
		touch "\$pack_dir/@lgtm-hq__pkg-1.2.3.tgz"
		exit 0;;
	*audit*signatures*) exit 0;;
	*install*) exit 0;;
BODY
	make_npm_mock_from "${BATS_TEST_TMPDIR}/mock_body"

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "not yet present"
	assert_output --partial "attempt 2/5"
	assert_output --partial "Post-publish verification passed"
}

@test "verify-published: metadata still missing after all attempts fails with the attempt count" {
	export ORDER='["meta"]'
	export ATTEMPTS=3
	cat >"${BATS_TEST_TMPDIR}/mock_body" <<'BODY'
	*view*dist.attestations*) echo '{"dist.integrity":"sha512-abc"}';;
	*--pack-destination*)
		for a in "$@"; do
			case "$a" in /*) pack_dir="$a";; esac
		done
		touch "$pack_dir/@lgtm-hq__pkg-1.2.3.tgz"
		exit 0;;
	*audit*signatures*) exit 0;;
	*install*) exit 0;;
BODY
	make_npm_mock_from "${BATS_TEST_TMPDIR}/mock_body"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "missing dist.attestations/dist.integrity after 3 propagation attempts"
	run grep -c "] view" "$CALLS"
	assert_output 3
}

@test "verify-published: an order that resolves to no packages fails" {
	export ORDER='[]'
	make_npm_mock_from /dev/null

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "resolved to no packages"
}
