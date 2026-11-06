#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Exercise each maintained inline Trivy installer with real tar/SHA-256 fixtures.
# Bats isolates exported test state.
# shellcheck disable=SC2030,SC2031

load "../../helpers/common"

setup() {
	require_python_yaml
	export FIXTURE="${BATS_TEST_TMPDIR}/fixture.tar.gz"
	export EVENTS="${BATS_TEST_TMPDIR}/events"
	mkdir -p "${BATS_TEST_TMPDIR}/bin" "${BATS_TEST_TMPDIR}/installers"
	"$PY" - "$PROJECT_ROOT" "$BATS_TEST_TMPDIR" <<'PY'
"""Prepare verified archive fixtures from maintained Docker workflows."""

import hashlib
import io
import shlex
import sys
import tarfile
from pathlib import Path

import yaml


def create_archive(scratch: Path) -> str:
    """Build a tiny executable tar and return its real SHA-256."""
    payload = (
        b'#!/bin/sh\nset -eu\nif [ "$1" = --version ]; then\n'
        b'[ ! -s "$GITHUB_PATH" ] || exit 96\n'
        b'echo execute >> "$EVENTS"\necho "Version: 0.76.2"\nelse\n'
        b'[ "$1" = image ] && [ "$#" = 2 ] && [ -n "$2" ]\n'
        b'[ "${TRIVY_SKIP_VERSION_CHECK:-}" = true ]\n'
        b'[ "${TRIVY_DISABLE_TELEMETRY:-}" = true ]\n'
        b'[ -s "$GITHUB_PATH" ]\necho scan >> "$EVENTS"\nfi\n'
    )
    with tarfile.open(scratch / "fixture.tar.gz", "w:gz") as archive:
        member = tarfile.TarInfo("trivy")
        member.mode = 0o755
        member.size = len(payload)
        archive.addfile(member, io.BytesIO(payload))
    return hashlib.sha256((scratch / "fixture.tar.gz").read_bytes()).hexdigest()


def prepare_fixture() -> None:
    """Validate scanner boundaries and replace release pins only in scratch."""
    scanner_action = "aquasecurity/trivy-action@"
    scanner_action += "ed142fd0673e97e23eac54620cfb913e5ce36c25"
    root, scratch = map(Path, sys.argv[1:])
    digest = create_archive(scratch)
    installers = []
    scanners = []
    for path in sorted((root / ".github/workflows").glob("reusable-docker*.yml")):
        workflow = yaml.safe_load(path.read_text())
        inputs = workflow.get("on", workflow.get(True))["workflow_call"]["inputs"]
        assert not any("trivy" in name for name in inputs), path
        for job in workflow["jobs"].values():
            steps = job.get("steps", [])
            for index, step in enumerate(steps):
                if not step.get("uses", "").startswith("aquasecurity/trivy-action@"):
                    continue
                assert step["uses"] == scanner_action
                install = steps[index - 1]
                assert install["name"] == "Install verified Trivy"
                assert install.get("if") == step.get("if")
                assert set(install) - {"if"} == {"name", "shell", "run"}
                assert ("if" in install) == ("if" in step)
                assert install["shell"] == "bash"
                assert step["with"]["skip-setup-trivy"] == "true"
                assert step["with"]["version"] == "v0.76.2"
                assert step["with"]["severity"] == "CRITICAL,HIGH"
                assert step["with"]["format"] == "sarif"
                assert step["with"]["exit-code"] == "${{ inputs.scan-exit-code }}"
                body = install["run"]
                assert ".lgtm-ci-tooling" not in body
                assert "get.trivy.dev" not in body
                installers.append(body)
                env = step.get("env", {})
                scanners.append(
                    "\n".join(f"export {key}={shlex.quote(str(value))}" for key, value in env.items())
                    + "\ntrivy image " + shlex.quote(step["with"]["image-ref"]) + "\n"
                )
    assert len(installers) == 4
    assert len(set(installers)) == 1
    for index, body in enumerate(installers):
        for pin in (
            "bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf",
            "ab9d51f86e6a5fb936f605faff6b593ac51bc378fff4d3e8b9d58358b9c367c3",
        ):
            assert body.count(pin) == 1
            body = body.replace(pin, digest)
        (scratch / "installers" / f"{index}.bash").write_text(body)
        (scratch / "installers" / f"{index}.scan").write_text(scanners[index])


prepare_fixture()
PY
	cat >"${BATS_TEST_TMPDIR}/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -eu
args=" $* "
for flag in --fail --silent --show-error --location --connect-timeout --max-time; do
	[[ "$args" == *" $flag "* ]] || exit 91
done
[[ "$args" == *" --proto =https "* && "$args" == *" --proto-redir =https "* ]] || exit 92
output=
while [[ $# -gt 0 ]]; do
	case "$1" in
	-o | --output) output=$2; shift 2 ;;
	*) url=$1; shift ;;
	esac
done
printf '%s\n' "$url" >>"$EVENTS"
[[ "$url" == "https://github.com/aquasecurity/trivy/releases/download/v0.76.2/trivy_0.76.2_Linux-${EXPECTED_ARCH}.tar.gz" ]] || exit 93
[[ "${FAILURE:-}" != http ]] || exit 22
if [[ "${FAILURE:-}" == checksum ]]; then printf corrupt >"$output"
else cp "$FIXTURE" "$output"; fi
MOCK
	cat >"${BATS_TEST_TMPDIR}/bin/tar" <<'MOCK'
#!/usr/bin/env bash
echo extract >>"$EVENTS"
exec /usr/bin/tar "$@"
MOCK
	chmod +x "${BATS_TEST_TMPDIR}/bin/"*
	export PATH="${BATS_TEST_TMPDIR}/bin:$PATH"
}

exercise_boundaries() {
	local arch="$1" failure="${2:-}" os="${3:-Linux}" script
	for script in "${BATS_TEST_TMPDIR}/installers/"*.bash; do
		export RUNNER_TEMP="${script%.bash}-runner"
		export GITHUB_PATH="${RUNNER_TEMP}/path"
		mkdir -p "$RUNNER_TEMP"
		: >"$GITHUB_PATH"
		: >"$EVENTS"
		local archive_arch=ARM64
		if [[ "$arch" == X64 ]]; then archive_arch=64bit; fi
		run env RUNNER_OS="$os" RUNNER_ARCH="$arch" FAILURE="$failure" \
			EXPECTED_ARCH="$archive_arch" bash "$script"
		if [[ -z "$failure" && "$os" == Linux && "$arch" != ARM ]]; then
			assert_success
			assert_output --partial 'Version: 0.76.2'
			[ -x "$(cat "$GITHUB_PATH")/trivy" ]
			[ "$(tail -2 "$EVENTS")" = $'extract\nexecute' ]
			run env PATH="$(cat "$GITHUB_PATH"):$PATH" \
				TRIVY_SKIP_VERSION_CHECK=false TRIVY_DISABLE_TELEMETRY=false \
				bash -e "${script%.bash}.scan"
			assert_success
			[ "$(tail -1 "$EVENTS")" = scan ]
		else
			assert_failure
			if [[ "$failure" == http ]]; then [ "$status" -eq 22 ]; fi
			if [[ "$failure" == checksum ]]; then assert_output --partial FAILED; fi
			if [[ "$os" != Linux || "$arch" == ARM ]]; then [ ! -s "$EVENTS" ]; fi
			[ ! -s "$GITHUB_PATH" ]
			[ ! -e "${RUNNER_TEMP}/lgtm-ci-trivy-0.76.2" ]
			run grep -Eq '^(extract|execute)$' "$EVENTS"
			assert_failure 1
		fi
		[ -z "$(find "$RUNNER_TEMP" -name 'trivy-download.*' -print)" ]
	done
}

@test "Trivy egress: production Docker preset has no obsolete binary or notification hosts" {
	run bash -c 'source "$1"; egress_preset_endpoints docker' test \
		"${PROJECT_ROOT}/scripts/ci/lib/egress/presets.sh"
	assert_success
	refute_output --partial get.trivy.dev
	refute_output --partial check.trivy.dev
	assert_line mirror.gcr.io:443
	assert_line release-assets.githubusercontent.com:443
	run bash "${PROJECT_ROOT}/scripts/ci/egress/sync-workflow-presets.sh" --check
	assert_success
}

@test "Trivy acquisition: all four boundaries install verified ARM64 before publishing PATH" {
	exercise_boundaries ARM64
}

@test "Trivy acquisition: all four boundaries install verified X64 before publishing PATH" {
	exercise_boundaries X64
}

@test "Trivy acquisition: HTTP errors fail closed at every boundary" {
	exercise_boundaries ARM64 http
	exercise_boundaries X64 http
}

@test "Trivy acquisition: checksum mismatch prevents extraction, execution and PATH publication" {
	exercise_boundaries X64 checksum
	exercise_boundaries ARM64 checksum
}

@test "Trivy acquisition: unsupported runners fail before network access" {
	exercise_boundaries ARM
	[ ! -s "$EVENTS" ]
	exercise_boundaries X64 '' Windows
	[ ! -s "$EVENTS" ]
}
