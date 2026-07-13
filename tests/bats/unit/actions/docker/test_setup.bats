#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/actions/docker/setup.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"
load "../../../../helpers/github_env"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/docker/setup.sh"

setup() {
	setup_temp_dir
	save_path
	setup_github_env
	export SCRIPT
}

teardown() {
	restore_path
	teardown_github_env
	teardown_temp_dir
}

_mock_docker_ready() {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
info)
	exit 0
	;;
"buildx version")
	echo "github.com/docker/buildx mock"
	exit 0
	;;
"--version")
	echo "Docker version mock"
	exit 0
	;;
*)
	echo "unexpected docker args: $*" >&2
	exit 1
	;;
esac
EOF
	chmod +x "${mock_bin}/docker"
	export PATH="${mock_bin}:$PATH"
}

@test "setup.sh: succeeds when docker and buildx are available" {
	_mock_docker_ready

	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Docker environment ready"
}

@test "setup.sh: fails when docker is missing" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	local bash_path cmd
	mkdir -p "$mock_bin"
	bash_path="$(command -v bash)"
	# Minimal PATH with coreutils but no docker (GHA ships docker in /usr/bin).
	for cmd in dirname uname tr; do
		ln -sf "$(command -v "$cmd")" "${mock_bin}/${cmd}"
	done
	run env PATH="${mock_bin}" "$bash_path" "$SCRIPT"
	assert_failure
	assert_output --partial "Docker is not available"
}

@test "setup.sh: fails when buildx is unavailable" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
info) exit 0 ;;
"buildx version") exit 1 ;;
*) exit 1 ;;
esac
EOF
	chmod +x "${mock_bin}/docker"
	export PATH="${mock_bin}:$PATH"

	run bash "$SCRIPT"
	assert_failure
	assert_output --partial "Docker Buildx is not available"
}
