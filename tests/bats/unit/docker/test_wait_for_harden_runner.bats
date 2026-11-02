#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Offline startup and deadline boundaries for wait-for-harden-runner.sh
# Bats isolates each test's environment; negated assertions end their test body.
# shellcheck disable=SC2030,SC2031,SC2314

load "../../../helpers/docker_readiness"

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
		refute_output --partial 'invalid value for trace file descriptor'
		refute_output --partial 'kcov@'
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
