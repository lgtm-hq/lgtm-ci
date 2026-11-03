# SPDX-License-Identifier: MIT
"""Selected explicitly by the dispatch-only negative workflow."""


def test_failure() -> None:
    """Keep a genuine pytest failure blocking in the production reusable."""
    raise AssertionError("Intentional #1297 dispatch-only pytest failure")
