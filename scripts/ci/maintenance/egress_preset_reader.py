# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Read one host list from ``scripts/ci/lib/egress/presets.sh``.

Shared by the scheduled checks that compare a preset host list with what
GitHub publishes (``check-results-hosts-drift.py`` #1498,
``check-attestation-store-host.py`` #1644). The list is read by sourcing
``presets.sh`` and calling the named function, never from a second copy.
Standard library only.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

PRESETS = Path(__file__).resolve().parents[3] / "scripts/ci/lib/egress/presets.sh"


class PresetReadError(Exception):
    """Raised when the preset function cannot be run or fails."""


def preset_function_lines(
    function: str,
    presets: Path = PRESETS,
    caller: str = "egress-preset-reader",
) -> list[str]:
    """Return the lines one ``presets.sh`` function prints.

    Args:
        function: Name of the shell function to call, e.g.
            ``egress_github_results_storage_endpoints``.
        presets: Path to ``scripts/ci/lib/egress/presets.sh``.
        caller: ``$0`` for the shell, so errors name the calling check.

    Returns:
        The function's stdout, split into lines.

    Raises:
        PresetReadError: When bash cannot run or the function exits non-zero.
    """
    try:
        completed = subprocess.run(
            ["bash", "-c", 'source "$1" && ' + function, caller, str(presets)],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        raise PresetReadError(f"could not run bash: {error}") from error
    if completed.returncode != 0:
        stderr = completed.stderr.strip()
        raise PresetReadError(f"{function} failed ({completed.returncode}): {stderr}")
    return completed.stdout.splitlines()
