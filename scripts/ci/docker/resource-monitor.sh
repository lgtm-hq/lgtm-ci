#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Sample runner memory and disk during Docker builds.
#
# Subcommands:
#   start - Background a 30s loop of date + free -m + df -h /. Each sample
#           is prefixed with [resource-monitor] and teed to stdout (live job
#           log) and $RUNNER_TEMP/resource-monitor.log. The file is re-opened
#           each iteration so a last complete sample can still be dumped on
#           clean completion. A VM kill cancels remaining steps, so stdout
#           is the kill-case signal. Idempotent when the loop is already
#           running. Stdout write failures are ignored (best-effort).
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

ensure_parent_dir() {
	local path="$1"
	local label="$2"
	local parent
	parent="$(dirname -- "$path")"
	if [[ ! -d "$parent" ]]; then
		if ! mkdir -p -- "$parent"; then
			log_error "Cannot create ${label} parent directory: ${parent}"
			exit 1
		fi
	fi
	if [[ ! -w "$parent" ]]; then
		log_error "${label} parent directory is not writable: ${parent}"
		exit 1
	fi
}

file_byte_size() {
	local path="$1"
	if [[ -f "$path" ]]; then
		wc -c <"$path" | tr -d '[:space:]'
	else
		echo 0
	fi
}

stop_started_monitor() {
	local pid_file="$1"
	local pid
	if [[ ! -f "$pid_file" ]]; then
		return 0
	fi
	pid="$(cat "$pid_file" 2>/dev/null || true)"
	if [[ -n "${pid:-}" ]]; then
		pkill -P "$pid" 2>/dev/null || true
		kill "$pid" 2>/dev/null || true
	fi
	rm -f "$pid_file"
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

	ensure_parent_dir "$log_file" "log"
	ensure_parent_dir "$pid_file" "PID file"

	local log_bytes_before
	log_bytes_before="$(file_byte_size "$log_file")"

	# Write-first loop: the first sample is flushed before the first sleep.
	# File append is independent of stdout. Print to stdout is best-effort
	# so a still-open runner pipe keeps samples in the live job log; a
	# closed pipe must not starve the dump file. trap "" PIPE: writing to
	# a closed start-step pipe sends SIGPIPE, which would kill the sampler
	# even with `printf || true`.
	# $1/$2/$3 expand in the inner bash, not this shell.
	# env -u BASH_ENV: kcov instruments nested bash via BASH_ENV; its injected
	# script trips `set -u` inside the sampler, which is not a coverage target.
	# stderr stays discarded so kcov/bash noise does not pollute the job log.
	# The GHA runner waits on the start script PID, not stdout EOF, so
	# leaving the child's stdout open does not hang the start step (bats
	# `run` does wait for every writer — tests redirect to a file).
	# shellcheck disable=SC2016
	nohup env -u BASH_ENV bash -c '
		set -eu
		trap "" PIPE
		log_file="$1"
		interval="$2"
		max_samples="$3"
		samples=0
		while true; do
			sample="$(
				{
					date
					free -m || echo "free: unavailable"
					df -h / || echo "df: unavailable"
					echo
				} | sed "s/^/[resource-monitor] /"
			)"
			printf "%s\n" "$sample" >>"$log_file"
			printf "%s\n" "$sample" || true
			samples=$((samples + 1))
			if [[ "$max_samples" -gt 0 && "$samples" -ge "$max_samples" ]]; then
				break
			fi
			sleep "$interval"
		done
	' _ "$log_file" "$interval" "$max_samples" 2>/dev/null &
	local monitor_pid=$!
	if ! echo "$monitor_pid" >"$pid_file"; then
		kill "$monitor_pid" 2>/dev/null || true
		log_error "Failed to write PID file: ${pid_file}"
		exit 1
	fi
	disown || true

	# Ready when this invocation appended a sample (so the first
	# [resource-monitor] line is already on stdout), or the sampler is
	# still alive after the wait (first flush can lag under kcov). A stale
	# nonempty log alone is not success — that hid a dead child after a
	# failed append.
	local i current
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		current="$(file_byte_size "$log_file")"
		if [[ "$current" -gt "$log_bytes_before" ]]; then
			break
		fi
		sleep 0.1
	done
	current="$(file_byte_size "$log_file")"
	if ! is_running "$pid_file" && [[ "$current" -le "$log_bytes_before" ]]; then
		stop_started_monitor "$pid_file"
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
