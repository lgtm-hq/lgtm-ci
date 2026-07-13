#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/health-lib.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"

LIB="${PROJECT_ROOT}/scripts/ci/actions/docker/health-lib.sh"
ACTIONS_LIB="${PROJECT_ROOT}/scripts/ci/lib/actions.sh"

setup() {
	setup_temp_dir
	save_path
}

teardown() {
	restore_path
	teardown_temp_dir
}

_install_health_mocks() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	local docker_calls="${BATS_TEST_TMPDIR}/mock_calls_docker"
	mkdir -p "$mock_bin"
	: >"$docker_calls"

	# docker: run prints a container id; logs/rm succeed
	cat >"${mock_bin}/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >> '${docker_calls}'
case "\$1" in
run)
	echo "cid123"
	exit 0
	;;
logs|rm)
	exit 0
	;;
*)
	exit 0
	;;
esac
EOF
	chmod +x "${mock_bin}/docker"

	# macOS/CI-safe timeout: ignore duration, run remaining args
	cat >"${mock_bin}/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
	chmod +x "${mock_bin}/timeout"

	# Make port_listening succeed immediately via nc
	cat >"${mock_bin}/nc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "${mock_bin}/nc"

	export PATH="${mock_bin}:$PATH"
}

@test "health-lib.sh: parse_duration_seconds accepts Ns form" {
	run bash -c '
		source "'"$ACTIONS_LIB"'"
		source "'"$LIB"'"
		parse_duration_seconds "45s"
	'
	assert_success
	assert_output "45"
}

@test "health-lib.sh: parse_duration_seconds accepts bare seconds" {
	run bash -c '
		source "'"$ACTIONS_LIB"'"
		source "'"$LIB"'"
		parse_duration_seconds "12"
	'
	assert_success
	assert_output "12"
}

@test "health-lib.sh: parse_duration_seconds defaults to 30s" {
	run bash -c '
		source "'"$ACTIONS_LIB"'"
		source "'"$LIB"'"
		parse_duration_seconds
	'
	assert_success
	assert_output "30"
}

@test "health-lib.sh: parse_duration_seconds rejects invalid input" {
	run bash -c '
		source "'"$ACTIONS_LIB"'"
		source "'"$LIB"'"
		parse_duration_seconds "30x"
	'
	assert_failure
	assert_output --partial "Invalid HEALTH_CHECK_TIMEOUT"
}

@test "health-lib.sh: can be sourced multiple times" {
	run bash -c '
		source "'"$ACTIONS_LIB"'"
		source "'"$LIB"'"
		source "'"$LIB"'"
		parse_duration_seconds "5s"
	'
	assert_success
	assert_output "5"
}

@test "health-lib.sh: run_health_check passes without port" {
	_install_health_mocks

	run bash -c '
		source "'"$ACTIONS_LIB"'"
		source "'"$LIB"'"
		export IMAGE="ghcr.io/org/repo:local"
		export HEALTH_CHECK_CMD="true"
		unset HEALTH_CHECK_PORT PLATFORM || true
		export HEALTH_CHECK_TIMEOUT="5s"
		run_health_check
	'
	assert_success
	assert_output --partial "Health check passed"
	run grep -F "run -d ghcr.io/org/repo:local" "${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
}

@test "health-lib.sh: run_health_check publishes port and uses platform" {
	_install_health_mocks

	run bash -c '
		source "'"$ACTIONS_LIB"'"
		source "'"$LIB"'"
		export IMAGE="ghcr.io/org/repo:local"
		export HEALTH_CHECK_CMD="true"
		export HEALTH_CHECK_PORT="8080"
		export PLATFORM="linux/arm64"
		export HEALTH_CHECK_TIMEOUT="5s"
		run_health_check
	'
	assert_success
	run grep -F "run -d -p 127.0.0.1:8080:8080 --platform linux/arm64 ghcr.io/org/repo:local" \
		"${BATS_TEST_TMPDIR}/mock_calls_docker"
	assert_success
}

@test "health-lib.sh: run_health_check fails when health command fails" {
	_install_health_mocks

	run bash -c '
		source "'"$ACTIONS_LIB"'"
		source "'"$LIB"'"
		export IMAGE="ghcr.io/org/repo:local"
		export HEALTH_CHECK_CMD="false"
		unset HEALTH_CHECK_PORT || true
		export HEALTH_CHECK_TIMEOUT="5s"
		run_health_check
	'
	assert_failure
	assert_output --partial "Health check command failed"
}

@test "health-lib.sh: run_health_check requires IMAGE" {
	run bash -c '
		source "'"$ACTIONS_LIB"'"
		source "'"$LIB"'"
		unset IMAGE || true
		export HEALTH_CHECK_CMD="true"
		run_health_check
	'
	assert_failure
	assert_output --partial "IMAGE is required"
}
