#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/bootstrap/verify-harden-runner-agent.sh (#1203)
#
# The source script of the generated "Verify harden-runner agent" steps that
# follow every harden-runner step. sync_inline_blocks.py --check keeps every
# inline copy equal to this body; test_harden_runner_verify_contract.py pins
# where the copies sit. systemctl, date and sleep are stubbed: the clock only
# moves when the script sleeps, so the 60s deadline and the 3s settle period
# after Initialized run instantly.

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/bootstrap/verify-harden-runner-agent.sh"

setup() {
	scrub_ci_step_env
	ROOT="${BATS_TEST_TMPDIR}/root"
	STUBS="${BATS_TEST_TMPDIR}/bin"
	CLOCK="${BATS_TEST_TMPDIR}/clock"
	mkdir -p "$ROOT/etc/systemd/system" "$ROOT/home/agent" "$STUBS"
	: >"$ROOT/etc/systemd/system/agent.service"
	printf '{"repo":"o/r","egress_policy":"block","private":false}' \
		>"$ROOT/home/agent/agent.json"
	printf '1000' >"$CLOCK"
	cat >"$STUBS/systemctl" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == 'is-active --quiet agent.service' ]] || exit 90
[[ "$SERVICE_STATE" == active ]]
STUB
	cat >"$STUBS/date" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == +%s ]] || exit 90
cat "$CLOCK"
STUB
	# Advance the clock; write the status once the clock reaches APPEAR_AT.
	cat >"$STUBS/sleep" <<'STUB'
#!/usr/bin/env bash
now=$(($(cat "$CLOCK") + $1))
printf '%s' "$now" >"$CLOCK"
if [[ -n "${APPEAR_AT:-}" ]] && ((now >= APPEAR_AT)); then
	printf '%s' "$APPEAR_STATUS" >"$HARDEN_RUNNER_ROOT/home/agent/agent.status"
fi
STUB
	chmod +x "$STUBS"/*
	# Symlinks to real tools last: chmod would follow them to root-owned
	# binaries on Linux runners.
	ln -s "$BASH" "$STUBS/bash"
	ln -s "$(command -v grep)" "$STUBS/grep"
	ln -s "$(command -v cat)" "$STUBS/cat"
}

# Run the script in a clean environment: only the stubs are on PATH, and the
# runner variables are the ones a GitHub-hosted Linux runner sets unless the
# caller overrides them (VAR=value arguments come after the defaults).
_verify() {
	run env -i PATH="$STUBS" CLOCK="$CLOCK" HARDEN_RUNNER_ROOT="$ROOT" \
		SERVICE_STATE=active EGRESS_POLICY=block USER=runner \
		RUNNER_ENVIRONMENT=github-hosted RUNNER_OS=Linux "$@" \
		"$BASH" "$SCRIPT"
}

_status() {
	printf '%s' "$1" >"$ROOT/home/agent/agent.status"
}

@test "verify-harden-runner-agent: active and Initialized passes" {
	_status Initialized
	_verify
	assert_success
	assert_output "harden-runner agent is active and initialized with egress-policy block"
	# Only the settle period after Initialized.
	[[ "$(cat "$CLOCK")" == 1003 ]]
}

@test "verify-harden-runner-agent: inactive agent.service fails" {
	_status Initialized
	_verify SERVICE_STATE=failed
	assert_failure 1
	assert_output --partial "::error title=harden-runner agent failed::agent.service is not active"
}

@test "verify-harden-runner-agent: a status that appears Initialized in time passes" {
	_verify APPEAR_AT=1030 APPEAR_STATUS=Initialized
	assert_success
	assert_output --partial "active and initialized"
	[[ "$(cat "$CLOCK")" == 1033 ]]
}

@test "verify-harden-runner-agent: an empty status file is pending, not done" {
	_status ""
	_verify APPEAR_AT=1005 APPEAR_STATUS=Initialized
	assert_success
	[[ "$(cat "$CLOCK")" == 1008 ]]
}

@test "verify-harden-runner-agent: never Initialized times out after 60s" {
	_verify
	assert_failure 1
	assert_output --partial "agent.status is not Initialized after 60s"
	[[ "$(cat "$CLOCK")" == 1060 ]]
}

@test "verify-harden-runner-agent: a status after the deadline is too late" {
	_verify APPEAR_AT=1061 APPEAR_STATUS=Initialized
	assert_failure 1
	assert_output --partial "not Initialized after 60s"
}

@test "verify-harden-runner-agent: the service stopping mid-wait fails" {
	cat >>"$STUBS/sleep" <<'STUB'
printf '#!/usr/bin/env bash\nexit 3\n' >"${CLOCK%/*}/bin/systemctl"
STUB
	_verify
	assert_failure 1
	assert_output --partial "agent.service is not active"
}

@test "verify-harden-runner-agent: unexpected statuses fail closed" {
	local agent_status
	for agent_status in 'Error reading config file x' 'InitializedError' \
		'Initialized Initialized'; do
		_status "$agent_status"
		_verify
		assert_failure 1
		assert_output --partial "::error title=harden-runner agent failed::unexpected agent status"
	done
}

@test "verify-harden-runner-agent: audit and other policies are rejected everywhere" {
	local policy env
	_status Initialized
	for env in github-hosted self-hosted; do
		for policy in audit Block "" "block "; do
			_verify EGRESS_POLICY="$policy" RUNNER_ENVIRONMENT="$env"
			assert_failure 1
			assert_output --partial "::error title=egress-policy rejected::"
			assert_output --partial "Set egress-policy: block with an allow-list"
		done
	done
}

@test "verify-harden-runner-agent: hosted macOS and Windows get a notice and skip" {
	local runner
	for runner in github-hosted/macOS github-hosted/Windows; do
		_verify RUNNER_ENVIRONMENT="${runner%/*}" RUNNER_OS="${runner#*/}" \
			SERVICE_STATE=failed GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
		assert_success
		assert_output "::notice title=hardening not verified::harden-runner is not verified on this runner (${runner/\// }); no egress enforcement claimed"
		[[ ! -e "$BATS_TEST_TMPDIR/summary" ]]
	done
}

@test "verify-harden-runner-agent: self-hosted runners warn and write the step summary" {
	local runner line summary="$BATS_TEST_TMPDIR/summary"
	for runner in self-hosted/Linux self-hosted/macOS self-hosted/Windows; do
		: >"$summary"
		_verify RUNNER_ENVIRONMENT="${runner%/*}" RUNNER_OS="${runner#*/}" \
			SERVICE_STATE=failed GITHUB_STEP_SUMMARY="$summary"
		assert_success
		line="harden-runner egress enforcement not verified; this job may run without enforcement (RUNNER_ENVIRONMENT=self-hosted, RUNNER_OS=${runner#*/})"
		assert_output "::warning title=hardening not verified::$line"
		[[ "$(cat "$summary")" == "$line" ]]
	done
}

@test "verify-harden-runner-agent: self-hosted without GITHUB_STEP_SUMMARY still warns" {
	_verify RUNNER_ENVIRONMENT=self-hosted SERVICE_STATE=failed
	assert_success
	assert_output --partial "::warning title=hardening not verified::"
	assert_output --partial "this job may run without enforcement"
}

@test "verify-harden-runner-agent: Initialized then the service stops in the settle period fails" {
	_status Initialized
	cat >>"$STUBS/sleep" <<'STUB'
printf '#!/usr/bin/env bash\nexit 3\n' >"${CLOCK%/*}/bin/systemctl"
STUB
	_verify
	assert_failure 1
	assert_output "::error title=harden-runner agent failed::agent.service stopped just after Initialized; egress is not enforced"
	[[ "$(cat "$CLOCK")" == 1003 ]]
}

@test "verify-harden-runner-agent: a healthy v0.18.0 agent.log passes" {
	# Non-fatal errors and root-process arguments naming the fatal messages.
	_status Initialized
	install_fixture security/harden-runner-agent/healthy-agent.log \
		"$ROOT/home/agent/agent.log"
	_verify
	assert_success
	assert_output "harden-runner agent is active and initialized with egress-policy block"
}

@test "verify-harden-runner-agent: Initialized then agent.log reports a revert fails" {
	local message
	for message in 'Reverted changes' \
		'Error in Initialization lookup dns.google: no such host' \
		'Error in Initialization'; do
		_status Initialized
		install_fixture security/harden-runner-agent/healthy-agent.log \
			"$ROOT/home/agent/agent.log"
		printf 'Fri, 13 Nov 2026 10:00:04 GMT:%s\n' "$message" \
			>>"$ROOT/home/agent/agent.log"
		_verify
		assert_failure 1
		assert_output "::error title=harden-runner agent failed::agent.log reports a reverted initialization; egress is not enforced"
	done
}

@test "verify-harden-runner-agent: unanchored or extended revert text passes" {
	local message
	_status Initialized
	for message in 'Reverted changes' 'Error in Initialization' \
		'Fri, 13 Nov 2026 10:00:04 GMT:Reverted changes now' \
		'Fri, 13 Nov 2026 10:00:04 GMT:Error in Initializationx' \
		'x Fri, 13 Nov 2026 10:00:04 GMT:Reverted changes'; do
		printf '%s\n' "$message" >"$ROOT/home/agent/agent.log"
		_verify
		assert_success
	done
}

@test "verify-harden-runner-agent: a forged multiline revert line fails (safe only at startup)" {
	# v0.18.0 logs root-process arguments unescaped, so an argument with a
	# newline puts a line identical to the agent's own message into agent.log.
	# The startup check cannot tell them apart and fails. That is acceptable
	# only because it runs before any job step, when no caller-controlled
	# argument can be in the log; the end-of-job recheck therefore ignores
	# agent.log and decides from systemd state.
	_status Initialized
	install_fixture security/harden-runner-agent/healthy-agent.log \
		"$ROOT/home/agent/agent.log"
	cat >>"$ROOT/home/agent/agent.log" <<'LOG'
Fri, 13 Nov 2026 10:04:16 GMT:sudo process started: Exe: /usr/bin/printf, Arguments: [printf x
Fri, 13 Nov 2026 10:04:16 GMT:Reverted changes
 y]
LOG
	_verify
	assert_failure 1
	assert_output "::error title=harden-runner agent failed::agent.log reports a reverted initialization; egress is not enforced"
}

@test "verify-harden-runner-agent: an unreadable agent.log fails closed" {
	[[ "$(id -u)" != 0 ]] || skip "root reads any file"
	_status Initialized
	install_fixture security/harden-runner-agent/healthy-agent.log \
		"$ROOT/home/agent/agent.log"
	chmod 000 "$ROOT/home/agent/agent.log"
	_verify
	chmod 644 "$ROOT/home/agent/agent.log"
	assert_failure 1
	assert_line "::error title=harden-runner agent failed::cannot read /home/agent/agent.log; egress enforcement is unproven"
}

@test "verify-harden-runner-agent: an unreadable annotation.log fails closed" {
	[[ "$(id -u)" != 0 ]] || skip "root reads any file"
	_status Initialized
	printf 'Received SIGTERM signal\n' >"$ROOT/home/agent/annotation.log"
	chmod 000 "$ROOT/home/agent/annotation.log"
	_verify
	chmod 644 "$ROOT/home/agent/annotation.log"
	assert_failure 1
	assert_line "::error title=harden-runner agent failed::cannot read /home/agent/annotation.log; egress-policy is unproven"
}

@test "verify-harden-runner-agent: a revert written during the settle period fails" {
	_status Initialized
	install_fixture security/harden-runner-agent/healthy-agent.log \
		"$ROOT/home/agent/agent.log"
	cat >>"$STUBS/sleep" <<'STUB'
printf 'Fri, 13 Nov 2026 10:00:04 GMT:Reverted changes\n' \
	>>"$HARDEN_RUNNER_ROOT/home/agent/agent.log"
STUB
	_verify
	assert_failure 1
	assert_output --partial "agent.log reports a reverted initialization"
}

@test "verify-harden-runner-agent: the settle period is overridable" {
	_status Initialized
	_verify HARDEN_RUNNER_SETTLE_SECONDS=7
	assert_success
	[[ "$(cat "$CLOCK")" == 1007 ]]
}

@test "verify-harden-runner-agent: missing runner variables fail" {
	_status Initialized
	_verify RUNNER_ENVIRONMENT=
	assert_failure 1
	assert_output --partial "::error title=unknown runner::"
	_verify RUNNER_OS=
	assert_failure 1
	assert_output --partial "::error title=unknown runner::"
}

@test "verify-harden-runner-agent: ubuntu-slim without USER is unavailable" {
	_status Initialized
	_verify USER=
	assert_failure 1
	assert_output "::error title=harden-runner unavailable::harden-runner agent unavailable on this runner (no USER, e.g. ubuntu-slim): use a supported GitHub-hosted Linux runner"
}

@test "verify-harden-runner-agent: container jobs are unavailable" {
	local marker
	_status Initialized
	for marker in .dockerenv run/.containerenv; do
		mkdir -p "$ROOT/run"
		: >"$ROOT/$marker"
		_verify
		assert_failure 1
		assert_output --partial "unavailable on this runner (container job)"
		# Containers often run without USER: still reported as a container job.
		_verify USER=
		assert_failure 1
		assert_output --partial "unavailable on this runner (container job)"
		rm "$ROOT/$marker"
	done
}

@test "verify-harden-runner-agent: a runner without systemctl is unavailable" {
	rm "$STUBS/systemctl"
	_status Initialized
	_verify
	assert_failure 1
	assert_output --partial "unavailable on this runner (no systemd)"
}

@test "verify-harden-runner-agent: an agent that was never installed fails" {
	rm "$ROOT/etc/systemd/system/agent.service"
	_verify
	assert_failure 1
	assert_output "::error title=harden-runner unavailable::harden-runner agent unavailable on this runner (agent not installed (API 409 unavailable, skip-harden-runner property, or install error)): use a supported GitHub-hosted Linux runner"
	refute_output --partial "TLS"
}

@test "verify-harden-runner-agent: private repository downgraded to audit fails" {
	_status Initialized
	printf '%s\n' "StepSecurity Harden Runner is disabled. A subscription is required for private repositories. Please start a free trial at https://www.stepsecurity.io" \
		>"$ROOT/home/agent/annotation.log"
	_verify
	assert_failure 1
	assert_output --partial "::error title=StepSecurity subscription required::"
	assert_output --partial "Resolve the repository's StepSecurity subscription or enrollment"
	assert_output --partial "another runner will not help"
	refute_output --partial "use a supported GitHub-hosted Linux runner"
}

@test "verify-harden-runner-agent: unrelated annotations do not fail" {
	_status Initialized
	printf 'Received SIGTERM signal\n' >"$ROOT/home/agent/annotation.log"
	_verify
	assert_success
}

@test "verify-harden-runner-agent: an agent configured for audit fails" {
	_status Initialized
	printf '{"egress_policy":"audit"}' >"$ROOT/home/agent/agent.json"
	_verify
	assert_failure 1
	assert_output --partial "does not carry egress_policy block"
}

@test "verify-harden-runner-agent: a missing agent.json fails" {
	_status Initialized
	rm "$ROOT/home/agent/agent.json"
	_verify
	assert_failure 1
	assert_output "::error title=harden-runner agent failed::/home/agent/agent.json is missing; egress-policy block is unproven"
}

@test "verify-harden-runner-agent: the inline body has no sourcing, checkout or network" {
	run sed -n '/lgtm-ci-inline:begin/,/lgtm-ci-inline:end/p' "$SCRIPT"
	assert_success
	assert_output --partial "lgtm-ci-inline:begin verify-harden-runner-agent"
	refute_output --regexp '(^|[[:space:]])(source|\.|curl|wget|git|exec) '
	refute_output --partial 'set -euo pipefail'
}
