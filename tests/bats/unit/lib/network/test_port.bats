#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/lib/network/port.sh

load "../../../../helpers/common"
load "../../../../helpers/mocks"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	export BATS_TEST_TMPDIR
}

teardown() {
	restore_path
	teardown_temp_dir
}

# =============================================================================
# port_available tests
# =============================================================================

@test "port_available: returns true for valid high port" {
	# Use a random high port that's likely free
	run bash -c 'source "$LIB_DIR/network/port.sh" && port_available 49999 && echo "available"'
	assert_success
	assert_output --partial "available"
}

@test "port_available: returns false for invalid port (negative)" {
	run bash -c 'source "$LIB_DIR/network/port.sh" && port_available -1 2>&1'
	assert_failure
	assert_output --partial "Invalid port"
}

@test "port_available: returns false for invalid port (zero)" {
	run bash -c 'source "$LIB_DIR/network/port.sh" && port_available 0 2>&1'
	assert_failure
	assert_output --partial "Invalid port"
}

@test "port_available: returns false for invalid port (too high)" {
	run bash -c 'source "$LIB_DIR/network/port.sh" && port_available 65536 2>&1'
	assert_failure
	assert_output --partial "Invalid port"
}

@test "port_available: returns false for empty port" {
	run bash -c 'source "$LIB_DIR/network/port.sh" && port_available "" 2>&1'
	assert_failure
	assert_output --partial "Invalid port"
}

@test "port_available: returns false for non-numeric port" {
	run bash -c 'source "$LIB_DIR/network/port.sh" && port_available "abc" 2>&1'
	assert_failure
	assert_output --partial "Invalid port"
}

@test "port_available: accepts valid port 1" {
	run bash -c 'source "$LIB_DIR/network/port.sh" && port_available 1'
	# Should not fail on validation (may or may not be available)
	[[ "$status" -eq 0 || "$status" -eq 1 ]]
}

@test "port_available: accepts valid port 65535" {
	run bash -c 'source "$LIB_DIR/network/port.sh" && port_available 65535'
	# Should not fail on validation (may or may not be available)
	[[ "$status" -eq 0 || "$status" -eq 1 ]]
}

# =============================================================================
# wait_for_port tests
# =============================================================================

@test "wait_for_port: succeeds when port is already free" {
	run bash -c 'source "$LIB_DIR/network/port.sh" && wait_for_port 49998 1 0.1 2>&1'
	assert_success
	assert_output --partial "Port 49998 is now free"
}

@test "wait_for_port: uses default timeout of 5 seconds" {
	run bash -c 'source "$LIB_DIR/network/port.sh" && wait_for_port 49997 2>&1'
	assert_success
	# Should complete quickly since port is free
	assert_output --partial "Waiting for port 49997"
}

@test "wait_for_port: logs waiting message" {
	run bash -c 'source "$LIB_DIR/network/port.sh" && wait_for_port 49996 1 0.1 2>&1'
	assert_success
	assert_output --partial "Waiting for port 49996 to be released"
}

# =============================================================================
# wait_for_port_listen tests
# =============================================================================

@test "wait_for_port_listen: succeeds when a listener is already bound" {
	run bash -c '
		source "$LIB_DIR/network/port.sh"
		nc -l 127.0.0.1 49995 >/dev/null 2>&1 &
		listener_pid=$!
		trap "kill ${listener_pid} 2>/dev/null || true" EXIT
		sleep 0.2
		wait_for_port_listen 49995 2 0.1
	'
	assert_success
}

@test "wait_for_port_listen: fails when no listener is bound" {
	# Hold an exclusive bind WITHOUT listen() so nothing else can steal the port,
	# while nc/tcp probes still fail (no accepting listener).
	run bash -c '
		source "$LIB_DIR/network/port.sh"
		declare -F wait_for_port_listen >/dev/null || { echo "wait_for_port_listen missing" >&2; exit 1; }
		holder="$(mktemp)"
		python3 - "$holder" <<'"'"'PY'"'"'
import socket, sys, time
path = sys.argv[1]
s = socket.socket()
s.bind(("127.0.0.1", 0))
port = s.getsockname()[1]
open(path, "w", encoding="utf-8").write(str(port))
time.sleep(60)
PY
		py_pid=$!
		trap "kill ${py_pid} 2>/dev/null || true; rm -f ${holder}" EXIT
		for _ in $(seq 1 50); do
			[[ -s "$holder" ]] && break
			sleep 0.05
		done
		port="$(cat "$holder")"
		out="$(wait_for_port_listen "${port}" 1 0.1 2>&1)" && {
			echo "unexpected listen success on bound-but-not-listening port ${port}" >&2
			echo "$out" >&2
			exit 1
		}
		printf "%s\n" "$out"
		case "$out" in
			*"Port ${port} not ready after"*) ;;
			*) echo "missing timeout diagnostic: $out" >&2; exit 1 ;;
		esac
	'
	assert_success
}

@test "wait_for_port_listen: logs waiting message" {
	run bash -c '
		source "$LIB_DIR/network/port.sh"
		declare -F wait_for_port_listen >/dev/null || { echo "wait_for_port_listen missing" >&2; exit 1; }
		holder="$(mktemp)"
		python3 - "$holder" <<'"'"'PY'"'"'
import socket, sys, time
path = sys.argv[1]
s = socket.socket()
s.bind(("127.0.0.1", 0))
port = s.getsockname()[1]
open(path, "w", encoding="utf-8").write(str(port))
time.sleep(60)
PY
		py_pid=$!
		trap "kill ${py_pid} 2>/dev/null || true; rm -f ${holder}" EXIT
		for _ in $(seq 1 50); do
			[[ -s "$holder" ]] && break
			sleep 0.05
		done
		port="$(cat "$holder")"
		out="$(wait_for_port_listen "${port}" 1 0.1 2>&1)" || true
		printf "%s\n" "$out"
		case "$out" in
			*"Waiting for port ${port} to accept connections"*) ;;
			*) echo "missing waiting log: $out" >&2; exit 1 ;;
		esac
		case "$out" in
			*"Port ${port} not ready after"*) ;;
			*) echo "missing timeout diagnostic: $out" >&2; exit 1 ;;
		esac
	'
	assert_success
}

# =============================================================================
# Function export tests
# =============================================================================

@test "port.sh: exports port_available function" {
	run bash -c 'source "$LIB_DIR/network/port.sh" && bash -c "port_available 50000"'
	assert_success
}

@test "port.sh: exports wait_for_port function" {
	run bash -c 'source "$LIB_DIR/network/port.sh" && bash -c "wait_for_port 50001 1 0.1" 2>&1'
	assert_success
}

# =============================================================================
# Guard pattern tests
# =============================================================================

@test "port.sh: can be sourced multiple times without error" {
	run bash -c '
		source "$LIB_DIR/network/port.sh"
		source "$LIB_DIR/network/port.sh"
		source "$LIB_DIR/network/port.sh"
		port_available 50002 2>/dev/null && echo "ok"
	'
	assert_success
	assert_output "ok"
}

@test "port.sh: sets _LGTM_CI_NETWORK_PORT_LOADED guard" {
	run bash -c 'source "$LIB_DIR/network/port.sh" && echo "${_LGTM_CI_NETWORK_PORT_LOADED}"'
	assert_success
	assert_output "1"
}
