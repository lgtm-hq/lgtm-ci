# SPDX-License-Identifier: MIT
"""Launch nested BATS checks from Python-based test fixtures."""

import subprocess
from collections.abc import Mapping, Sequence


def run_bats(
    arguments: Sequence[str], environment: Mapping[str, str]
) -> subprocess.CompletedProcess[bytes]:
    """Keep kcov's trace stream separate from nested BATS assertion output."""
    # Python closes extra descriptors by default, but BASH_ENV still enables
    # xtrace in the child. Losing its collector FD sends traces to stderr;
    # BATS then contaminates assertions and traces its own failure output.
    trace_fd = environment.get("BASH_XTRACEFD") or environment.get("KCOV_BASH_XTRACEFD")
    return subprocess.run(
        ["bats", *arguments],
        check=True,
        env=environment,
        pass_fds=(int(trace_fd),) if trace_fd else (),
    )
