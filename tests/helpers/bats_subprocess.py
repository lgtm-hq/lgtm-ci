# SPDX-License-Identifier: MIT
"""Preserve the coverage collector across Python-based shell fixtures."""

import subprocess
from collections.abc import Mapping, Sequence


def trace_fds(environment: Mapping[str, str]) -> tuple[int, ...]:
    """Keep kcov's trace stream separate from shell fixture assertion output."""
    # Python closes extra descriptors by default, but BASH_ENV still enables
    # xtrace in the child. Losing its collector FD sends traces to stderr;
    # BATS then contaminates assertions and traces its own failure output.
    trace_fd = environment.get("BASH_XTRACEFD") or environment.get("KCOV_BASH_XTRACEFD")
    return (int(trace_fd),) if trace_fd else ()


def run_bats(
    arguments: Sequence[str], environment: Mapping[str, str]
) -> subprocess.CompletedProcess[bytes]:
    """Launch nested BATS without closing its inherited collector descriptor."""
    return subprocess.run(
        ["bats", *arguments],
        check=True,
        env=environment,
        pass_fds=trace_fds(environment),
    )
