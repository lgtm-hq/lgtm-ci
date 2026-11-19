#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Stable apt mirror lists and a private main sources list for ``apt_helper.py``.

``apt_mirrors.MirrorPolicy`` points every Ubuntu archive and security source
at a ``mirror+file:`` list of the hosts egress allows (#1664), so apt fails
over between them.

The lists live at a fixed path, ``<tmp>/lgtm-ci-apt-mirrors-<euid>/`` with
one fixed name per group (``archive-ubuntu.txt``, ``security-ubuntu.txt``),
never in the helper's per-call temporary directory. apt names the indexes it
keeps in ``/var/lib/apt/lists`` after the source URI (``URItoFileName``), and
a mirror redirect does not change that. With a stable URI, a later
``install --no-update`` finds the indexes an earlier ``update`` fetched, and
apt's check that a new ``InRelease`` is not older than the last one
(``acquire-item.cc``, ``LastMetaIndexParser->GetDate() >
MetaIndexParser->GetDate()``, line 1789 in apt 2.8.4 and 1872 in 3.2.1)
keeps working. Ubuntu's ``InRelease`` has no ``Valid-Until``, so that check
is the only guard against an older, validly signed one. The names stay fixed
when the allowed set changes; only the content follows it.

``publish_lists`` writes each list on every call, and only through a
directory it has checked: a real directory (``lstat``, opened with
``O_NOFOLLOW``), owned by the effective user, writable by no group or other
user. A list is replaced atomically (temporary file in the same directory,
``fsync``, ``os.replace``) unless its bytes already match. An existing list
that is a symlink, not a regular file, owned by another user or writable by
others is refused. A refusal raises ``ListsRefused``, and the caller names
one host per suite directly, as #1661 did.

apt's ``file`` and ``mirror`` methods read a list as ``_apt``
(``DropPrivsOrDie``), so the directory is ``0711`` (searchable, not listable)
and the lists ``0644``. Nothing removes them: they outlive every helper call
for the rest of the job. A GitHub-hosted runner is discarded after its job.
On a persistent runner they stay, and the next call rewrites their content.

``copy_main_list`` writes a rewritten private copy of
``/etc/apt/sources.list`` into the per-call SourceParts directory, for
``Dir::Etc::SourceList``. apt skips that ``main`` subdirectory when it reads
its sources: a directory without an extension is ignored silently
(``GetListOfFilesInDir``).

Loaded by ``apt_helper.py`` and ``apt_mirrors.py`` under ``python3 -I`` on
any runner ``python3`` (3.10 on ``ubuntu-22.04``): standard library only.
"""

from __future__ import annotations

import contextlib
import os
import stat
from pathlib import Path

try:
    import apt_sources
except ImportError:  # python3 -I leaves this lib/ directory off sys.path
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import apt_sources

LISTS_PREFIX = "lgtm-ci-apt-mirrors-"
MAIN_DIR = "main"
# The main sources list's file name, in /etc/apt and in the private copy.
MAIN_LIST = "sources.list"
LIST_HEADER = "# Egress-allowed Ubuntu archive hosts, in priority order (#1664).\n"
LIST_MODE = 0o644
DIR_MODE = 0o711
# Upper bound of an existing list read for comparison; ours are a few lines.
MAX_LIST_BYTES = 1 << 16


class ListsRefused(Exception):
    """Raised when the stable lists cannot be trusted; the message says why."""


def lists_dir(root: Path) -> Path:
    """Return the stable per-user directory of the mirror lists under ``root``."""
    return root / f"{LISTS_PREFIX}{os.geteuid()}"


def sandbox_blocker(path: Path) -> Path | None:
    """Return a directory above ``path`` other users cannot search, if any.

    apt's sandbox user ``_apt`` reads the mirror lists, so every directory
    above them must be searchable by others. Only the "other" execute bit
    counts (not groups or ACLs), so access is never over-reported.

    Args:
        path: The lists' directory.

    Returns:
        The first such directory, or None when ``_apt`` can reach ``path``.
    """
    for directory in Path(os.path.realpath(path)).parents:
        try:
            if not os.stat(directory).st_mode & stat.S_IXOTH:
                return directory
        except OSError:
            return directory
    return None


def _trusted(info: os.stat_result, what: str) -> None:
    """Refuse an entry owned by another user or writable by group or others."""
    if info.st_uid != os.geteuid():
        raise ListsRefused(f"{what} is owned by uid {info.st_uid}")
    if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise ListsRefused(f"{what} is writable by group or others")


def _open_dir(directory: Path) -> int:
    """Create or open the lists' directory, checked, and make it ``0711``."""
    with contextlib.suppress(FileExistsError):
        os.mkdir(directory, 0o700)
    info = os.lstat(directory)
    if not stat.S_ISDIR(info.st_mode):
        raise ListsRefused(f"{directory} is not a directory (or is a symlink)")
    _trusted(info, str(directory))
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        _trusted(info, str(directory))
        os.fchmod(fd, DIR_MODE)  # nosemgrep # nosec B103 - _apt must search it
    except BaseException:
        os.close(fd)
        raise
    return fd


def _matches(fd: int, name: str, data: bytes) -> bool:
    """Return whether list ``name`` already holds ``data``; refuse a bad entry."""
    try:
        info = os.lstat(name, dir_fd=fd)
    except FileNotFoundError:
        return False
    if not stat.S_ISREG(info.st_mode):
        raise ListsRefused(f"{name} is not a regular file (or is a symlink)")
    _trusted(info, name)
    if stat.S_IMODE(info.st_mode) != LIST_MODE or info.st_size != len(data):
        return False
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    with os.fdopen(os.open(name, flags, dir_fd=fd), "rb") as handle:
        return handle.read(MAX_LIST_BYTES) == data


def _replace(fd: int, name: str, data: bytes) -> None:
    """Write ``data`` to a temporary file, ``fsync`` it, rename it over ``name``."""
    temporary = f".{name}.{os.getpid()}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    out = os.open(temporary, flags, LIST_MODE, dir_fd=fd)
    try:
        with os.fdopen(out, "wb") as handle:
            os.fchmod(handle.fileno(), LIST_MODE)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, name, src_dir_fd=fd, dst_dir_fd=fd)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary, dir_fd=fd)
        raise


def list_bytes(uris: list[str]) -> bytes:
    """Return a mirror list: one ``URI<TAB>priority:N`` line per mirror.

    apt orders mirrors by ``priority`` and at random among equal ones
    (``methods/mirror.cc``, ``apt-transport-mirror(1)``), so each line has one.
    """
    lines = [f"{uri}\tpriority:{rank}\n" for rank, uri in enumerate(uris, 1)]
    return (LIST_HEADER + "".join(lines)).encode("utf-8")


def publish_lists(directory: Path, lists: dict[str, list[str]]) -> list[Path]:
    """Write the mirror lists into the stable ``directory``, idempotently.

    Args:
        directory: ``lists_dir(root)``.
        lists: File name to URIs, in the order apt should try them.

    Returns:
        The lists, in name order.

    Raises:
        ListsRefused: When the directory or a list fails a check.
        OSError: When a list cannot be written.
    """
    fd = _open_dir(directory)
    try:
        for name in sorted(lists):
            data = list_bytes(lists[name])
            if not _matches(fd, name, data):
                _replace(fd, name, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    return [directory / name for name in sorted(lists)]


def uses_lists(parts: Path, directory: Path) -> bool:
    """Return whether a sources file in ``parts`` names a list in ``directory``."""
    needle = f"mirror+file:{directory}/"
    files = [*parts.glob("*.list"), *parts.glob("*.sources")]
    files.append(parts / MAIN_DIR / MAIN_LIST)
    texts = [p.read_text("utf-8", errors="replace") for p in files if p.is_file()]
    return any(needle in text for text in texts)


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
