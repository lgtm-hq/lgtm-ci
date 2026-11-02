#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Offline startup boundary for wait-for-harden-runner.sh and its Docker callers

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/docker/wait-for-harden-runner.sh"
CONTRACT="${PROJECT_ROOT}/tests/helpers/docker_readiness_contract.py"
export TIMEOUT_CONTRACT="${PROJECT_ROOT}/tests/helpers/docker_readiness_timeout.py"

setup() {
	export RUNNER_OS=Linux RUNNER_ENVIRONMENT=github-hosted
	export HARDEN_RUNNER_STATUS_FILE="${BATS_TEST_TMPDIR}/agent.status"
	export READINESS_EVENTS="${BATS_TEST_TMPDIR}/events"
	export READINESS_PHASE="${BATS_TEST_TMPDIR}/phase"
	export REAL_TIMEOUT
	REAL_TIMEOUT=""
	# Back the isolated binary layouts with a verified GNU implementation.
	local candidate version
	for candidate in gnutimeout timeout; do
		if version="$("$candidate" --version 2>/dev/null)" && [[ "$version" == 'timeout (GNU coreutils) '* ]]; then
			REAL_TIMEOUT="$(command -v "$candidate")"
			break
		fi
	done
	: "${REAL_TIMEOUT:?GNU timeout is required for the real signal fixtures}"
	export READINESS_MODE=advance SERVICE_STATE=active DOCKER_STATE=ready
	export STATUS_STATE=ready
	export WORKFLOW_REPOSITORY=lgtm-hq/lgtm-ci WORKFLOW_SHA
	WORKFLOW_SHA=1111111111111111111111111111111111111111
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	printf 'pending\n' >"$READINESS_PHASE"
	: >"$READINESS_EVENTS"
	cat >"${BATS_TEST_TMPDIR}/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
echo "systemctl $*" >>"$READINESS_EVENTS"
[[ "$*" == 'is-active --quiet agent.service' ]] || exit 90
if [[ "$SERVICE_STATE" == ignores-term ]]; then
	exec "$READINESS_PYTHON" -S "$TIMEOUT_CONTRACT" ignore-term systemctl
fi
if [[ "$SERVICE_STATE" == hung ]]; then /bin/sleep 2; fi
[[ "$SERVICE_STATE" == active ]]
MOCK
	cat >"${BATS_TEST_TMPDIR}/bin/docker" <<'MOCK'
#!/usr/bin/env bash
echo "docker $* $(cat "$READINESS_PHASE")" >>"$READINESS_EVENTS"
if [[ "$*" == info ]]; then
	if [[ "$DOCKER_STATE" == ignores-term ]]; then
		exec "$READINESS_PYTHON" -S "$TIMEOUT_CONTRACT" ignore-term docker
	fi
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
	cat >"${BATS_TEST_TMPDIR}/bin/cat" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == "-- $HARDEN_RUNNER_STATUS_FILE" && "$STATUS_STATE" == ignores-term ]]; then
	exec "$READINESS_PYTHON" -S "$TIMEOUT_CONTRACT" ignore-term cat
fi
exec /bin/cat "$@"
MOCK
	cat >"${BATS_TEST_TMPDIR}/gnu-timeout-wrapper" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == --version ]]; then exec "$REAL_TIMEOUT" "$@"; fi
options=()
if [[ "$1" == --kill-after=* ]]; then
	options+=("$1")
	shift
fi
echo "deadline ${0##*/} $1" >>"$READINESS_EVENTS"
echo "timeout $1" >>"$READINESS_EVENTS"
if [[ "$READINESS_MODE" == ignores-term ]]; then
	# Shorten the real deadline/grace; never supply a missing escalation option.
	if [[ ${#options[@]} == 1 ]]; then options=(--kill-after=0.1s); fi
	shift
	exec "$REAL_TIMEOUT" "${options[@]}" 1s "$@"
fi
if [[ "$1" == 60s && "$READINESS_MODE" == pending ]]; then
	shift
	exec "$REAL_TIMEOUT" "${options[@]}" 0.1s "$@"
fi
if [[ "$1" == 10s && "$DOCKER_STATE" == hung ]]; then
	shift
	exec "$REAL_TIMEOUT" "${options[@]}" 0.1s "$@"
fi
exec "$REAL_TIMEOUT" "${options[@]}" "$@"
MOCK
	chmod +x "${BATS_TEST_TMPDIR}/gnu-timeout-wrapper"
	configure_timeout_layout gnu-prefixed
	chmod +x "${BATS_TEST_TMPDIR}/bin/"*
	ln -s "$(command -v bash)" "${BATS_TEST_TMPDIR}/bin/bash"
	export PATH="${BATS_TEST_TMPDIR}/bin:$PATH"
}

configure_timeout_layout() {
	local layout="$1" name
	rm -f "${BATS_TEST_TMPDIR}/bin/"{gnutimeout,timeout}
	for name in gnutimeout timeout; do
		if [[ "$layout" == missing || ( "$layout" == gnu-timeout && "$name" == gnutimeout ) ]]; then
			continue
		fi
		if [[ ( "$layout" == gnu-prefixed && "$name" == gnutimeout ) || ( "$layout" == gnu-timeout* && "$name" == timeout ) ]]; then
			cp "${BATS_TEST_TMPDIR}/gnu-timeout-wrapper" "${BATS_TEST_TMPDIR}/bin/$name"
		else
			cat >"${BATS_TEST_TMPDIR}/bin/$name" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == --version ]]; then
	echo 'timeout (uutils coreutils) 0.10.0'
	exit 0
fi
echo "unsupported timeout invoked: $*" >>"$READINESS_EVENTS"
exit 93
MOCK
		fi
		chmod +x "${BATS_TEST_TMPDIR}/bin/$name"
	done
}

@test "hardener readiness: production selects GNU for both deadlines across binary layouts" {
	local layout selected
	printf Initialized >"$HARDEN_RUNNER_STATUS_FILE"
	for layout in gnu-timeout gnu-prefixed gnu-timeout-unsupported-prefix; do
		configure_timeout_layout "$layout"
		: >"$READINESS_EVENTS"
		run env PATH="${BATS_TEST_TMPDIR}/bin" bash "$SCRIPT"
		assert_success
		selected=timeout
		if [[ "$layout" == gnu-prefixed ]]; then selected=gnutimeout; fi
		grep -q "^deadline $selected 60s$" "$READINESS_EVENTS"
		grep -q "^deadline $selected 10s$" "$READINESS_EVENTS"
		! grep -q '^unsupported timeout invoked:' "$READINESS_EVENTS"
	done
}

@test "hardener readiness: unsupported or missing timeout fails before service and Docker" {
	local layout
	for layout in unsupported missing; do
		configure_timeout_layout "$layout"
		run env PATH="${BATS_TEST_TMPDIR}/bin" bash "$SCRIPT"
		assert_failure 1
		assert_output --partial 'GNU timeout is required (gnutimeout or timeout)'
		[[ ! -s "$READINESS_EVENTS" ]]
	done
}

@test "hardener readiness: waits through pending and restart despite a responsive Docker socket" {
	# This succeeds before the future restart; it must not release Buildx.
	run docker info
	assert_success
	: >"$READINESS_EVENTS"
	run bash "$SCRIPT"
	assert_success
	run grep -v '^deadline ' "$READINESS_EVENTS"
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
	assert_failure 1
	assert_output --partial 'Docker info timed out after harden-runner initialized (10s deadline + 2s kill grace)'
	[[ "$(grep -c '^docker info' "$READINESS_EVENTS")" == 1 ]]
}

check_ignoring_term_boundary() {
	require_python_yaml
	export READINESS_PYTHON READINESS_MODE=ignores-term
	READINESS_PYTHON="$(command -v "$PY")"
	local boundary="$1" layout selected
	case "$boundary" in
	systemctl) export SERVICE_STATE=ignores-term ;;
	cat) export STATUS_STATE=ignores-term ;;
	docker) export DOCKER_STATE=ignores-term ;;
	esac
	printf Initialized >"$HARDEN_RUNNER_STATUS_FILE"
	for layout in gnu-timeout gnu-prefixed; do
		configure_timeout_layout "$layout"
		: >"$READINESS_EVENTS"
		run env PATH="${BATS_TEST_TMPDIR}/bin" "$READINESS_PYTHON" "$TIMEOUT_CONTRACT" "$SCRIPT"
		# Prove the child installed SIG_IGN before accepting any deadline result.
		grep -q "^ignoring TERM: $boundary$" "$READINESS_EVENTS"
		assert_success
		assert_output --partial 'bounded setup failure; no live fixture groups'
		selected=timeout
		if [[ "$layout" == gnu-prefixed ]]; then selected=gnutimeout; fi
		grep -q "^deadline $selected 60s$" "$READINESS_EVENTS"
		if [[ "$boundary" == docker ]]; then
			assert_output --partial 'Docker info timed out after harden-runner initialized (10s deadline + 2s kill grace)'
			grep -q "^deadline $selected 10s$" "$READINESS_EVENTS"
			[[ "$(grep -c '^docker info' "$READINESS_EVENTS")" == 1 ]]
		else
			assert_output --partial 'Timed out waiting for harden-runner to finish Docker initialization (60s deadline + 2s kill grace)'
			run grep '^docker ' "$READINESS_EVENTS"
			assert_failure 1
		fi
	done
}

@test "hardener readiness: real deadline kills a TERM-ignoring service read" {
	check_ignoring_term_boundary systemctl
}

@test "hardener readiness: real deadline kills a TERM-ignoring status read" {
	check_ignoring_term_boundary cat
}

@test "hardener readiness: real deadline kills a TERM-ignoring Docker client" {
	check_ignoring_term_boundary docker
}

@test "hardener readiness: non-Linux and host-managed runners keep their existing setup" {
	configure_timeout_layout missing
	local runner_pair
	for runner_pair in 'macOS github-hosted' 'Windows github-hosted' 'Linux self-hosted' 'Windows self-hosted' 'macOS self-hosted'; do
		read -r RUNNER_OS RUNNER_ENVIRONMENT <<<"$runner_pair"
		export RUNNER_OS RUNNER_ENVIRONMENT
		run env PATH="${BATS_TEST_TMPDIR}/bin" bash "$SCRIPT"
		assert_success
	done
	[[ ! -s "$READINESS_EVENTS" ]]
}

@test "hardener readiness: every reusable Docker setup job requires readiness exactly on hosted Linux before QEMU or Buildx" {
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
	local fixture_root="${BATS_TEST_TMPDIR}/repo" mutation workflow job
	while read -r workflow job; do
		for mutation in \
			conditional nonfatal late hardener-order hardener-late \
			missing-hardener missing-tooling sparse-checkout caller-map missing-identity \
			missing-checkout identity-conditional identity-nonfatal identity-repository identity-sha \
			identity-body checkout-order checkout-late checkout-conditional checkout-nonfatal \
			checkout-pin checkout-ref checkout-repository checkout-path checkout-sparse \
			checkout-cone checkout-credentials tooling-override \
			identity-unconditional identity-linux-only identity-hosted-only identity-widened identity-env \
			checkout-unconditional checkout-linux-only checkout-hosted-only checkout-widened checkout-env \
			barrier-unconditional barrier-linux-only barrier-hosted-only barrier-widened barrier-env; do
			"$PY" - "$PROJECT_ROOT" "$fixture_root" "$mutation" "$workflow" "$job" <<'PY'
from pathlib import Path
import sys

import yaml

source, destination = map(Path, sys.argv[1:3])
mutation = sys.argv[3]
workflows = destination / ".github/workflows"
workflows.mkdir(parents=True, exist_ok=True)
for path in (source / ".github/workflows").glob("reusable-docker*.yml"):
    (workflows / path.name).write_text(path.read_text())
path = workflows / sys.argv[4]
workflow = yaml.safe_load(path.read_text())
steps = workflow["jobs"][sys.argv[5]]["steps"]
barrier = next(i for i, step in enumerate(steps)
               if step.get("name") == "Wait for hardener Docker readiness")
tooling = next(i for i, step in enumerate(steps) if step.get("id") == "egress")
hardener = next(i for i, step in enumerate(steps)
                if step.get("uses", "").startswith("step-security/harden-runner@"))
identity = next(i for i, step in enumerate(steps)
                if step.get("name") == "Require workflow readiness identity")
checkout = next(i for i, step in enumerate(steps)
                if step.get("name") == "Checkout workflow readiness helper")
if mutation.rsplit("-", 1)[-1] in (
    "unconditional", "only", "widened", "env",
):
    stage, condition = mutation.split("-", 1)
    target = steps[{"identity": identity, "checkout": checkout, "barrier": barrier}[stage]]
    if condition == "unconditional":
        del target["if"]
    else:
        target["if"] = {
            "linux-only": "${{ runner.os == 'Linux' }}",
            "hosted-only": "${{ runner.environment == 'github-hosted' }}",
            "widened": "${{ runner.os == 'Linux' || runner.environment == 'github-hosted' }}",
            "env": "${{ env.RUNNER_OS == 'Linux' && env.RUNNER_ENVIRONMENT == 'github-hosted' }}",
        }[condition]
elif mutation == "conditional":
    steps[barrier]["if"] = "false"
elif mutation == "nonfatal":
    steps[barrier]["continue-on-error"] = True
elif mutation == "late":
    steps.append(steps.pop(barrier))
elif mutation == "hardener-order":
    steps.insert(tooling, steps.pop(barrier))
elif mutation == "hardener-late":
    steps.insert(tooling + 1, steps.pop(hardener))
elif mutation == "missing-hardener":
    steps.pop(hardener)
elif mutation == "missing-tooling":
    steps.pop(tooling)
elif mutation == "sparse-checkout":
    steps[tooling]["with"]["sparse-checkout-extra"] = "docs/"
elif mutation == "caller-map":
    del workflow["jobs"][sys.argv[5]]
elif mutation == "missing-identity":
    steps.pop(identity)
elif mutation == "missing-checkout":
    steps.pop(checkout)
elif mutation == "identity-conditional":
    steps[identity]["if"] = "false"
elif mutation == "identity-nonfatal":
    steps[identity]["continue-on-error"] = True
elif mutation == "identity-repository":
    steps[identity]["env"]["WORKFLOW_REPOSITORY"] = "lgtm-hq/lgtm-ci"
elif mutation == "identity-sha":
    steps[identity]["env"]["WORKFLOW_SHA"] = "${{ inputs.tooling-ref }}"
elif mutation == "identity-body":
    steps[identity]["run"] = "true"
elif mutation == "checkout-order":
    steps.insert(identity, steps.pop(checkout))
elif mutation == "checkout-late":
    steps.append(steps.pop(checkout))
elif mutation == "checkout-conditional":
    steps[checkout]["if"] = "false"
elif mutation == "checkout-nonfatal":
    steps[checkout]["continue-on-error"] = True
elif mutation == "checkout-pin":
    steps[checkout]["uses"] = "actions/checkout@main"
elif mutation == "checkout-ref":
    steps[checkout]["with"]["ref"] = "${{ inputs.tooling-ref || github.sha || 'main' }}"
elif mutation == "checkout-repository":
    steps[checkout]["with"]["repository"] = "${{ github.repository }}"
elif mutation == "checkout-path":
    steps[checkout]["with"]["path"] = ".lgtm-ci-tooling"
elif mutation == "checkout-sparse":
    steps[checkout]["with"]["sparse-checkout"] = "scripts/ci/"
elif mutation == "checkout-cone":
    steps[checkout]["with"]["sparse-checkout-cone-mode"] = True
elif mutation == "checkout-credentials":
    steps[checkout]["with"]["persist-credentials"] = True
elif mutation == "tooling-override":
    steps[tooling]["with"]["tooling-ref"] = "${{ job.workflow_sha }}"
path.write_text(yaml.safe_dump(workflow))
PY
			run "$PY" -O "$CONTRACT" check "$fixture_root"
			assert_failure
			assert_output --partial 'AssertionError'
			case "$mutation" in
			missing-hardener) assert_output --partial 'missing harden-runner step' ;;
			missing-tooling) assert_output --partial 'missing tooling checkout' ;;
			esac
		done
	done < <("$PY" "$CONTRACT" callers "$PROJECT_ROOT")
}

@test "hardener readiness: validate setup commands cannot cross the pending restart boundary" {
	require_python_yaml
	cd "$BATS_TEST_TMPDIR"
	# Replay actual conditions and shell steps; Docker actions use the local stub.
	# Without a barrier this deterministically fails with the original lease error.
	run "$PY" "$CONTRACT" replay "$PROJECT_ROOT"
	assert_success
	grep -q '^docker buildx inspect --bootstrap ready$' "$READINESS_EVENTS"
	! grep -q '^docker buildx inspect --bootstrap pending$' "$READINESS_EVENTS"
}

@test "hardener readiness: all seven workflow commands work with released tooling that predates the helper" {
	require_python_yaml
	local old_ref=f63b85534ce3a561f177c4ee3417b17c04f14a8b
	local tooling="${BATS_TEST_TMPDIR}/.lgtm-ci-tooling" workflow job
	# Minimal old-ref sparse layout: scripts/ci exists, this newer helper does not.
	# The exact released tree reproduction is retained in operator evidence.
	mkdir -p "$tooling/scripts/ci"
	printf '%s\n' "$old_ref" >"$tooling/released-ref"
	[[ -d "$tooling/scripts/ci" ]]
	[[ ! -e "$tooling/scripts/ci/docker/wait-for-harden-runner.sh" ]]
	cd "$BATS_TEST_TMPDIR"
	while read -r workflow job; do
		: >"$READINESS_EVENTS"
		rm -f "$HARDEN_RUNNER_STATUS_FILE"
		echo pending >"$READINESS_PHASE"
		run "$PY" "$CONTRACT" replay "$PROJECT_ROOT" "$workflow" "$job"
		assert_success
		assert_output --partial 'harden-runner initialized; Docker setup may proceed'
		grep -q '^docker buildx inspect --bootstrap ready$' "$READINESS_EVENTS"
		[[ "$(grep -c '^docker info' "$READINESS_EVENTS")" == 1 ]]
		# A poison helper in caller tooling must never supply this workflow barrier.
		mkdir -p "$tooling/scripts/ci/docker"
		printf 'exit 99\n' >"$tooling/scripts/ci/docker/wait-for-harden-runner.sh"
		run "$PY" "$CONTRACT" replay "$PROJECT_ROOT" "$workflow" "$job"
		assert_success
		rm "$tooling/scripts/ci/docker/wait-for-harden-runner.sh"
	done < <("$PY" "$CONTRACT" callers "$PROJECT_ROOT")
}

@test "hardener readiness: all seven identity guards reject missing or mutable identity before running the helper" {
	require_python_yaml
	local workflow job identity repository sha
	cd "$BATS_TEST_TMPDIR"
	# No helper is present: the actual guard must fail before checkout or Docker.
	while read -r workflow job; do
		for identity in missing-repository missing-sha mutable-sha short-sha; do
			repository="$WORKFLOW_REPOSITORY"
			sha="$WORKFLOW_SHA"
			case "$identity" in
			missing-repository) repository="" ;;
			missing-sha) sha="" ;;
			mutable-sha) sha=main ;;
			short-sha) sha=86958e1 ;;
			esac
			run env WORKFLOW_REPOSITORY="$repository" WORKFLOW_SHA="$sha" "$PY" "$CONTRACT" replay "$PROJECT_ROOT" "$workflow" "$job"
			assert_failure 1
			assert_output --partial 'Immutable workflow identity is required for Docker readiness'
			refute_output --partial 'No such file'
			refute_output --partial 'replay: Checkout workflow readiness helper'
			[[ ! -e .lgtm-ci-readiness ]]
			[[ ! -s "$READINESS_EVENTS" ]]
		done
	done < <("$PY" "$CONTRACT" callers "$PROJECT_ROOT")
}

@test "hardener readiness: all seven jobs skip only readiness on other runners without identity or helper" {
	require_python_yaml
	local workflow job runner_pair helper
	cd "$BATS_TEST_TMPDIR"
	# The helper source is absent too, so even an attempted checkout must fail.
	mkdir -p repo/.github
	cp -R "$PROJECT_ROOT/.github/workflows" repo/.github/
	export WORKFLOW_REPOSITORY="" WORKFLOW_SHA=""
	configure_timeout_layout missing
	for runner_pair in 'Linux self-hosted' 'Windows self-hosted' 'macOS self-hosted' \
		'Windows github-hosted' 'macOS github-hosted'; do
		read -r RUNNER_OS RUNNER_ENVIRONMENT <<<"$runner_pair"
		export RUNNER_OS RUNNER_ENVIRONMENT
		while read -r workflow job; do
			for helper in missing poison; do
				rm -rf .lgtm-ci-readiness
				if [[ "$helper" == poison ]]; then
					mkdir -p .lgtm-ci-readiness/scripts/ci/docker
					printf 'echo poison-readiness; exit 99\n' >.lgtm-ci-readiness/scripts/ci/docker/wait-for-harden-runner.sh
				fi
				: >"$READINESS_EVENTS"
				# Normal Docker setup is allowed immediately on these runners.
				echo ready >"$READINESS_PHASE"
				run "$PY" "$CONTRACT" replay "$BATS_TEST_TMPDIR/repo" "$workflow" "$job"
				assert_success
				refute_output --partial 'replay: Require workflow readiness identity'
				refute_output --partial 'replay: Checkout workflow readiness helper'
				refute_output --partial 'replay: Wait for hardener Docker readiness'
				refute_output --partial 'poison-readiness'
				[[ "$(cat "$READINESS_EVENTS")" == 'docker buildx inspect --bootstrap ready' ]]
				if [[ "$helper" == missing ]]; then [[ ! -e .lgtm-ci-readiness ]]; fi
			done
		done < <("$PY" "$CONTRACT" callers "$PROJECT_ROOT")
	done
}

@test "hardener readiness: all seven hosted Linux jobs fail closed when their own helper is missing" {
	require_python_yaml
	local workflow job
	cd "$BATS_TEST_TMPDIR"
	mkdir -p repo/.github .lgtm-ci-tooling/scripts/ci/docker
	cp -R "$PROJECT_ROOT/.github/workflows" repo/.github/
	# Caller tooling cannot rescue a missing workflow helper or bypass readiness.
	printf 'echo poison-tooling; exit 0\n' >.lgtm-ci-tooling/scripts/ci/docker/wait-for-harden-runner.sh
	while read -r workflow job; do
		: >"$READINESS_EVENTS"
		run "$PY" "$CONTRACT" replay "$BATS_TEST_TMPDIR/repo" "$workflow" "$job"
		assert_failure
		assert_output --partial 'replay: Checkout workflow readiness helper'
		refute_output --partial 'poison-tooling'
		[[ ! -s "$READINESS_EVENTS" ]]
	done < <("$PY" "$CONTRACT" callers "$PROJECT_ROOT")
}
