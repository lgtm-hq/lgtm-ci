# SPDX-License-Identifier: MIT
"""Scan a GitHub Actions expression outside its string literals.

Shared by the checks that split an expression at its top level: the
``hashFiles(...)`` argument splitter in ``inlined_setup_python_check.py`` and
the ``&&`` operand splitter in ``test_harden_runner_verify_contract.py``.
"""

from __future__ import annotations

from collections.abc import Iterator


def unquoted(text: str, start: int = 0) -> Iterator[tuple[int, int]]:
    """Yield ``(index, depth)`` for each character outside ``'...'`` literals.

    Args:
        text: Expression text. A doubled ``''`` inside a literal toggles the
            quote state twice, so it stays inside the literal.
        start: Index to start at.

    Yields:
        The index of each unquoted character, quote marks excluded, and the
        number of parentheses around it. A parenthesis counts at the outer
        level, so a ``)`` that closes nothing opened after ``start`` has
        depth -1.
    """
    depth, quoted = 0, False
    for index in range(start, len(text)):
        char = text[index]
        if char == "'":
            quoted = not quoted
            continue
        if quoted:
            continue
        if char == ")":
            depth -= 1
        yield index, depth
        if char == "(":
            depth += 1
