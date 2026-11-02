# SPDX-License-Identifier: MIT
"""Reproduce the kcov trace-descriptor boundary in the runner-bump fixture."""

import fcntl
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HELPERS = Path(__file__).resolve().parents[1] / "helpers"


def check_nested_bats(tmp_path: Path, tracing: bool, expected_status: int) -> None:
    """Exact output stays clean under kcov; a real assertion still fails."""
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

    assert result.returncode == expected_status, result.stdout[-1000:]
    assert "kcov@" not in result.stdout
    assert "invalid value for trace file descriptor" not in result.stderr
    if tracing:
        assert "kcov@" in (tmp_path / "trace.log").read_text(encoding="utf-8")


class BatsSubprocessTests(unittest.TestCase):
    """Run under pytest or directly from BATS without extra dependencies."""

    @unittest.skipUnless(
        shutil.which("bats") and shutil.which("timeout"),
        "bats and coreutils timeout are required",
    )
    def test_nested_bats_preserves_output_and_failures(self) -> None:
        """Exercise passing and failing assertions with and without tracing."""
        for tracing in (False, True):
            for expected_status in (0, 1):
                case = self.subTest(tracing=tracing, expected_status=expected_status)
                with case, tempfile.TemporaryDirectory() as directory:
                    check_nested_bats(Path(directory), tracing, expected_status)


if __name__ == "__main__":
    unittest.main()
