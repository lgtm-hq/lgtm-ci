#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Serialize Docker setup after the hosted Linux hardener's initialization

set -euo pipefail

: "${RUNNER_OS:?RUNNER_OS is required}"
: "${RUNNER_ENVIRONMENT:?RUNNER_ENVIRONMENT is required}"

# The pinned hardener installs /home/agent only on GitHub-hosted Linux.
# Self-hosted agents are host-managed; other platforms use different agents.
if [[ "$RUNNER_OS" != Linux || "$RUNNER_ENVIRONMENT" != github-hosted ]]; then
	echo "Hosted Linux hardener completion barrier does not apply on this runner"
	exit 0
fi

# Test fixtures may supply an isolated status file. Workflows use the default.
export HARDEN_RUNNER_STATUS_FILE="${HARDEN_RUNNER_STATUS_FILE:-/home/agent/agent.status}"

wait_for_harden_runner() {
	local agent_status
	# Bash defers a TERM trap while waiting for a foreground command. Keep the
	# monitored shell alive so timeout can escalate against an ignoring child.
	trap 'exit 124' TERM
	while true; do
		if ! systemctl is-active --quiet agent.service; then
			echo "::error::harden-runner agent.service is not active"
			return 1
		fi
		if [[ -e "$HARDEN_RUNNER_STATUS_FILE" ]]; then
			if ! agent_status="$(cat -- "$HARDEN_RUNNER_STATUS_FILE")"; then
				echo "::error::Cannot read harden-runner status"
				return 1
			fi
			case "$agent_status" in
			# agent v0.18.0 writes this only AFTER Docker restart and firewall setup.
			Initialized) return 0 ;;
			"") ;; # File creation can precede the status write.
			*)
				printf '::error::Unexpected harden-runner status: %q\n' "$agent_status"
				return 1
				;;
			esac
		fi
		sleep 1
	done
}
export -f wait_for_harden_runner

# The action's own short status wait can time out while initialization continues.
# Bound service/status reads to 60s plus a 2s TERM-to-KILL grace.
result=0
timeout --kill-after=2s 60s bash -c wait_for_harden_runner || result=$?
if [[ "$result" == 124 || "$result" == 137 ]]; then
	echo "::error::Timed out waiting for harden-runner to finish Docker initialization (60s deadline + 2s kill grace)"
	exit 1
elif [[ "$result" != 0 ]]; then
	exit "$result"
fi

# A responsive socket before Initialized is insufficient: restart may be pending.
result=0
timeout --kill-after=2s 10s docker info >/dev/null || result=$?
if [[ "$result" == 124 || "$result" == 137 ]]; then
	echo "::error::Docker info timed out after harden-runner initialized (10s deadline + 2s kill grace)"
	exit 1
elif [[ "$result" != 0 ]]; then
	echo "::error::Docker is unavailable after harden-runner initialized"
	exit 1
fi
echo "harden-runner initialized; Docker setup may proceed"
