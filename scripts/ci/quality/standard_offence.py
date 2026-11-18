# SPDX-License-Identifier: MIT
"""The offence record the standard checks report (#1625, #1626).

Shared by ``validate_test_standard.py`` (through ``standard_scan.py``) and
``validate_source_standard.py``. Kept to the standard library and to Python
3.9 syntax: CI runs the checks with the runner's ``python3``.
"""

from __future__ import annotations

from dataclasses import dataclass

__all__ = ["Offence"]


@dataclass(frozen=True)
class Offence:
    """One place in a scanned file that breaks a rule.

    Attributes:
        file: The file's repository-relative path.
        line: The line the offence starts on.
        rule: The rule's name.
        what: What is wrong, in a few words.
    """

    file: str
    line: int
    rule: str
    what: str

    def render(self) -> str:
        """Return the offence as ``file:line: [rule] what``."""
        return f"{self.file}:{self.line}: [{self.rule}] {self.what}"
