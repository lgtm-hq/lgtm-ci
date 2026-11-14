#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Print the toolchain a rust-toolchain(.toml) file asks rustup for.

Usage:
    python3 -I read-rust-toolchain.py <rust-toolchain-file>

Prints the ``[toolchain] channel`` value (or, for a legacy
``rust-toolchain`` file that is not TOML, its single line), or nothing when
the file names no channel. Does not validate the channel; ``rust.sh`` does.

Exit status:
    0  printed the channel (possibly empty)
    1  usage error, or the file cannot be read
    3  the file sets ``[toolchain] path``: a toolchain from the checkout
    4  the file cannot be understood (bad TOML, ``channel`` not a string,
       or a legacy file with more than one line)
"""

# pylint: disable=invalid-name  # CLI script; hyphenated filename is the invocation contract

from __future__ import annotations

import sys
import tomllib
from pathlib import Path

EXIT_PATH_TOOLCHAIN = 3
EXIT_UNREADABLE = 4


def read_channel(path: Path) -> str:
    """Return the channel named by a rust-toolchain file.

    Args:
        path: A ``rust-toolchain.toml`` or legacy ``rust-toolchain`` file.

    Returns:
        The channel, or an empty string when the file names none.

    Raises:
        SystemExit: With ``EXIT_PATH_TOOLCHAIN`` when the file sets a
            toolchain ``path``, or ``EXIT_UNREADABLE`` when it cannot be
            understood.
    """
    text = path.read_text(encoding="utf-8")
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        # rustup's legacy format: the whole file is one toolchain name.
        if path.name == "rust-toolchain" and len(lines) <= 1:
            return lines[0] if lines else ""
        print(f"ERROR: cannot parse {path}: {exc}", file=sys.stderr)
        raise SystemExit(EXIT_UNREADABLE) from exc
    toolchain = data.get("toolchain", {})
    if not isinstance(toolchain, dict):
        print(f"ERROR: {path}: [toolchain] is not a table", file=sys.stderr)
        raise SystemExit(EXIT_UNREADABLE)
    if "path" in toolchain:
        print(f"ERROR: {path} sets [toolchain] path", file=sys.stderr)
        raise SystemExit(EXIT_PATH_TOOLCHAIN)
    channel = toolchain.get("channel", "")
    if not isinstance(channel, str):
        print(f"ERROR: {path}: [toolchain] channel is not a string", file=sys.stderr)
        raise SystemExit(EXIT_UNREADABLE)
    return channel


def main() -> None:
    """Print the channel of the rust-toolchain file named in ``sys.argv``."""
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <rust-toolchain-file>", file=sys.stderr)
        sys.exit(1)
    path = Path(sys.argv[1])
    try:
        print(read_channel(path))
    except OSError as exc:
        print(f"ERROR: cannot read {path}: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
