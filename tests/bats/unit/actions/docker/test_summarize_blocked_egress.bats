#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/summarize-blocked-egress.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"
load "../../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/summarize-blocked-egress.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export SCRIPT
	export RUNNER_TEMP="$BATS_TEST_TMPDIR"
	export BUILD_LOG="$BATS_TEST_TMPDIR/docker-build.log"
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

# Write a bun-style hang log: registry.npmjs.org blocked, buildkit dies with
# an rpc error after harden-runner silently drops the packets.
_write_bun_hang_log() {
	cat >"$BUILD_LOG" <<'EOF'
#12 [full 5/9] RUN bun install --frozen-lockfile
#12 3.214 bun install v1.2.19 (aad3abea)
#12 1499.7 error: ConnectionRefused downloading package manifest react
#12 1499.7 GET https://registry.npmjs.org/react - dial tcp: lookup registry.npmjs.org: i/o timeout
ERROR: failed to receive status: rpc error: code = Unavailable desc = error reading from server: EOF
EOF
}

# Write an apk-style fast failure: APKINDEX fetch I/O error.
_write_apk_log() {
	cat >"$BUILD_LOG" <<'EOF'
#6 [base 2/4] RUN apk add --no-cache curl
#6 0.412 fetch https://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64/APKINDEX.tar.gz
#6 5.021 ERROR: https://dl-cdn.alpinelinux.org/alpine/v3.20/main: temporary error (try again later)
#6 5.021 WARNING: fetching https://dl-cdn.alpinelinux.org/alpine/v3.20/main: I/O error
EOF
}

# Write a curl-style connection-refused log.
_write_curl_refused_log() {
	cat >"$BUILD_LOG" <<'EOF'
#8 [tools 3/6] RUN curl -fsSL https://static.rust-lang.org/rustup/rustup-init.sh -o rustup-init.sh
#8 2.001 curl: (7) Failed to connect to static.rust-lang.org port 443 after 2000 ms: connect: connection refused
EOF
}

@test "summarize-blocked-egress: bun hang log annotates registry.npmjs.org" {
	_write_bun_hang_log

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "::error::Likely blocked egress: registry.npmjs.org"
	assert_output --partial "add registry.npmjs.org:443 to allowed-endpoints"
}

@test "summarize-blocked-egress: bun hang log writes step summary section" {
	_write_bun_hang_log

	run bash "$SCRIPT"
	assert_success

	local summary
	summary=$(get_github_step_summary)
	[[ "$summary" == *"Possible blocked egress"* ]]
	[[ "$summary" == *"registry.npmjs.org"* ]]
	[[ "$summary" == *"Matched log lines"* ]]
	[[ "$summary" == *"failed to receive status: rpc error"* ]]
}

@test "summarize-blocked-egress: apk I/O error log names the APKINDEX host" {
	_write_apk_log

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "::error::Likely blocked egress: dl-cdn.alpinelinux.org"

	local summary
	summary=$(get_github_step_summary)
	[[ "$summary" == *"dl-cdn.alpinelinux.org"* ]]
	[[ "$summary" == *"temporary error (try again later)"* ]]
}

@test "summarize-blocked-egress: curl connection refused names the host" {
	_write_curl_refused_log

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "::error::Likely blocked egress: static.rust-lang.org"
}

@test "summarize-blocked-egress: clean log emits nothing and exits 0" {
	cat >"$BUILD_LOG" <<'EOF'
#10 [full 4/9] COPY . .
#10 DONE 0.3s
#11 exporting to image
#11 DONE 1.2s
EOF

	run bash "$SCRIPT"
	assert_success
	[[ "$output" != *"::error::"* ]]

	local summary
	summary=$(get_github_step_summary)
	[[ "$summary" != *"Possible blocked egress"* ]]
}

@test "summarize-blocked-egress: missing log exits 0 without annotations" {
	rm -f "$BUILD_LOG"
	# Mock docker so the buildx-history fallback stays inert
	mock_command "docker" "" 1

	run bash "$SCRIPT"
	assert_success
	[[ "$output" != *"::error::"* ]]
}

@test "summarize-blocked-egress: signature without extractable host emits generic error" {
	cat >"$BUILD_LOG" <<'EOF'
#9 [deps 2/5] RUN cargo fetch
#9 30.101 Connection timed out
EOF

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "::error::Build log contains blocked-egress signatures but no host could be extracted"
}

@test "summarize-blocked-egress: dispatcher routes STEP=summarize-blocked-egress" {
	_write_apk_log
	export STEP="summarize-blocked-egress"

	run bash "${PROJECT_ROOT}/scripts/ci/actions/build-docker.sh"
	assert_success
	assert_output --partial "::error::Likely blocked egress: dl-cdn.alpinelinux.org"
}
