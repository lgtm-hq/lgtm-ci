#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Shared offline fixtures for hardener runtime and Docker workflow contracts
# Bats isolates each test's environment; negated assertions end their test body.
# shellcheck disable=SC2030,SC2031,SC2314

# shellcheck source=common.bash
load "${BASH_SOURCE[0]%/*}/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/docker/wait-for-harden-runner.sh"
CONTRACT="${PROJECT_ROOT}/tests/helpers/docker_readiness_contract.py"
export TIMEOUT_CONTRACT="${PROJECT_ROOT}/tests/helpers/docker_readiness_timeout.py"

setup() {
	# Exercise Python's inherited collector descriptor even outside kcov. Under
	# coverage retain the real collector so nested production shells stay traced.
	if [[ -z "${BASH_XTRACEFD:-${KCOV_BASH_XTRACEFD:-}}" ]]; then
		local trace_fd
		exec {trace_fd}>"${BATS_TEST_TMPDIR}/trace"
		export BASH_XTRACEFD="$trace_fd"
	fi
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
		if [[ "$layout" == missing || ("$layout" == gnu-timeout && "$name" == gnutimeout) ]]; then
			continue
		fi
		if [[ ("$layout" == gnu-prefixed && "$name" == gnutimeout) || ("$layout" == gnu-timeout* && "$name" == timeout) ]]; then
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
