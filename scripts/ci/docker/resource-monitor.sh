#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Sample runner memory and disk during Docker builds.
#
# Subcommands:
#   start - Background a 30s loop appending date + free -m + df -h / to
#           $RUNNER_TEMP/resource-monitor.log. Each iteration re-opens the
#           file so the last complete sample survives a VM kill. Idempotent
#           when the loop is already running.
#   dump  - Print the last ~100 lines of the log to the job log.
#
# Environment variables:
#   RUNNER_TEMP                 - Log/pid directory (required)
#   RESOURCE_MONITOR_INTERVAL   - Seconds between samples (default: 30)
#   RESOURCE_MONITOR_MAX_SAMPLES - Stop after N samples (0 = run until killed)
#   RESOURCE_MONITOR_LOG        - Override log path
#   RESOURCE_MONITOR_PID_FILE   - Override pid path
#
# Usage:
#   resource-monitor.sh start
#   resource-monitor.sh dump

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/log.sh
source "$SCRIPT_DIR/../lib/log.sh"

usage() {
	echo "Usage: $(basename "$0") {start|dump}" >&2
}

require_runner_temp() {
	: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
	if [[ ! -d "$RUNNER_TEMP" ]]; then
		log_error "RUNNER_TEMP does not exist: ${RUNNER_TEMP}"
		exit 1
	fi
}

log_path() {
	echo "${RESOURCE_MONITOR_LOG:-${RUNNER_TEMP}/resource-monitor.log}"
}

pid_path() {
	echo "${RESOURCE_MONITOR_PID_FILE:-${RUNNER_TEMP}/resource-monitor.pid}"
}

is_running() {
	local pid_file="$1"
	local pid
	if [[ ! -f "$pid_file" ]]; then
		return 1
	fi
	pid="$(cat "$pid_file")"
	if [[ -z "$pid" ]]; then
		return 1
	fi
	kill -0 "$pid" 2>/dev/null
}

start_monitor() {
	require_runner_temp

	local log_file pid_file interval
	log_file="$(log_path)"
	pid_file="$(pid_path)"
	interval="${RESOURCE_MONITOR_INTERVAL:-30}"

	if [[ ! "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -lt 1 ]]; then
		log_error "RESOURCE_MONITOR_INTERVAL must be a positive integer, got: '${interval}'"
		exit 1
	fi

	if is_running "$pid_file"; then
		log_info "Resource monitor already running (pid $(cat "$pid_file"))"
		return 0
	fi

	local max_samples="${RESOURCE_MONITOR_MAX_SAMPLES:-0}"
	if [[ ! "$max_samples" =~ ^[0-9]+$ ]]; then
		log_error "RESOURCE_MONITOR_MAX_SAMPLES must be a non-negative integer, got: '${max_samples}'"
		exit 1
	fi

	# Write-first loop: the first sample is flushed before the first sleep.
	# The compound redirect closes the file each iteration (survives a kill).
	# $1/$2/$3 expand in the inner bash, not this shell.
	# shellcheck disable=SC2016
	nohup bash -c '
		set -u
		log_file="$1"
		interval="$2"
		max_samples="$3"
		samples=0
		while true; do
			{
				date
				free -m || echo "free: unavailable"
				df -h / || echo "df: unavailable"
				echo
			} >>"$log_file"
			samples=$((samples + 1))
			if [[ "$max_samples" -gt 0 && "$samples" -ge "$max_samples" ]]; then
				break
			fi
			sleep "$interval"
		done
	' _ "$log_file" "$interval" "$max_samples" >/dev/null 2>&1 &
	echo $! >"$pid_file"
	disown || true

	# Finite samplers (tests) may exit after the first flush; otherwise the
	# child must still be alive or we reported a green start with no samples.
	local i
	for i in 1 2 3 4 5; do
		if is_running "$pid_file"; then
			break
		fi
		if [[ "$max_samples" -gt 0 && -s "$log_file" ]]; then
			break
		fi
		sleep 0.1
	done
	if ! is_running "$pid_file" && [[ ! -s "$log_file" ]]; then
		log_error "Resource monitor failed to stay running"
		exit 1
	fi

	log_info "Started resource monitor (pid $(cat "$pid_file"), log ${log_file}, interval ${interval}s)"
}

dump_monitor() {
	require_runner_temp

	local log_file
	log_file="$(log_path)"

	echo "=== Resource monitor (last 100 lines) ==="
	if [[ ! -f "$log_file" ]]; then
		echo "No resource monitor log found at ${log_file}"
		return 0
	fi
	tail -n 100 "$log_file"
}

if [[ $# -lt 1 ]]; then
	usage
	exit 2
fi

case "$1" in
start)
	start_monitor
	;;
dump)
	dump_monitor
	;;
-h | --help)
	usage
	exit 0
	;;
*)
	log_error "Unknown subcommand: $1"
	usage
	exit 2
	;;
esac
