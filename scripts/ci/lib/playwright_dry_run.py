#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Read ``playwright install --dry-run`` output into its artifact list (#1433).

``playwright_browsers.py`` uses the list to decide whether a restored browser
cache is complete (``present``) and which directories the ``ldd`` probe scans.
The dry run prints, on stdout, one record per artifact the real install would
put down, at the exact revision the installed Playwright expects for the host:

    <header>
      Install location:    <absolute directory | <system>>
      Download url:        <url>            (optional)
      Download fallback 1: <url>            (optional, repeated)
    <blank line>

Two header formats exist, read from playwright-core's install action:

- Playwright 1.57 and older (``src/cli/program.ts``):
  ``browser: <name>[ version <browserVersion>]``
- Playwright 1.58 and newer (``registry.calculateDownloadTitle``, checked
  in 1.58.0, 1.59.0, 1.60.0, 1.61.0, 1.62.0 and 1.63.0):
  ``<Title>[ <browserVersion>] (playwright <name> v<revision>)``

The reading is all or nothing: any line that is not part of a well-formed
record (an unknown header, an orphan or second location, a location without a
header, stray text), a ``<system>`` location (a channel such as ``chrome``,
installed outside the cache), a relative location, or a directory whose name
does not belong to its artifact makes the whole list unknown. Callers treat
unknown as "not present" and "cannot decide", so the install and the system
packages run. Records may repeat (1.56.1 lists FFmpeg twice for chromium);
repeats are folded.

Standard library only and Python 3.10 compatible (``python3 -I`` on the
runner's own interpreter, through ``playwright_browsers.py``).
"""

from __future__ import annotations

import os
import re
from pathlib import Path

LEGACY_HEADER = re.compile(r"browser: ([a-z][a-z0-9-]*)(?: version \S+)?")
MODERN_HEADER = re.compile(r"\S.* \(playwright ([a-z][a-z0-9-]*) v([0-9]+)\)")
LOCATION = re.compile(r"  Install location:    (\S.*)")
DOWNLOAD = re.compile(r"  Download (?:url|fallback [1-9][0-9]*): +\S+")
SYSTEM_LOCATION = "<system>"


class Unrecognised(Exception):
    """Raised when the dry run output is not a list of well-formed records."""


def _header(line: str) -> tuple[str, str | None] | None:
    """Return ``(name, revision)`` of a record header, or None.

    Args:
        line: One output line.

    Returns:
        The artifact name and, in the 1.58+ format, its revision (the legacy
        format prints none).
    """
    modern = MODERN_HEADER.fullmatch(line)
    if modern:
        return modern.group(1), modern.group(2)
    legacy = LEGACY_HEADER.fullmatch(line)
    if legacy:
        return legacy.group(1), None
    return None


def _location(raw: str, name: str, revision: str | None) -> Path:
    """Return the validated install directory of one record.

    Playwright names the directory ``<name>-<revision>`` with ``-`` in the
    name turned into ``_``, or ``<name>_<host>_special-<revision>`` when the
    host has a revision override.

    Args:
        raw: The text after ``Install location:``.
        name: The record's artifact name.
        revision: Its revision, when the header carries one.

    Returns:
        The directory.

    Raises:
        Unrecognised: For ``<system>``, a relative path or a foreign name.
    """
    if raw == SYSTEM_LOCATION:
        raise Unrecognised(f"{name} installs outside the browser cache")
    path = Path(raw)
    if not path.is_absolute():
        raise Unrecognised(f"{name} has a relative install location")
    prefix = re.escape(name.replace("-", "_"))
    suffix = re.escape(revision) if revision else "[0-9]+"
    if not re.fullmatch(rf"{prefix}(?:_[A-Za-z0-9._]+_special)?-{suffix}", path.name):
        raise Unrecognised(f"{name} has an unexpected install directory {path.name!r}")
    return path


def parse(text: str) -> list[tuple[str, Path]]:
    """Return every artifact of a dry run, all or nothing.

    Args:
        text: The dry run's stdout.

    Returns:
        ``(name, directory)`` pairs in output order, repeats folded.

    Raises:
        Unrecognised: When any line is not part of a well-formed record, or
            no record is listed.
    """
    found: list[tuple[str, Path]] = []
    name: str | None = None  # the open record's artifact name
    revision: str | None = None
    located = False
    for raw in text.splitlines():
        line = raw.rstrip("\r")
        if not line.strip():
            if name is not None and not located:
                raise Unrecognised(f"{name} has no install location")
            name, revision, located = None, None, False
            continue
        header = _header(line)
        if header is not None:
            if name is not None and not located:
                raise Unrecognised(f"{name} has no install location")
            (name, revision), located = header, False
            continue
        location = LOCATION.fullmatch(line)
        if location is not None:
            if name is None or located:
                raise Unrecognised("an install location belongs to no record")
            path = _location(location.group(1).strip(), name, revision)
            if (name, path) not in found:
                found.append((name, path))
            located = True
            continue
        if name is not None and located and DOWNLOAD.fullmatch(line):
            continue
        raise Unrecognised(f"unrecognised line {line!r}")
    if name is not None and not located:
        raise Unrecognised(f"{name} has no install location")
    if not found:
        raise Unrecognised("no artifact listed")
    return found


def install_locations(
    dry_run: str,
    root: Path | None = None,
) -> list[tuple[str, Path]] | None:
    """Return each artifact ``playwright install --dry-run`` would install.

    Args:
        dry_run: Its stdout.
        root: When given, every artifact must sit directly in this browser
            directory (the one the cache saves); None skips the check.

    Returns:
        ``(name, directory)`` pairs, or None when the output is not
        recognised in full or an artifact lies outside ``root``.
    """
    try:
        found = parse(dry_run)
    except Unrecognised:
        return None
    if root is not None:
        expected = os.path.normpath(root)
        if any(os.path.normpath(path.parent) != expected for _, path in found):
            return None
    return found
