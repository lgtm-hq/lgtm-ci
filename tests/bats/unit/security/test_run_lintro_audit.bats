#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/security/run-lintro-audit.sh and fail-audit.sh

load "../../../helpers/common"

setup() {
	setup_temp_dir
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github-output"
	touch "$GITHUB_OUTPUT"
}

teardown() {
	teardown_temp_dir
}

@test "fail-audit: exits with error annotation" {
	run bash "${PROJECT_ROOT}/scripts/ci/security/fail-audit.sh"
	assert_failure
	assert_output --partial "::error::Security audit found vulnerabilities or failed"
}

@test "run-lintro-audit: requires LINTRO_IMAGE" {
	run bash "${PROJECT_ROOT}/scripts/ci/security/run-lintro-audit.sh"
	assert_failure
	assert_output --partial "LINTRO_IMAGE is required"
}

@test "run-lintro-audit: writes comment file when scan results exist" {
	local workspace="${BATS_TEST_TMPDIR}/workspace"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$workspace" "$mock_bin"

	cat >"${mock_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "pull" ]]; then
	printf 'mock pull %s\n' "${2:-}"
	exit 0
fi
if [[ "${1:-}" == "run" ]]; then
	workspace=""
	for ((i = 1; i <= $#; i++)); do
		if [[ "${!i}" == "-v" ]] && [[ $((i + 1)) -le $# ]]; then
			next=$((i + 1))
			mount="${!next}"
			workspace="${mount%%:/code}"
		fi
	done
	if [[ -z "$workspace" ]]; then
		echo "mock docker: missing workspace mount" >&2
		exit 1
	fi
	cat >"${workspace}/osv-results.json" <<'JSON'
{
  "results": [
    {
      "tool": "osv_scanner",
      "issues_count": 0,
      "success": true
    }
  ]
}
JSON
	printf 'mock scan\n' >"${workspace}/osv-output.txt"
	exit 0
fi
echo "unexpected docker invocation: $*" >&2
exit 1
EOF
	chmod +x "${mock_bin}/docker"

	run env \
		PATH="${mock_bin}:${PATH}" \
		LINTRO_IMAGE="ghcr.io/lgtm-hq/py-lintro@sha256:deadbeef" \
		GITHUB_OUTPUT="$GITHUB_OUTPUT" \
		WORKSPACE="$workspace" \
		COMMENT_FILE="security-audit-comment.txt" \
		OSV_RESULTS="osv-results.json" \
		OSV_OUTPUT="osv-output.txt" \
		MAP_HOST_USER=false \
		bash "${PROJECT_ROOT}/scripts/ci/security/run-lintro-audit.sh"

	assert_success
	assert_file_exists "${workspace}/security-audit-comment.txt"
	assert_file_contains "${workspace}/security-audit-comment.txt" "Security Audit Report"
	assert_file_contains "$GITHUB_OUTPUT" "status=passed"
	assert_file_contains "$GITHUB_OUTPUT" "has-vulns=0"
}

# Install a docker mock whose `run` writes the given lintro JSON into the
# mounted workspace and exits with the given scan status.
# Usage: install_docker_mock <mock-bin-dir> <json-fixture> <scan-exit-code>
install_docker_mock() {
	local mock_bin="$1"
	local fixture="$2"
	local scan_exit="$3"
	mkdir -p "$mock_bin"
	cat >"${mock_bin}/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "pull" ]]; then
	exit 0
fi
workspace=""
for ((i = 1; i <= \$#; i++)); do
	if [[ "\${!i}" == "-v" ]]; then
		next=\$((i + 1))
		mount="\${!next}"
		workspace="\${mount%%:/code}"
	fi
done
cp "${fixture}" "\${workspace}/osv-results.json"
printf 'mock scan\n' >"\${workspace}/osv-output.txt"
exit ${scan_exit}
EOF
	chmod +x "${mock_bin}/docker"
}

@test "run-lintro-audit: FORMAT FAILED when probe metadata is missing but TOML has dated entries" {
	local workspace="${BATS_TEST_TMPDIR}/workspace"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$workspace"
	install_fixture "security/osv-scanner-active-stale-expired.toml" "${workspace}/.osv-scanner.toml"
	install_docker_mock "$mock_bin" "${FIXTURES_DIR}/security/osv-results-no-suppressions-meta.json" 0

	# cwd is the audited directory, as the reusable's working-directory sets it.
	run bash -c "cd '${workspace}' && PATH='${mock_bin}:${PATH}' \
		LINTRO_IMAGE='ghcr.io/lgtm-hq/py-lintro@sha256:deadbeef' \
		GITHUB_OUTPUT='${GITHUB_OUTPUT}' WORKSPACE='${workspace}' MAP_HOST_USER=false \
		bash '${PROJECT_ROOT}/scripts/ci/security/run-lintro-audit.sh'"

	assert_failure
	assert_output --partial "Suppression status unavailable"
	assert_file_contains "${workspace}/security-audit-comment.txt" "FORMAT FAILED"
	assert_file_contains "$GITHUB_OUTPUT" "format-failed=1"
	assert_file_contains "$GITHUB_OUTPUT" "status=failed"
}

@test "run-lintro-audit: scanner error keeps its diagnostic when TOML has dated entries" {
	local workspace="${BATS_TEST_TMPDIR}/workspace"
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$workspace"
	install_fixture "security/osv-scanner-active-stale-expired.toml" "${workspace}/.osv-scanner.toml"
	cat >"${BATS_TEST_TMPDIR}/scan-error.json" <<'JSON'
{
  "results": [
    {
      "tool": "osv_scanner",
      "issues_count": 0,
      "success": false,
      "output": "OSV-Scanner timed out after 300s"
    }
  ]
}
JSON
	install_docker_mock "$mock_bin" "${BATS_TEST_TMPDIR}/scan-error.json" 1

	run bash -c "cd '${workspace}' && PATH='${mock_bin}:${PATH}' \
		LINTRO_IMAGE='ghcr.io/lgtm-hq/py-lintro@sha256:deadbeef' \
		GITHUB_OUTPUT='${GITHUB_OUTPUT}' WORKSPACE='${workspace}' MAP_HOST_USER=false \
		bash '${PROJECT_ROOT}/scripts/ci/security/run-lintro-audit.sh'"

	assert_failure
	assert_file_contains "${workspace}/security-audit-comment.txt" "AUDIT FAILED"
	assert_file_contains "${workspace}/security-audit-comment.txt" "OSV-Scanner timed out after 300s"
	assert_file_contains "${workspace}/security-audit-comment.txt" "the scan failed"
	assert_file_contains "$GITHUB_OUTPUT" "format-failed=0"
}

@test "run-lintro-audit: writes github outputs when docker pull fails" {
	local mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"

	cat >"${mock_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "pull" ]]; then
	echo "mock pull failed" >&2
	exit 1
fi
echo "unexpected docker invocation: $*" >&2
exit 1
EOF
	chmod +x "${mock_bin}/docker"

	run env \
		PATH="${mock_bin}:${PATH}" \
		LINTRO_IMAGE="ghcr.io/lgtm-hq/py-lintro@sha256:deadbeef" \
		GITHUB_OUTPUT="$GITHUB_OUTPUT" \
		WORKSPACE="${BATS_TEST_TMPDIR}/workspace" \
		MAP_HOST_USER=false \
		bash "${PROJECT_ROOT}/scripts/ci/security/run-lintro-audit.sh"

	assert_failure
	assert_file_contains "$GITHUB_OUTPUT" "audit-failed=1"
	assert_file_contains "$GITHUB_OUTPUT" "exit-code=1"
	assert_file_contains "$GITHUB_OUTPUT" "status=failed"
	assert_file_contains "$GITHUB_OUTPUT" "has-vulns=0"
}
