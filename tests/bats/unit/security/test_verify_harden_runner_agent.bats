#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/bootstrap/verify-harden-runner-agent.sh (#1203, #1668, #1669)
#
# The source script of the generated "Verify harden-runner agent" steps that
# follow every harden-runner step. sync_inline_blocks.py --check keeps every
# inline copy equal to this body; test_harden_runner_verify_contract.py pins
# where the copies sit. systemctl, date and sleep are stubbed: the clock only
# moves when the script sleeps, so the 60s deadline and the 3s settle period
# after Initialized run instantly.

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/bootstrap/verify-harden-runner-agent.sh"
FIXTURES="${PROJECT_ROOT}/tests/fixtures/security/harden-runner-agent"
# step-security/agent v0.18.0 buildinfo.go, as in fixture run 43858549864.
BUILD_STANDARD='Fri, 13 Nov 2026 10:00:00 GMT:[buildInfo] tag=v0.18.0 commit=7bfa6297a2bacca7a0844515ebf5a7ef90764d98 branch=HEAD '
PREFIX='verify-harden-runner-agent: agent.log: '

setup() {
	scrub_ci_step_env
	# Keep kcov tracing through env -i, or the script is never measured.
	kcov_trace_env
	ROOT="${BATS_TEST_TMPDIR}/root"
	STUBS="${BATS_TEST_TMPDIR}/bin"
	CLOCK="${BATS_TEST_TMPDIR}/clock"
	mkdir -p "$ROOT/etc/systemd/system" "$ROOT/home/agent" "$STUBS"
	: >"$ROOT/etc/systemd/system/agent.service"
	printf '{"repo":"o/r","egress_policy":"block","private":false}' \
		>"$ROOT/home/agent/agent.json"
	# The standard agent's first log line and its DNS proxy (#1668).
	printf '%s\n\n' "$BUILD_STANDARD" >"$ROOT/home/agent/agent.log"
	printf '[Resolve]\nDNS=127.0.0.1\nDomains=~.\n' >"$ROOT/etc/systemd/resolved.conf"
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
	ln -s "$(command -v head)" "$STUBS/head"
}

# Run the script in a clean environment: only the stubs are on PATH, and the
# runner variables are the ones a GitHub-hosted Linux runner sets unless the
# caller overrides them (VAR=value arguments come after the defaults).
_verify() {
	run env -i "${KCOV_TRACE_ENV[@]}" PATH="$STUBS" CLOCK="$CLOCK" HARDEN_RUNNER_ROOT="$ROOT" \
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

@test "verify-harden-runner-agent: a public repository on a self-hosted runner fails (#1552)" {
	local os summary="$BATS_TEST_TMPDIR/summary"
	for os in Linux macOS Windows; do
		: >"$summary"
		_verify RUNNER_ENVIRONMENT=self-hosted RUNNER_OS="$os" REPOSITORY_PRIVATE=false \
			SERVICE_STATE=failed GITHUB_STEP_SUMMARY="$summary"
		assert_failure 1
		assert_output "::error title=public repository on self-hosted runner::a public repository must not run on a self-hosted runner (RUNNER_OS=$os): fork pull requests could run code there. Use a GitHub-hosted runner (check the runner variable or runner-image input), or make the repository internal or private"
		refute_output --partial "::warning"
		[[ ! -s "$summary" ]]
	done
}

@test "verify-harden-runner-agent: a public repository on GHES self-hosted fails too (#1552)" {
	# Owner decision: no GHES exemption. The server URL does not matter.
	local url
	for url in https://ghes.example.com https://github.com; do
		_verify RUNNER_ENVIRONMENT=self-hosted REPOSITORY_PRIVATE=false \
			GITHUB_SERVER_URL="$url" SERVICE_STATE=failed
		assert_failure 1
		assert_output --partial "::error title=public repository on self-hosted runner::"
		refute_output --partial "::warning"
	done
}

@test "verify-harden-runner-agent: private, internal or unknown visibility on self-hosted warns (#1552)" {
	# Internal repositories carry private: true. Events without a repository
	# payload render the expression empty, which is not public.
	local private line summary="$BATS_TEST_TMPDIR/summary"
	line="harden-runner egress enforcement not verified; this job may run without enforcement (RUNNER_ENVIRONMENT=self-hosted, RUNNER_OS=Linux)"
	for private in true "" False FALSE " false" null; do
		: >"$summary"
		_verify RUNNER_ENVIRONMENT=self-hosted REPOSITORY_PRIVATE="$private" \
			SERVICE_STATE=failed GITHUB_STEP_SUMMARY="$summary"
		assert_success
		assert_output "::warning title=hardening not verified::$line"
		[[ "$(cat "$summary")" == "$line" ]]
	done
	# REPOSITORY_PRIVATE unset entirely.
	_verify RUNNER_ENVIRONMENT=self-hosted SERVICE_STATE=failed
	assert_success
	assert_output "::warning title=hardening not verified::$line"
}

@test "verify-harden-runner-agent: a public repository on GitHub-hosted runners is unchanged (#1552)" {
	local runner
	_status Initialized
	_verify REPOSITORY_PRIVATE=false
	assert_success
	assert_output "harden-runner agent is active and initialized with egress-policy block"
	for runner in github-hosted/macOS github-hosted/Windows; do
		_verify RUNNER_ENVIRONMENT="${runner%/*}" RUNNER_OS="${runner#*/}" \
			REPOSITORY_PRIVATE=false SERVICE_STATE=failed
		assert_success
		assert_output --partial "::notice title=hardening not verified::"
	done
}

@test "verify-harden-runner-agent: audit is rejected before the public self-hosted check" {
	_verify RUNNER_ENVIRONMENT=self-hosted REPOSITORY_PRIVATE=false EGRESS_POLICY=audit
	assert_failure 1
	assert_output --partial "::error title=egress-policy rejected::"
	refute_output --partial "public repository"
}

@test "verify-harden-runner-agent: Initialized then the service stops in the settle period fails" {
	_status Initialized
	cat >>"$STUBS/sleep" <<'STUB'
printf '#!/usr/bin/env bash\nexit 3\n' >"${CLOCK%/*}/bin/systemctl"
STUB
	_verify
	assert_failure 1
	assert_line "::error title=harden-runner agent failed::agent.service stopped just after Initialized; egress is not enforced"
	assert_line "agent.log has no agent start-up error line"
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
		assert_line "::error title=harden-runner agent failed::agent.log reports a reverted initialization; egress is not enforced"
		assert_line "${PREFIX}Fri, 13 Nov 2026 10:00:04 GMT:${message}"
	done
}

@test "verify-harden-runner-agent: unanchored or extended revert text passes" {
	local message
	_status Initialized
	for message in 'Reverted changes' 'Error in Initialization' \
		'Fri, 13 Nov 2026 10:00:04 GMT:Reverted changes now' \
		'Fri, 13 Nov 2026 10:00:04 GMT:Error in Initializationx' \
		'x Fri, 13 Nov 2026 10:00:04 GMT:Reverted changes'; do
		printf '%s\n%s\n' "$BUILD_STANDARD" "$message" >"$ROOT/home/agent/agent.log"
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
	assert_line "::error title=harden-runner agent failed::agent.log reports a reverted initialization; egress is not enforced"
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

# --- #1668: only the standard agent is trusted -----------------------------

@test "verify-harden-runner-agent: the eBPF fallback agent is refused (#1668)" {
	# Real lines from fixture run 44565576621: harden-runner's TLS-status call
	# failed and it installed the eBPF agent v1.9.5 ("AgentAlpha").
	_status Initialized
	install_fixture security/harden-runner-agent/ebpf-agent.log \
		"$ROOT/home/agent/agent.log"
	_verify
	assert_failure 1
	assert_output "::error title=harden-runner agent refused::harden-runner installed its eBPF fallback agent; only the standard agent is trusted"
}

@test "verify-harden-runner-agent: the eBPF agent is refused even beside a standard line" {
	_status Initialized
	cat "$FIXTURES/ebpf-agent.log" >>"$ROOT/home/agent/agent.log"
	_verify
	assert_failure 1
	assert_output --partial "::error title=harden-runner agent refused::"
}

@test "verify-harden-runner-agent: an eBPF build line that is not the agent's own does not count as eBPF" {
	# Untimestamped or prefixed text is an argument, not the agent's line;
	# the standard build line still identifies the agent.
	_status Initialized
	printf '%s\n' '[buildInfo] name=AgentAlpha branch=HEAD tag=v1.9.5 commit=x' \
		'x Thu, 19 Nov 2026 16:25:21 GMT:[buildInfo] name=AgentAlpha tag=v1.9.5' \
		>>"$ROOT/home/agent/agent.log"
	_verify
	assert_success
}

@test "verify-harden-runner-agent: no standard build line fails closed (#1668)" {
	local log
	_status Initialized
	for log in '' \
		'Fri, 13 Nov 2026 10:00:00 GMT:read config' \
		'Fri, 13 Nov 2026 10:00:00 GMT:[buildInfo] name=AgentBravo branch=HEAD tag=v1.9.5 commit=2b9a2fc885aa4619a101e2cf0b4468252ef28527' \
		'Fri, 13 Nov 2026 10:00:00 GMT:[buildInfo] tag=v0.18.0 commit=short branch=HEAD' \
		'Fri, 13 Nov 2026 10:00:00 GMT:[buildInfo] tag= commit=7bfa6297a2bacca7a0844515ebf5a7ef90764d98 branch=HEAD'; do
		printf '%s\n' "$log" >"$ROOT/home/agent/agent.log"
		_verify
		assert_failure 1
		assert_output "::error title=harden-runner agent failed::agent.log does not identify the standard agent; egress enforcement is unproven"
	done
}

@test "verify-harden-runner-agent: a second, different build line fails closed" {
	_status Initialized
	printf '%s\n' 'Fri, 13 Nov 2026 10:00:09 GMT:[buildInfo] name=Other tag=v2 commit=x branch=y' \
		>>"$ROOT/home/agent/agent.log"
	_verify
	assert_failure 1
	assert_output --partial "does not identify the standard agent"
}

@test "verify-harden-runner-agent: a missing agent.log after Initialized fails closed" {
	_status Initialized
	rm "$ROOT/home/agent/agent.log"
	_verify
	assert_failure 1
	assert_output "::error title=harden-runner agent failed::/home/agent/agent.log is missing; the agent build is unproven"
}

@test "verify-harden-runner-agent: resolved.conf without the agent's DNS proxy fails (#1668)" {
	local conf
	_status Initialized
	for conf in '[Resolve]\nDNS=8.8.8.8\n' '[Resolve]\n#DNS=127.0.0.1\n' '[Resolve]\nDNS=127.0.0.1 8.8.8.8\n'; do
		# shellcheck disable=SC2059 # the cases carry \n escapes.
		printf "$conf" >"$ROOT/etc/systemd/resolved.conf"
		_verify
		assert_failure 1
		assert_output "::error title=harden-runner agent failed::resolved.conf does not use the agent's DNS proxy; egress is not enforced"
	done
	rm "$ROOT/etc/systemd/resolved.conf"
	_verify
	assert_failure 1
	assert_output --partial "resolved.conf does not use the agent's DNS proxy"
}

# --- #1669: an inactive agent's own start-up errors are printed ------------

@test "verify-harden-runner-agent: an inactive agent prints its start-up errors, then fails (#1669)" {
	# Trimmed agent.log of fixture run 43858549864: the agent failed 11 s into
	# the verify step's polling, after harden-runner had stopped waiting.
	install_fixture security/harden-runner-agent/late-failure-agent.log \
		"$ROOT/home/agent/agent.log"
	_verify SERVICE_STATE=failed
	assert_failure 1
	# Only "Error ..." and "Reverted changes" lines are printed.
	assert_equal "${#lines[@]}" 3
	assert_equal "${lines[0]}" "${PREFIX}Mon, 16 Nov 2026 12:00:40 GMT:Error resolving allowed domain error in response from dns.google unable to resolve domain productionresultssa187.blob.core.windows.net., status 2"
	assert_equal "${lines[1]}" "${PREFIX}Mon, 16 Nov 2026 12:00:40 GMT:Reverted changes"
	# The annotation is unchanged and comes last.
	assert_equal "${lines[2]}" "::error title=harden-runner agent failed::agent.service is not active; egress is not enforced"
}

@test "verify-harden-runner-agent: an inactive agent without error lines says so" {
	_verify SERVICE_STATE=failed
	assert_failure 1
	assert_equal "${#lines[@]}" 2
	assert_equal "${lines[0]}" "agent.log has no agent start-up error line"
	assert_equal "${lines[1]}" "::error title=harden-runner agent failed::agent.service is not active; egress is not enforced"
}

@test "verify-harden-runner-agent: an inactive agent without agent.log says so" {
	rm "$ROOT/home/agent/agent.log"
	_verify SERVICE_STATE=failed
	assert_failure 1
	assert_equal "${lines[0]}" "agent.log is missing; no agent start-up error to show"
	assert_equal "${lines[1]}" "::error title=harden-runner agent failed::agent.service is not active; egress is not enforced"
}

@test "verify-harden-runner-agent: an unreadable or non-file agent.log is reported, not read" {
	rm "$ROOT/home/agent/agent.log"
	mkdir "$ROOT/home/agent/agent.log"
	_verify SERVICE_STATE=failed
	assert_failure 1
	assert_line "agent.log is not a readable file; no agent start-up error to show"
	assert_line "::error title=harden-runner agent failed::agent.service is not active; egress is not enforced"
	rmdir "$ROOT/home/agent/agent.log"
	[[ "$(id -u)" != 0 ]] || skip "root reads any file"
	printf 'Fri, 13 Nov 2026 10:00:04 GMT:Error x\n' >"$ROOT/home/agent/agent.log"
	chmod 000 "$ROOT/home/agent/agent.log"
	_verify SERVICE_STATE=failed
	chmod 644 "$ROOT/home/agent/agent.log"
	assert_failure 1
	assert_line "agent.log is not a readable file; no agent start-up error to show"
	refute_output --partial "$PREFIX"
}

@test "verify-harden-runner-agent: only the agent's own error lines are printed" {
	cat >>"$ROOT/home/agent/agent.log" <<'LOG'
Fri, 13 Nov 2026 10:00:02 GMT:domain resolved: github.com., ip address: 140.82.113.3, TTL: 60
Error resolving allowed domain without a timestamp
x Fri, 13 Nov 2026 10:00:03 GMT:Error prefixed
Fri, 13 Nov 2026 10:00:03 GMT:Reverted changes now
Fri, 13 Nov 2026 10:00:04 GMT:Error in Initialization boom
LOG
	_verify SERVICE_STATE=failed
	assert_failure 1
	assert_equal "${#lines[@]}" 2
	assert_equal "${lines[0]}" "${PREFIX}Fri, 13 Nov 2026 10:00:04 GMT:Error in Initialization boom"
}

@test "verify-harden-runner-agent: printed lines are capped at 20 and 512 bytes" {
	local i long
	long="$(printf 'a%.0s' {1..2000})"
	printf 'Fri, 13 Nov 2026 10:00:01 GMT:Error %s\n' "$long" >>"$ROOT/home/agent/agent.log"
	for i in {1..30}; do
		printf 'Fri, 13 Nov 2026 10:00:02 GMT:Error number %s\n' "$i" >>"$ROOT/home/agent/agent.log"
	done
	_verify SERVICE_STATE=failed
	assert_failure 1
	# 20 agent lines and the annotation.
	assert_equal "${#lines[@]}" 21
	assert_equal "${#lines[0]}" $((${#PREFIX} + 512))
	assert_equal "${lines[19]}" "${PREFIX}Fri, 13 Nov 2026 10:00:02 GMT:Error number 19"
	refute_output --partial "Error number 20"
}

@test "verify-harden-runner-agent: only the first 1 MiB of agent.log is read" {
	local filler
	filler="$(printf 'x%.0s' {1..1023})"
	{
		printf 'Fri, 13 Nov 2026 10:00:01 GMT:Error early\n'
		for _ in {1..1100}; do printf '%s\n' "$filler"; done
		printf 'Fri, 13 Nov 2026 10:00:02 GMT:Error late\n'
	} >>"$ROOT/home/agent/agent.log"
	(($(wc -c <"$ROOT/home/agent/agent.log") > 1048576))
	_verify SERVICE_STATE=failed
	assert_failure 1
	assert_line "${PREFIX}Fri, 13 Nov 2026 10:00:01 GMT:Error early"
	refute_output --partial "Error late"
}

@test "verify-harden-runner-agent: control characters and workflow commands are neutralised" {
	printf 'Fri, 13 Nov 2026 10:00:01 GMT:Error \033[31mred\033[0m ::error::x ##[error]y %%0A\r\n' \
		>>"$ROOT/home/agent/agent.log"
	printf 'Fri, 13 Nov 2026 10:00:02 GMT:Error tab\there bell\a nul-free \xff\xfe end\n' \
		>>"$ROOT/home/agent/agent.log"
	_verify SERVICE_STATE=failed
	assert_failure 1
	assert_equal "${#lines[@]}" 3
	assert_equal "${lines[0]}" "${PREFIX}Fri, 13 Nov 2026 10:00:01 GMT:Error ??31mred??0m ::error::x ???error?y ?0A?"
	assert_equal "${lines[1]}" "${PREFIX}Fri, 13 Nov 2026 10:00:02 GMT:Error tab?here bell? nul-free ?? end"
	refute_output --partial $'\033'
	refute_output --partial '##['
	# Only the step's own annotation is a workflow command.
	run grep -c '^::' <<<"$output"
	assert_output 1
}

# --- #1668 opt-in: LGTM_CI_ALLOW_HARDEN_RUNNER_EBPF_AGENT ----------------------

ALLOW='LGTM_CI_ALLOW_HARDEN_RUNNER_EBPF_AGENT=true'
REFUSED='::error title=harden-runner agent refused::harden-runner installed its eBPF fallback agent; only the standard agent is trusted'
ACCEPTED="::warning title=harden-runner eBPF agent accepted::harden-runner's eBPF fallback agent was accepted because LGTM_CI_ALLOW_HARDEN_RUNNER_EBPF_AGENT is true; it logged NetMode:ebpf and block-policy applied"

# The eBPF agent as fixture run 44565576621 left it: its own lines, and the
# resolved.conf it never changes.
_ebpf_agent() {
	install_fixture security/harden-runner-agent/ebpf-agent.log \
		"$ROOT/home/agent/agent.log"
	printf '[Resolve]\n' >"$ROOT/etc/systemd/resolved.conf"
	_status Initialized
}

@test "verify-harden-runner-agent: the switch off refuses the eBPF agent, whatever else is set" {
	local value
	_ebpf_agent
	for value in '' false TRUE True 1 yes on ' true' 'true ' '"true"'; do
		_verify LGTM_CI_ALLOW_HARDEN_RUNNER_EBPF_AGENT="$value" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
		assert_failure 1
		assert_output "$REFUSED"
		[[ ! -s "$BATS_TEST_TMPDIR/out" ]]
	done
}

@test "verify-harden-runner-agent: the switch on accepts the eBPF agent with full block-mode evidence" {
	_ebpf_agent
	_verify "$ALLOW" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
	assert_success
	assert_equal "${#lines[@]}" 2
	assert_equal "${lines[0]}" "$ACCEPTED"
	assert_equal "${lines[1]}" "harden-runner agent is active and initialized with egress-policy block"
	[[ "$(cat "$BATS_TEST_TMPDIR/out")" == agent=ebpf ]]
	# No wait: block-policy applied was already logged.
	[[ "$(cat "$CLOCK")" == 1003 ]]
}

@test "verify-harden-runner-agent: the switch on waits for block-policy applied within 30s" {
	_ebpf_agent
	grep -vF 'block-policy applied' "$FIXTURES/ebpf-agent.log" >"$ROOT/home/agent/agent.log"
	cat >>"$STUBS/sleep" <<'STUB'
if ((now >= 1010)) && ! grep -q 'block-policy' "$HARDEN_RUNNER_ROOT/home/agent/agent.log"; then
	printf 'Thu, 19 Nov 2026 16:25:30 GMT:[tracerManager] block-policy applied\n' \
		>>"$HARDEN_RUNNER_ROOT/home/agent/agent.log"
fi
STUB
	_verify "$ALLOW"
	assert_success
	assert_line "$ACCEPTED"
	[[ "$(cat "$CLOCK")" == 1010 ]]
}

@test "verify-harden-runner-agent: the switch on refuses an eBPF agent without block-policy applied" {
	_ebpf_agent
	grep -vF 'block-policy applied' "$FIXTURES/ebpf-agent.log" >"$ROOT/home/agent/agent.log"
	_verify "$ALLOW"
	assert_failure 1
	assert_output "::error title=harden-runner agent failed::the eBPF agent did not log block-policy applied within 30s; egress enforcement is unproven"
	[[ "$(cat "$CLOCK")" == 1033 ]]
}

@test "verify-harden-runner-agent: the switch on refuses an eBPF agent with another policy" {
	local policy
	for policy in 'audit-policy applied' 'allow-policy applied'; do
		_ebpf_agent
		printf 'Thu, 19 Nov 2026 16:25:23 GMT:[tracerManager] %s\n' "$policy" >>"$ROOT/home/agent/agent.log"
		_verify "$ALLOW"
		assert_failure 1
		assert_output "::error title=harden-runner agent failed::the eBPF agent applied a policy other than block; egress is not enforced"
	done
}

@test "verify-harden-runner-agent: the switch on refuses an eBPF agent without NetMode:ebpf" {
	local line
	_ebpf_agent
	grep -vF 'NetMode:' "$FIXTURES/ebpf-agent.log" >"$ROOT/home/agent/agent.log"
	_verify "$ALLOW"
	assert_failure 1
	assert_output "::error title=harden-runner agent failed::the eBPF agent does not report NetMode:ebpf; egress enforcement is unproven"
	for line in 'Initial Feature flags: {ResolveTXT:false NetMode:dns}' 'Feature flags: {NetMode:ebpfx}'; do
		_ebpf_agent
		printf 'Thu, 19 Nov 2026 16:25:22 GMT:%s\n' "$line" >>"$ROOT/home/agent/agent.log"
		_verify "$ALLOW"
		assert_failure 1
		assert_output --partial "does not report NetMode:ebpf"
	done
	# NetMode only as a step-like argument, not the agent's own line.
	grep -vF 'NetMode:' "$FIXTURES/ebpf-agent.log" >"$ROOT/home/agent/agent.log"
	printf 'Initial Feature flags: {NetMode:ebpf}\n' >>"$ROOT/home/agent/agent.log"
	_verify "$ALLOW"
	assert_failure 1
	assert_output --partial "does not report NetMode:ebpf"
}

@test "verify-harden-runner-agent: the switch on refuses a malformed or second build line" {
	local line
	for line in 'Thu, 19 Nov 2026 16:25:21 GMT:[buildInfo] name=AgentAlpha branch=HEAD tag=v1.9.5 commit=short' \
		"$BUILD_STANDARD"; do
		_ebpf_agent
		printf '%s\n' "$line" >>"$ROOT/home/agent/agent.log"
		_verify "$ALLOW"
		assert_failure 1
		assert_output "::error title=harden-runner agent failed::agent.log does not identify the ebpf agent; egress enforcement is unproven"
	done
}

@test "verify-harden-runner-agent: the switch on refuses an eBPF agent that stopped or reverted" {
	_ebpf_agent
	cat >>"$STUBS/sleep" <<'STUB'
if ((now > 1003)); then printf '#!/usr/bin/env bash\nexit 3\n' >"${CLOCK%/*}/bin/systemctl"; fi
STUB
	grep -vF 'block-policy applied' "$FIXTURES/ebpf-agent.log" >"$ROOT/home/agent/agent.log"
	cat >>"$STUBS/sleep" <<'STUB'
if ((now >= 1005)); then
	printf 'Thu, 19 Nov 2026 16:25:30 GMT:[tracerManager] block-policy applied\n' \
		>>"$HARDEN_RUNNER_ROOT/home/agent/agent.log"
fi
STUB
	_verify "$ALLOW"
	assert_failure 1
	assert_line "::error title=harden-runner agent failed::agent.service stopped while the eBPF agent was checked; egress is not enforced"
	_ebpf_agent
	printf '1000' >"$CLOCK"
	printf 'Thu, 19 Nov 2026 16:25:24 GMT:Reverted changes\n' >>"$ROOT/home/agent/agent.log"
	cat >"$STUBS/systemctl" <<'STUB'
#!/usr/bin/env bash
[[ "$SERVICE_STATE" == active ]]
STUB
	chmod +x "$STUBS/systemctl"
	_verify "$ALLOW"
	assert_failure 1
	assert_line "::error title=harden-runner agent failed::agent.log reports a reverted initialization; egress is not enforced"
}

@test "verify-harden-runner-agent: the switch on keeps the policy and subscription checks for the eBPF agent" {
	_ebpf_agent
	printf '{"egress_policy":"audit"}' >"$ROOT/home/agent/agent.json"
	_verify "$ALLOW"
	assert_failure 1
	assert_output --partial "does not carry egress_policy block"
}

@test "verify-harden-runner-agent: the switch on leaves the standard agent unchanged" {
	_status Initialized
	_verify "$ALLOW" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
	assert_success
	assert_output "harden-runner agent is active and initialized with egress-policy block"
	[[ "$(cat "$BATS_TEST_TMPDIR/out")" == agent=standard ]]
	# resolved.conf is still required for it.
	printf '[Resolve]\nDNS=8.8.8.8\n' >"$ROOT/etc/systemd/resolved.conf"
	_verify "$ALLOW"
	assert_failure 1
	assert_output "::error title=harden-runner agent failed::resolved.conf does not use the agent's DNS proxy; egress is not enforced"
}

@test "verify-harden-runner-agent: the standard agent writes agent=standard to the step output" {
	_status Initialized
	_verify GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
	assert_success
	[[ "$(cat "$BATS_TEST_TMPDIR/out")" == agent=standard ]]
}

# --- #1672 review: one agent start, policy re-read, guarded diagnostics ------

@test "verify-harden-runner-agent: two valid standard build records fail closed" {
	_status Initialized
	printf '%s\n' "${BUILD_STANDARD/10:00:00/10:05:00}" >>"$ROOT/home/agent/agent.log"
	_verify
	assert_failure 1
	assert_output "::error title=harden-runner agent failed::agent.log does not start with exactly one build record of the standard agent; egress enforcement is unproven"
}

@test "verify-harden-runner-agent: two valid eBPF build records fail closed with the switch on" {
	_ebpf_agent
	printf '%s\n' 'Thu, 19 Nov 2026 16:30:00 GMT:[buildInfo] name=AgentAlpha branch=HEAD tag=v1.9.5 commit=2b9a2fc885aa4619a101e2cf0b4468252ef28527' \
		>>"$ROOT/home/agent/agent.log"
	_verify "$ALLOW"
	assert_failure 1
	assert_output "::error title=harden-runner agent failed::agent.log does not start with exactly one build record of the ebpf agent; egress enforcement is unproven"
}

@test "verify-harden-runner-agent: a build record that is not the log's first record fails closed" {
	printf '%s\n%s\n' 'Fri, 13 Nov 2026 09:59:59 GMT:read config' "$BUILD_STANDARD" \
		>"$ROOT/home/agent/agent.log"
	_status Initialized
	_verify
	assert_failure 1
	assert_output --partial "does not start with exactly one build record of the standard agent"
	_ebpf_agent
	printf '%s\n' 'Thu, 19 Nov 2026 16:25:20 GMT:[tracerManager] block-policy applied' >"$BATS_TEST_TMPDIR/head"
	cat "$BATS_TEST_TMPDIR/head" "$FIXTURES/ebpf-agent.log" >"$ROOT/home/agent/agent.log"
	_verify "$ALLOW"
	assert_failure 1
	assert_output --partial "does not start with exactly one build record of the ebpf agent"
}

@test "verify-harden-runner-agent: a policy logged after block-policy applied is caught on the re-read" {
	local line
	for line in 'audit-policy applied' 'deny-list applied, denied endpoints:[x]' 'failed to apply block-policy : boom'; do
		_ebpf_agent
		printf '0' >"$BATS_TEST_TMPDIR/calls"
		# The third is-active call is the last one, after the policy wait: the
		# agent logs another policy just then.
		cat >"$STUBS/systemctl" <<STUB
#!/usr/bin/env bash
calls=\$((\$(cat "$BATS_TEST_TMPDIR/calls") + 1))
printf '%s' "\$calls" >"$BATS_TEST_TMPDIR/calls"
if ((calls == 3)); then
	printf 'Thu, 19 Nov 2026 16:25:40 GMT:[tracerManager] %s\n' '$line' >>"\$HARDEN_RUNNER_ROOT/home/agent/agent.log"
fi
exit 0
STUB
		chmod +x "$STUBS/systemctl"
		_verify "$ALLOW"
		assert_failure 1
		assert_output "::error title=harden-runner agent failed::the eBPF agent applied a policy other than block; egress is not enforced"
		[[ "$(cat "$BATS_TEST_TMPDIR/calls")" == 3 ]]
	done
}

@test "verify-harden-runner-agent: deny-list or a failed apply is never block mode" {
	local line
	for line in 'deny-list applied, denied endpoints:[x]' 'failed to apply block-policy : boom'; do
		_ebpf_agent
		printf 'Thu, 19 Nov 2026 16:25:23 GMT:[tracerManager] %s\n' "$line" >>"$ROOT/home/agent/agent.log"
		_verify "$ALLOW"
		assert_failure 1
		assert_output --partial "applied a policy other than block"
	done
}

@test "verify-harden-runner-agent: a failing diagnostic cannot suppress the start-up annotation" {
	# agent_errors is diagnostic only; even when it fails, set -e must not end
	# the step before the ::error line #1667's rule reads.
	local copy="$BATS_TEST_TMPDIR/verify-copy.sh"
	sed 's/^agent_errors() ($/agent_errors() { return 3; }\n_unused() (/' "$SCRIPT" >"$copy"
	grep -q '^agent_errors() { return 3; }$' "$copy"
	run env -i "${KCOV_TRACE_ENV[@]}" PATH="$STUBS" CLOCK="$CLOCK" HARDEN_RUNNER_ROOT="$ROOT" \
		SERVICE_STATE=failed EGRESS_POLICY=block USER=runner \
		RUNNER_ENVIRONMENT=github-hosted RUNNER_OS=Linux "$BASH" "$copy"
	assert_failure 1
	assert_output "::error title=harden-runner agent failed::agent.service is not active; egress is not enforced"
	# Every call site is guarded.
	run grep -cE '^ *agent_errors$' "$SCRIPT"
	assert_output 0
	run grep -cE '^ *agent_errors \|\| true$' "$SCRIPT"
	assert_output 4
}
