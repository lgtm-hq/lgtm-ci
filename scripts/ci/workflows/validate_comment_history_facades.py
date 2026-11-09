#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check that facades of a comment-history publisher expose and forward it (#1365).

Usage: validate_comment_history_facades.py <workflows-dir>
Exits non-zero and prints each violation when a reusable-*.yml that calls a
reusable-publish-*.yml declaring `comment-history` does not itself declare and
forward `comment-history` and `comment-history-limit`.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

INPUTS = ("comment-history", "comment-history-limit")


def main(workflows: Path) -> int:
    """Report facades that call a history-capable publisher without forwarding it.

    Args:
        workflows: Directory holding the reusable workflow files.

    Returns:
        int: 0 when every facade declares and forwards both inputs, else 1.
    """
    declared = re.compile(r"^      comment-history:", re.M)
    publishers = [
        p.name
        for p in sorted(workflows.glob("reusable-publish-*.yml"))
        if declared.search(p.read_text())
    ]
    if not publishers:
        print("no publisher declares comment-history")
        return 1

    problems: list[str] = []
    for facade in sorted(workflows.glob("reusable-*.yml")):
        text = facade.read_text()
        if not any(f"uses: ./.github/workflows/{p}" in text for p in publishers):
            continue
        for name in INPUTS:
            if not re.search(rf"^      {name}:\s*$", text, re.M):
                problems.append(f"{facade.name}: does not declare {name}")
            forward = rf"^      {name}: \$\{{\{{ inputs\.{name} \}}\}}\s*$"
            if not re.search(forward, text, re.M):
                problems.append(f"{facade.name}: does not forward {name}")
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1])))
