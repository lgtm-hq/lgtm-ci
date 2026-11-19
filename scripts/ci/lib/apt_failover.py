#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Private apt mirror lists and main sources list for ``apt_helper.py`` (#1664).

``apt_mirrors.MirrorPolicy`` points every Ubuntu archive and security source
at a private ``mirror+file:`` list of the hosts egress allows, so apt fails
over between them. This module writes those lists and, when
``/etc/apt/sources.list`` needs the same rewrite (ubuntu-22.04 keeps the
image's ``mirror+file:`` there), a private copy of it for
``Dir::Etc::SourceList``. Everything lives in the helper's private
``Dir::Etc::SourceParts`` directory and goes with it; ``/etc/apt`` is never
written.

How apt reads a list (``methods/mirror.cc``, the same in apt 2.8.4 on noble
and 3.2.1 on resolute apart from trailing-slash handling;
``apt-transport-mirror(1)``): one URI per line, ``#`` and empty lines
skipped, ``key:value`` tags after a tab. Mirrors are tried lowest
``priority`` first and at random among equal priorities, so every line
carries ``priority:N``. A failed request moves to the next mirror
(``pkgAcquire::Worker::HandleFailure``), after ``Acquire::Retries`` retries
for a transient failure. apt's ``file`` and ``mirror`` methods drop to
``_apt`` before they read a list (``DropPrivsOrDie``), so the lists are
``0644`` and the directories above them ``0711``: searchable, not listable.
apt skips the ``mirrors`` and ``main`` subdirectories when it reads its
sources: a directory without an extension is ignored silently
(``GetListOfFilesInDir``). The timing and the evidence are in
docs/workflow-contract.md.

Loaded by ``apt_helper.py`` and ``apt_mirrors.py`` under ``python3 -I`` on
any runner ``python3`` (3.10 on ``ubuntu-22.04``): standard library only.
"""

from __future__ import annotations

import os
import stat
from pathlib import Path

try:
    import apt_sources
except ImportError:  # python3 -I leaves this lib/ directory off sys.path
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import apt_sources

# Subdirectories of the private SourceParts (no extension: apt skips them).
MIRRORS_DIR = "mirrors"
MAIN_DIR = "main"
# The main sources list's file name, in /etc/apt and in the private copy.
MAIN_LIST = "sources.list"
LIST_HEADER = "# Egress-allowed Ubuntu archive hosts, in priority order (#1664).\n"


def sandbox_blocker(parts: Path) -> Path | None:
    """Return a directory above ``parts`` other users cannot search, if any.

    apt's sandbox user ``_apt`` reads the mirror lists, so every directory
    above them must be searchable by others. Only the "other" execute bit
    counts (not groups or ACLs), so access is never over-reported.

    Args:
        parts: The helper's private ``Dir::Etc::SourceParts`` directory.

    Returns:
        The first such directory, or None when ``_apt`` can reach ``parts``.
    """
    for directory in Path(os.path.realpath(parts)).parents:
        try:
            if not os.stat(directory).st_mode & stat.S_IXOTH:
                return directory
        except OSError:
            return directory
    return None


def write_mirror_lists(directory: Path, lists: dict[str, list[str]]) -> list[Path]:
    """Write apt mirror lists into ``directory``, a new child of SourceParts.

    Args:
        directory: Path to create; its parent is the private SourceParts.
        lists: File name to URIs, in the order apt should try them.

    Returns:
        The lists written, in name order.

    Raises:
        OSError: When a list cannot be written; the caller then copies the
            sources unchanged.
    """
    # A new 0700 directory, and "x" (O_CREAT | O_EXCL) never follows a link.
    os.mkdir(directory, 0o700)
    written: list[Path] = []
    for name in sorted(lists):
        path = directory / name
        lines = [f"{uri}\tpriority:{rank}\n" for rank, uri in enumerate(lists[name], 1)]
        with open(path, "x", encoding="utf-8") as out:
            os.fchmod(out.fileno(), 0o644)
            out.write(LIST_HEADER + "".join(lines))
        written.append(path)
    # Set last, once every list is in place: _apt searches, never lists.
    for searchable in (directory, directory.parent):
        os.chmod(searchable, 0o711)  # nosemgrep # nosec B103 - _apt must search
    return written


def copy_main_list(
    main: Path,
    parts: Path,
    rewrite: apt_sources.Rewrite,
) -> Path | None:
    """Write a rewritten private copy of the main sources list, if it changes.

    apt reads ``Dir::Etc::SourceList`` as root, before any method runs, so
    the copy needs no sandbox access. A list whose URIs all stay is not
    copied, and apt keeps reading the real one.

    Args:
        main: ``/etc/apt/sources.list`` (or the test root's copy).
        parts: The helper's private ``Dir::Etc::SourceParts`` directory.
        rewrite: Maps a URI and a suite to the URI to use.

    Returns:
        The private copy for ``Dir::Etc::SourceList``, or None.

    Raises:
        OSError: When the copy cannot be written.
    """
    if not main.is_file():
        return None
    # surrogateescape round-trips any byte that is not UTF-8.
    text = main.read_bytes().decode("utf-8", errors="surrogateescape")
    new = apt_sources.rewrite_text(text, deb822=False, rewrite=rewrite)
    if new == text:
        return None
    directory = parts / MAIN_DIR
    os.mkdir(directory, 0o700)
    path = directory / MAIN_LIST
    with open(path, "xb") as out:
        out.write(new.encode("utf-8", errors="surrogateescape"))
    return path
