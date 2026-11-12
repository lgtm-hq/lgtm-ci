#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Read the apt packages Playwright needs from ``install-deps --dry-run``.

``scripts/ci/lib/testing/playwright_runner.sh`` installs those packages
through ``apt_helper.py`` instead of letting ``playwright install --with-deps``
run apt itself (#1432). Two output formats exist, both read from the
``playwright-core`` sources on npm:

- 1.60 and newer (``reportMissingDependenciesLinux``): Playwright simulates
  the install with ``apt-get install -s`` and prints only what is missing,
  then exits 1::

      Missing system dependencies (2):
        libnss3
        xvfb

  or, with nothing missing, ``All system dependencies are installed.`` and
  exit 0.
- 1.59 and older (``installDependenciesLinux``): it prints the command it
  would run and exits 0::

      sudo -- sh -c "apt-get update&& apt-get install -y
      --no-install-recommends libnss3 xvfb"

  (one line in the real output)

  (``sh -c "..."`` as root, ``su root -c "..."`` without sudo).

Anything else is unrecognised. The caller then falls back to
``playwright install --with-deps``, which is never worse than before.

Usage:
    npx playwright install-deps --dry-run chromium > out.txt; rc=$?
    python3 -I scripts/ci/lib/playwright_deps.py --exit-code "$rc" < out.txt

Exit codes:
    0 - recognised; the packages to install are printed one per line
        (nothing when every dependency is installed)
    1 - unrecognised output, unexpected exit code or an invalid package name
    2 - usage error
"""

from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Sequence
from pathlib import Path

try:
    from apt_helper import is_package_name
except ImportError:  # standalone execution: bootstrap this lib/ directory
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    sys.modules.pop("apt_helper", None)  # a failed attribute import stays cached
    from apt_helper import is_package_name

ALL_INSTALLED = "All system dependencies are installed."
MISSING_HEADER = re.compile(r"Missing system dependencies \(([0-9]+)\):")
MISSING_ITEM = re.compile(r"  (\S+)")
LEGACY_COMMAND = re.compile(
    r'(?:sudo -- sh -c |sh -c |su root -c )"apt-get update&& '
    r'apt-get install -y --no-install-recommends ([^"]+)"',
)
EXIT_UNRECOGNISED = 1


class Unrecognised(Exception):
    """Raised when the dry-run output cannot be trusted."""


def _validated(names: Sequence[str]) -> list[str]:
    """Return the names when every one is a valid package name.

    Raises:
        Unrecognised: When the list is empty or a name is invalid.
    """
    if not names:
        raise Unrecognised("no package names")
    bad = [name for name in names if not is_package_name(name)]
    if bad:
        raise Unrecognised(f"invalid package names: {' '.join(map(repr, bad))}")
    return list(dict.fromkeys(names))


def _missing_list(lines: list[str], start: int) -> list[str]:
    """Read the ``Missing system dependencies (N):`` block starting at ``start``.

    Raises:
        Unrecognised: When the count does not match the listed names.
    """
    header = MISSING_HEADER.fullmatch(lines[start])
    if header is None:
        raise Unrecognised("malformed header")
    expected = int(header.group(1))
    names: list[str] = []
    for line in lines[start + 1 :]:
        item = MISSING_ITEM.fullmatch(line)
        if item is None:
            break
        names.append(item.group(1))
    if len(names) != expected:
        raise Unrecognised(f"header says {expected} packages, found {len(names)}")
    return _validated(names)


def parse(output: str, exit_code: int) -> list[str]:
    """Return the packages a dry run says to install.

    Args:
        output: Combined stdout and stderr of ``install-deps --dry-run``.
        exit_code: Its exit code.

    Returns:
        The package names, de-duplicated in output order; empty when every
        dependency is installed.

    Raises:
        Unrecognised: When the output matches neither format.
    """
    lines = [line.rstrip("\r") for line in output.splitlines()]
    headers = [i for i, line in enumerate(lines) if MISSING_HEADER.fullmatch(line)]
    commands = [m for m in map(LEGACY_COMMAND.fullmatch, lines) if m]
    installed = ALL_INSTALLED in lines
    if len(headers) + len(commands) + int(installed) != 1:
        raise Unrecognised("expected exactly one recognised dry-run result")
    if headers:
        if exit_code != 1:
            raise Unrecognised(f"missing-dependency report exited {exit_code}, not 1")
        return _missing_list(lines, headers[0])
    if exit_code != 0:
        raise Unrecognised(f"dry run exited {exit_code}")
    if installed:
        return []
    return _validated(commands[0].group(1).split())


def main(argv: Sequence[str] | None = None) -> int:
    """Read the dry-run output on stdin and print the packages.

    Args:
        argv: Arguments (defaults to ``sys.argv[1:]``).

    Returns:
        The process exit code.
    """
    parser = argparse.ArgumentParser(prog="playwright_deps.py", description=__doc__)
    parser.add_argument("--exit-code", type=int, required=True)
    args = parser.parse_args(argv)
    try:
        packages = parse(sys.stdin.read(), args.exit_code)
    except Unrecognised as error:
        message = f"[playwright-deps] unrecognised dry-run output: {error}"
        print(message, file=sys.stderr)
        return EXIT_UNRECOGNISED
    for name in packages:
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
