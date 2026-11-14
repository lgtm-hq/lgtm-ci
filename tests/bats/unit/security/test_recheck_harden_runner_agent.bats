#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/bootstrap/recheck-harden-runner-agent.sh (#1203)
#
# The source script of the generated "Recheck harden-runner agent" step that
# ends every job with the startup verify step. sync_inline_blocks.py --check
# keeps every inline copy equal to this body;
# test_harden_runner_verify_contract.py pins where the copies sit. systemctl
# is stubbed. The verdict is systemd state plus the agent's resolved.conf;
# agent.log is never read.

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/bootstrap/recheck-harden-runner-agent.sh"

setup() {
	scrub_ci_step_env
	ROOT="${BATS_TEST_TMPDIR}/root"
	STUBS="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$ROOT/home/agent" "$ROOT/etc/systemd" "$STUBS"
	# What a healthy agent writes before Initialized (v0.18.0 dnsconfig.go).
	printf '[Resolve]\nDNS=127.0.0.1\nDomains=~.\n' \
		>"$ROOT/etc/systemd/resolved.conf"
	# is-active answers from SERVICE_STATE; show prints SHOW_OUTPUT (or exits
	# SHOW_STATUS when set); any other call is a bug.
	cat >"$STUBS/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
'is-active --quiet agent.service') [[ "$SERVICE_STATE" == active ]] ;;
'show agent.service -p ActiveState,SubState,Result,ExecMainStatus')
	[[ -z "${SHOW_STATUS:-}" ]] || exit "$SHOW_STATUS"
	printf '%s' "${SHOW_OUTPUT:-}"
	;;
*) exit 90 ;;
esac
STUB
	chmod +x "$STUBS/systemctl"
	# Symlinks to real tools last: chmod would follow them to root-owned
	# binaries on Linux runners.
	ln -s "$BASH" "$STUBS/bash"
	ln -s "$(command -v grep)" "$STUBS/grep"
}

# Run the script with only the stubs on PATH, as on a GitHub-hosted Linux
# runner unless the caller overrides a variable. HARDEN_RUNNER_ROOT points at
# a fake resolved.conf and an agent.log the script must ignore.
_recheck() {
	run env -i PATH="$STUBS" HARDEN_RUNNER_ROOT="$ROOT" SERVICE_STATE=active \
		RUNNER_ENVIRONMENT=github-hosted RUNNER_OS=Linux "$@" \
		"$BASH" "$SCRIPT"
}

STOPPED="::error title=harden-runner agent stopped::harden-runner agent stopped enforcing mid-job; steps after it ran unhardened"

@test "recheck-harden-runner-agent: an active agent passes" {
	_recheck
	assert_success
	assert_output "harden-runner agent is still active and enforcing DNS at job end"
}

@test "recheck-harden-runner-agent: a failed agent.service fails with its Result" {
	_recheck SERVICE_STATE=failed SHOW_OUTPUT=$'ActiveState=failed\nSubState=failed\nResult=exit-code\nExecMainStatus=1\n'
	assert_failure 1
	assert_output "$STOPPED (agent.service is not active: ActiveState=failed SubState=failed Result=exit-code ExecMainStatus=1)"
}

@test "recheck-harden-runner-agent: an inactive agent.service fails with its Result" {
	_recheck SERVICE_STATE=inactive SHOW_OUTPUT=$'ActiveState=inactive\nSubState=dead\nResult=success\nExecMainStatus=0\n'
	assert_failure 1
	assert_output "$STOPPED (agent.service is not active: ActiveState=inactive SubState=dead Result=success ExecMainStatus=0)"
}

@test "recheck-harden-runner-agent: an inactive agent fails even when systemctl show fails" {
	_recheck SERVICE_STATE=failed SHOW_STATUS=1
	assert_failure 1
	assert_output "$STOPPED (agent.service is not active)"
}

@test "recheck-harden-runner-agent: agent.log is ignored; systemd state decides" {
	# v0.18.0 logs root-process arguments unescaped, so a step can forge a
	# line identical to the agent's own "Reverted changes" message. Healthy
	# service, forged log: pass.
	install_fixture security/harden-runner-agent/healthy-agent.log \
		"$ROOT/home/agent/agent.log"
	cat >>"$ROOT/home/agent/agent.log" <<'LOG'
Fri, 13 Nov 2026 10:04:16 GMT:sudo process started: Exe: /usr/bin/printf, Arguments: [printf x
Fri, 13 Nov 2026 10:04:16 GMT:Reverted changes
Fri, 13 Nov 2026 10:04:16 GMT:Error in Initialization
 y]
LOG
	_recheck
	assert_success
	assert_output "harden-runner agent is still active and enforcing DNS at job end"
	# An unreadable log does not matter either.
	if [[ "$(id -u)" != 0 ]]; then
		chmod 000 "$ROOT/home/agent/agent.log"
		_recheck
		chmod 644 "$ROOT/home/agent/agent.log"
		assert_success
	fi
}

@test "recheck-harden-runner-agent: self-hosted and non-Linux runners pass silently" {
	local runner
	printf 'Fri, 13 Nov 2026 10:10:00 GMT:Reverted changes\n' \
		>"$ROOT/home/agent/agent.log"
	for runner in self-hosted/Linux self-hosted/macOS github-hosted/macOS \
		github-hosted/Windows; do
		_recheck RUNNER_ENVIRONMENT="${runner%/*}" RUNNER_OS="${runner#*/}" \
			SERVICE_STATE=failed
		assert_success
		assert_output ""
	done
}

@test "recheck-harden-runner-agent: missing runner variables fail" {
	_recheck RUNNER_ENVIRONMENT=
	assert_failure 1
	assert_output --partial "::error title=unknown runner::"
	_recheck RUNNER_OS=
	assert_failure 1
	assert_output --partial "::error title=unknown runner::"
}

@test "recheck-harden-runner-agent: the inline body has no sourcing, checkout, network or wait" {
	run sed -n '/lgtm-ci-inline:begin/,/lgtm-ci-inline:end/p' "$SCRIPT"
	assert_success
	assert_output --partial "lgtm-ci-inline:begin recheck-harden-runner-agent"
	refute_output --regexp '(^|[[:space:]])(source|\.|curl|wget|git|exec|sleep) '
	refute_output --partial 'agent.status'
	refute_output --partial 'agent.json'
	refute_output --partial 'agent.log'
	refute_output --partial 'set -euo pipefail'
}

@test "recheck-harden-runner-agent: an active agent mid-revert (DNS restored) fails" {
	# RevertChanges clears the firewall, restores resolved.conf, then restarts
	# Docker before exiting, so the unit can still be active here.
	printf '[Resolve]\n#DNS=\n' >"$ROOT/etc/systemd/resolved.conf"
	_recheck
	assert_failure 1
	assert_output "$STOPPED (resolved.conf no longer uses the agent's DNS proxy: revert in progress or DNS changed by a step)"
}

@test "recheck-harden-runner-agent: a missing resolved.conf fails" {
	rm "$ROOT/etc/systemd/resolved.conf"
	_recheck
	assert_failure 1
	assert_output --partial "resolved.conf no longer uses the agent's DNS proxy"
}

@test "recheck-harden-runner-agent: DNS=127.0.0.1 only as part of a longer line fails" {
	printf '[Resolve]\nDNS=127.0.0.10\n#DNS=127.0.0.1 old\n' \
		>"$ROOT/etc/systemd/resolved.conf"
	_recheck
	assert_failure 1
}
