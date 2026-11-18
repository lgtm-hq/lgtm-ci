#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Reproduce the kcov trace-descriptor boundary in the runner-bump fixture.

Standard library only: the runner-image BATS suite runs this file with the
system ``python3`` (``python3 bats_subprocess_boundary.py``), inside the
kcov-traced shell where the boundary matters; ``tests/python/
test_bats_subprocess.py`` runs the same cases under pytest.
"""

from __future__ import annotations

import fcntl
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HELPERS = Path(__file__).resolve().parent
# Every (tracing, expected_status) combination the boundary must hold for.
CASES = ((False, 0), (False, 1), (True, 0), (True, 1))


def tools_available() -> bool:
    """Return True when ``bats`` and coreutils ``timeout`` are on PATH."""
    return bool(shutil.which("bats") and shutil.which("timeout"))


def nested_bats_problems(
    tmp_path: Path,
    tracing: bool,
    expected_status: int,
) -> list[str]:
    """Run a nested BATS suite; return what breaks the boundary, if anything.

    Exact output stays clean under kcov; a real assertion still fails.

    Args:
        tmp_path: An empty scratch directory.
        tracing: Whether to run under kcov's tracing preamble.
        expected_status: 0 for a passing nested assertion, 1 for a failing one.

    Returns:
        One message per broken expectation; empty when the boundary holds.
    """
    suite = tmp_path / "boundary.bats"
    expected = "expected" if expected_status == 0 else "different"
    suite.write_text(
        "_value() { printf expected; }\n"
        '@test "nested exact output" {\n'
        "  run _value\n"
        f'  [ "$output" = {expected} ]\n'
        "}\n",
        encoding="utf-8",
    )
    preamble = tmp_path / "bash-helper.sh"
    # kcov v43's actual startup preamble; no collector installation needed.
    preamble.write_text(
        "#!/bin/sh\n\n"
        "# Set PS4, the sh -x prompt.\n"
        "PS4='kcov@${BASH_SOURCE}@${LINENO}@'\n\n"
        "# Turn on tracing\n"
        "set -x\n",
        encoding="utf-8",
    )
    environment = {
        key: value
        for key, value in os.environ.items()
        if key not in {"BASH_ENV", "BASH_XTRACEFD", "KCOV_BASH_XTRACEFD"}
    }
    environment["TMPDIR"] = str(tmp_path)
    command = (
        "import os, sys; "
        "sys.path.insert(0, sys.argv[1]); "
        "from bats_subprocess import run_bats; "
        "run_bats(['--tap', sys.argv[2]], os.environ)"
    )
    with (tmp_path / "trace.log").open("wb") as trace:
        trace_fd = fcntl.fcntl(trace.fileno(), fcntl.F_DUPFD, 100)
        try:
            if tracing:
                environment.update(
                    BASH_ENV=str(preamble),
                    BASH_XTRACEFD=str(trace_fd),
                    KCOV_BASH_XTRACEFD=str(trace_fd),
                )
            # Bound the entire descendant group: the regression loops in BATS
            # failure reporting when Python drops the inherited trace FD.
            result = subprocess.run(
                [
                    "timeout",
                    "--kill-after=1s",
                    "3s",
                    sys.executable,
                    "-c",
                    command,
                    str(HELPERS),
                    str(suite),
                ],
                env=environment,
                pass_fds=(trace_fd,),
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            os.close(trace_fd)

    problems = []
    if result.returncode != expected_status:
        problems.append(
            f"exit status {result.returncode}, expected {expected_status}: "
            f"{result.stdout[-1000:]}",
        )
    if "kcov@" in result.stdout:
        problems.append("kcov trace lines leaked into the BATS output")
    if "invalid value for trace file descriptor" in result.stderr:
        problems.append("bash rejected the inherited trace file descriptor")
    if tracing and "kcov@" not in (tmp_path / "trace.log").read_text(encoding="utf-8"):
        problems.append("the trace file received no kcov trace lines")
    return problems


def main() -> int:
    """Run every case; print each broken expectation.

    Returns:
        0 when every case holds (or the tools are missing), 1 otherwise.
    """
    if not tools_available():
        print("skipped: bats and coreutils timeout are required")
        return 0
    failed = False
    for tracing, expected_status in CASES:
        with tempfile.TemporaryDirectory() as directory:
            problems = nested_bats_problems(Path(directory), tracing, expected_status)
        for problem in problems:
            failed = True
            print(f"tracing={tracing} expected_status={expected_status}: {problem}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
