#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Offline startup boundary for wait-for-harden-runner.sh and its Docker callers

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/docker/wait-for-harden-runner.sh"
CONTRACT="${PROJECT_ROOT}/tests/helpers/docker_readiness_contract.py"

setup() {
	export RUNNER_OS=Linux RUNNER_ENVIRONMENT=github-hosted
	export HARDEN_RUNNER_STATUS_FILE="${BATS_TEST_TMPDIR}/agent.status"
	export READINESS_EVENTS="${BATS_TEST_TMPDIR}/events"
	export READINESS_PHASE="${BATS_TEST_TMPDIR}/phase"
	export REAL_TIMEOUT
	REAL_TIMEOUT="$(command -v timeout)"
	export READINESS_MODE=advance SERVICE_STATE=active DOCKER_STATE=ready
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	printf 'pending\n' >"$READINESS_PHASE"
	: >"$READINESS_EVENTS"
	cat >"${BATS_TEST_TMPDIR}/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
echo "systemctl $*" >>"$READINESS_EVENTS"
[[ "$*" == 'is-active --quiet agent.service' ]] || exit 90
if [[ "$SERVICE_STATE" == hung ]]; then /bin/sleep 2; fi
[[ "$SERVICE_STATE" == active ]]
MOCK
	cat >"${BATS_TEST_TMPDIR}/bin/docker" <<'MOCK'
#!/usr/bin/env bash
echo "docker $* $(cat "$READINESS_PHASE")" >>"$READINESS_EVENTS"
if [[ "$*" == info ]]; then
	if [[ "$DOCKER_STATE" == hung ]]; then /bin/sleep 2; fi
	if [[ "$DOCKER_STATE" != ready ]]; then
		echo 'daemon unavailable (mock)' >&2
		exit 1
	fi
elif [[ "$*" == 'buildx inspect --bootstrap' ]]; then
	if [[ "$(cat "$READINESS_PHASE")" != ready ]]; then
		echo 'error creating lease: Canceled: grpc: the client connection is closing: context canceled'
		exit 1
	fi
else
	exit 91
fi
MOCK
	cat >"${BATS_TEST_TMPDIR}/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == 1 ]] || exit 92
if [[ "$READINESS_MODE" == pending ]]; then
	exec /bin/sleep 1
fi
case "$(cat "$READINESS_PHASE")" in
pending)
	echo restarting >"$READINESS_PHASE"
	echo 'hardener restart' >>"$READINESS_EVENTS"
	;;
restarting)
	echo ready >"$READINESS_PHASE"
	printf Initialized >"$HARDEN_RUNNER_STATUS_FILE"
	echo 'hardener Initialized' >>"$READINESS_EVENTS"
	;;
esac
MOCK
	cat >"${BATS_TEST_TMPDIR}/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
echo "timeout $1" >>"$READINESS_EVENTS"
if [[ "$1" == 60s && "$READINESS_MODE" == pending ]]; then
	shift
	exec "$REAL_TIMEOUT" 0.1s "$@"
fi
if [[ "$1" == 10s && "$DOCKER_STATE" == hung ]]; then
	shift
	exec "$REAL_TIMEOUT" 0.1s "$@"
fi
exec "$REAL_TIMEOUT" "$@"
MOCK
	chmod +x "${BATS_TEST_TMPDIR}/bin/"*
	export PATH="${BATS_TEST_TMPDIR}/bin:$PATH"
}

@test "hardener readiness: waits through pending and restart despite a responsive Docker socket" {
	# This succeeds before the future restart; it must not release Buildx.
	run docker info
	assert_success
	: >"$READINESS_EVENTS"
	run bash "$SCRIPT"
	assert_success
	run cat "$READINESS_EVENTS"
	assert_output --partial $'hardener restart\nsystemctl is-active --quiet agent.service\nhardener Initialized\nsystemctl is-active --quiet agent.service\ntimeout 10s\ndocker info ready'
	[[ "$(grep -c '^docker info' "$READINESS_EVENTS")" == 1 ]]
}

@test "hardener readiness: ready status returns immediately without sleep or restart" {
	printf Initialized >"$HARDEN_RUNNER_STATUS_FILE"
	echo ready >"$READINESS_PHASE"
	run bash "$SCRIPT"
	assert_success
	run grep '^hardener ' "$READINESS_EVENTS"
	assert_failure 1
	grep -q '^docker info ready$' "$READINESS_EVENTS"
}

@test "hardener readiness: empty status is pending, not completion" {
	: >"$HARDEN_RUNNER_STATUS_FILE"
	run bash "$SCRIPT"
	assert_success
	grep -q '^hardener Initialized$' "$READINESS_EVENTS"
}

@test "hardener readiness: absent or empty status times out and never starts Docker" {
	export READINESS_MODE=pending
	local kind
	for kind in absent empty; do
		if [[ "$kind" == empty ]]; then : >"$HARDEN_RUNNER_STATUS_FILE"; fi
		run bash "$SCRIPT"
		assert_failure
		assert_output --partial 'Timed out waiting for harden-runner'
	done
	! grep -q '^docker ' "$READINESS_EVENTS"
}

@test "hardener readiness: error and unknown statuses fail closed even containing Initialized" {
	local agent_status
	for agent_status in 'Error reading config' 'Error Initialized' 'InitializedError' 'InitializedInitialized'; do
		printf '%s' "$agent_status" >"$HARDEN_RUNNER_STATUS_FILE"
		run bash "$SCRIPT"
		assert_failure
		assert_output --partial 'Unexpected harden-runner status'
	done
	! grep -q '^docker ' "$READINESS_EVENTS"
}

@test "hardener readiness: unreadable status fails closed" {
	mkdir "$HARDEN_RUNNER_STATUS_FILE"
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial 'Cannot read harden-runner status'
	! grep -q '^docker ' "$READINESS_EVENTS"
}

@test "hardener readiness: stopped agent cannot be accepted even with a ready status" {
	printf Initialized >"$HARDEN_RUNNER_STATUS_FILE"
	export SERVICE_STATE=failed
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial 'harden-runner agent.service is not active'
	! grep -q '^docker ' "$READINESS_EVENTS"
}

@test "hardener readiness: hanging service read is bounded by the completion deadline" {
	export SERVICE_STATE=hung READINESS_MODE=pending
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial 'Timed out waiting for harden-runner'
	! grep -q '^docker ' "$READINESS_EVENTS"
}

@test "hardener readiness: Docker failure after completion is preserved without retry" {
	printf Initialized >"$HARDEN_RUNNER_STATUS_FILE"
	export DOCKER_STATE=failed
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial 'Docker is unavailable after harden-runner initialized'
	assert_output --partial 'daemon unavailable (mock)'
	[[ "$(grep -c '^docker info' "$READINESS_EVENTS")" == 1 ]]
}

@test "hardener readiness: hanging Docker after completion fails its separate deadline" {
	printf Initialized >"$HARDEN_RUNNER_STATUS_FILE"
	export DOCKER_STATE=hung
	run bash "$SCRIPT"
	assert_failure
	assert_output --partial 'Docker is unavailable after harden-runner initialized'
	[[ "$(grep -c '^docker info' "$READINESS_EVENTS")" == 1 ]]
}

@test "hardener readiness: non-Linux and host-managed runners keep their existing setup" {
	local runner_pair
	for runner_pair in 'macOS github-hosted' 'Windows github-hosted' 'Linux self-hosted'; do
		read -r RUNNER_OS RUNNER_ENVIRONMENT <<<"$runner_pair"
		export RUNNER_OS RUNNER_ENVIRONMENT
		run bash "$SCRIPT"
		assert_success
	done
	[[ ! -s "$READINESS_EVENTS" ]]
}

@test "hardener readiness: every reusable Docker setup job has an unconditional barrier before QEMU or Buildx" {
	require_python_yaml
	run "$PY" "$CONTRACT" check "$PROJECT_ROOT"
	assert_success
	assert_output '7 Docker setup jobs require hardener completion'
	run "$PY" -O "$CONTRACT" check "$PROJECT_ROOT"
	assert_success
	assert_output '7 Docker setup jobs require hardener completion'
}

@test "hardener readiness: optimized Python rejects weakened caller contracts" {
	require_python_yaml
	local fixture_root="${BATS_TEST_TMPDIR}/repo" mutation
	for mutation in conditional late hardener-order sparse-checkout caller-map; do
		"$PY" - "$PROJECT_ROOT" "$fixture_root" "$mutation" <<'PY'
from pathlib import Path
import sys

import yaml

source, destination = map(Path, sys.argv[1:3])
mutation = sys.argv[3]
workflows = destination / ".github/workflows"
workflows.mkdir(parents=True, exist_ok=True)
for path in (source / ".github/workflows").glob("reusable-docker*.yml"):
    (workflows / path.name).write_text(path.read_text())
path = workflows / "reusable-docker-multiplatform-validate.yml"
workflow = yaml.safe_load(path.read_text())
steps = workflow["jobs"]["build-per-platform"]["steps"]
barrier = next(i for i, step in enumerate(steps)
               if step.get("name") == "Wait for hardener Docker readiness")
tooling = next(i for i, step in enumerate(steps) if step.get("id") == "egress")
if mutation == "conditional":
    steps[barrier]["if"] = "false"
elif mutation == "late":
    steps.append(steps.pop(barrier))
elif mutation == "hardener-order":
    steps.insert(tooling, steps.pop(barrier))
elif mutation == "sparse-checkout":
    steps[tooling]["with"]["sparse-checkout-extra"] = "docs/"
elif mutation == "caller-map":
    del workflow["jobs"]["build-per-platform"]
path.write_text(yaml.safe_dump(workflow))
PY
		run "$PY" -O "$CONTRACT" check "$fixture_root"
		assert_failure
		assert_output --partial 'AssertionError'
	done
}

@test "hardener readiness: validate setup commands cannot cross the pending restart boundary" {
	require_python_yaml
	local command_file="${BATS_TEST_TMPDIR}/setup.sh"
	# Replay validate/build-per-platform; the structural check covers all seven jobs.
	# Emit that workflow's barrier (if present), followed by simulated Buildx.
	# Without a barrier this deterministically fails with the original lease error.
	"$PY" "$CONTRACT" commands "$PROJECT_ROOT" >"$command_file"
	run bash -e "$command_file"
	assert_success
	grep -q '^docker buildx inspect --bootstrap ready$' "$READINESS_EVENTS"
	! grep -q '^docker buildx inspect --bootstrap pending$' "$READINESS_EVENTS"
}
