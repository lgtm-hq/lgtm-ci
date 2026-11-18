# SPDX-License-Identifier: MIT
"""Reproduce the kcov trace-descriptor boundary in the runner-bump fixture.

The cases live in ``tests/helpers/bats_subprocess_boundary.py``, which the
runner-image BATS suite also runs with the system ``python3``.
"""

from pathlib import Path

import pytest
from assertpy import assert_that
from bats_subprocess_boundary import nested_bats_problems, tools_available


@pytest.mark.skipif(
    not tools_available(),
    reason="bats and coreutils timeout are required",
)
@pytest.mark.parametrize(
    ("tracing", "expected_status"),
    [
        pytest.param(False, 0, id="untraced-passing-assertion"),
        pytest.param(False, 1, id="untraced-failing-assertion"),
        pytest.param(True, 0, id="traced-passing-assertion"),
        pytest.param(True, 1, id="traced-failing-assertion"),
    ],
)
def test_nested_bats_preserves_output_and_failures(
    tmp_path: Path,
    tracing: bool,
    expected_status: int,
) -> None:
    """A nested BATS run keeps its exact output and exit status, traced or not."""
    assert_that(nested_bats_problems(tmp_path, tracing, expected_status)).is_empty()
