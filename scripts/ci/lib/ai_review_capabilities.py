#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read the canonical shell review matrix for generators, policy and invocation."""

from __future__ import annotations

import subprocess
from pathlib import Path


def matrix_rows() -> list[list[str]]:
    """Read capability rows without passing credentials or shell startup overrides."""
    result = subprocess.run(
        [
            "/bin/bash",
            "-c",
            'source "$1"; ai_review_matrix_rows',
            "matrix",
            str(Path(__file__).with_name("ai_review_matrix.sh")),
        ],
        env={"PATH": "/usr/bin:/bin"},
        capture_output=True,
        text=True,
        check=True,
    )
    return [line.split("|") for line in result.stdout.splitlines()]
