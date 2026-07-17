#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Docker health-check command mocks for BATS tests
#
# Usage: In your .bats file:
#   load "../../../../helpers/health_mocks"

# Install docker, timeout, and nc mocks used by docker health-check tests.
# Optional first argument sets the container id echoed by docker run.
_install_health_mocks() {
	local container_id="${1:-cid-health-mock}"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	local docker_calls="${BATS_TEST_TMPDIR}/mock_calls_docker"
	mkdir -p "$mock_bin"
	: >"$docker_calls"

	# docker: run prints a container id; logs/rm succeed
	cat >"${mock_bin}/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >> '${docker_calls}'
case "\$1" in
run)
	echo "${container_id}"
	exit 0
	;;
logs|rm)
	exit 0
	;;
*)
	exit 0
	;;
esac
EOF
	chmod +x "${mock_bin}/docker"

	# macOS/CI-safe timeout: ignore duration, run remaining args
	cat >"${mock_bin}/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
	chmod +x "${mock_bin}/timeout"

	# Make port_listening succeed immediately via nc
	cat >"${mock_bin}/nc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "${mock_bin}/nc"

	if [[ ":$PATH:" != *":${mock_bin}:"* ]]; then
		export PATH="${mock_bin}:$PATH"
	fi
}
