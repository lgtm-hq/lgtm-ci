#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Exercise each maintained inline Trivy installer with real tar/SHA-256 fixtures.
# Bats isolates exported test state and negated assertions end their test body.
# shellcheck disable=SC2030,SC2031,SC2314

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
import sys
import tarfile
from pathlib import Path

import yaml


def create_archive(scratch: Path) -> str:
    """Build a tiny executable tar and return its real SHA-256."""
    payload = (
        b'#!/bin/sh\n[ ! -s "$GITHUB_PATH" ] || exit 96\n'
        b'echo execute >> "$EVENTS"\necho "Version: 0.70.0"\n'
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
                assert step["with"]["version"] == "v0.70.0"
                assert step["with"]["severity"] == "CRITICAL,HIGH"
                assert step["with"]["format"] == "sarif"
                assert step["with"]["exit-code"] == "${{ inputs.scan-exit-code }}"
                body = install["run"]
                assert ".lgtm-ci-tooling" not in body
                assert "get.trivy.dev" not in body
                installers.append(body)
    assert len(installers) == 4
    assert len(set(installers)) == 1
    for index, body in enumerate(installers):
        for pin in (
            "8b4376d5d6befe5c24d503f10ff136d9e0c49f9127a4279fd110b727929a5aa9",
            "2f6bb988b553a1bbac6bdd1ce890f5e412439564e17522b88a4541b4f364fc8d",
        ):
            assert body.count(pin) == 1
            body = body.replace(pin, digest)
        (scratch / "installers" / f"{index}.bash").write_text(body)


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
[[ "$url" == "https://github.com/aquasecurity/trivy/releases/download/v0.70.0/trivy_0.70.0_Linux-${EXPECTED_ARCH}.tar.gz" ]] || exit 93
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
			assert_output --partial 'Version: 0.70.0'
			[ -x "$(cat "$GITHUB_PATH")/trivy" ]
			[ "$(tail -2 "$EVENTS")" = $'extract\nexecute' ]
		else
			assert_failure
			if [[ "$failure" == http ]]; then [ "$status" -eq 22 ]; fi
			if [[ "$failure" == checksum ]]; then assert_output --partial FAILED; fi
			if [[ "$os" != Linux || "$arch" == ARM ]]; then [ ! -s "$EVENTS" ]; fi
			[ ! -s "$GITHUB_PATH" ]
			[ ! -e "${RUNNER_TEMP}/lgtm-ci-trivy-0.70.0" ]
			! grep -Eq '^(extract|execute)$' "$EVENTS"
		fi
		[ -z "$(find "$RUNNER_TEMP" -name 'trivy-download.*' -print)" ]
	done
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
