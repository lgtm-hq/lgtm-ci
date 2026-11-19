#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Read, filter and rewrite apt sources files for ``apt_helper.py`` (#1432).

``apt_helper.py`` loads this module under ``python3 -I`` on any runner
``python3`` (3.10 on ``ubuntu-22.04``), so it stays standard-library only and
3.10-compatible.

- ``source_uris`` reads the URIs of the enabled entries of a one-line
  ``.list`` or a deb822 ``.sources`` file; ``apt_false`` is apt's own boolean
  parser for ``Enabled``.
- ``is_third_party`` tells whether a file only points at
  ``THIRD_PARTY_HOSTS``; ``filter_sources`` copies every other file into the
  helper's private ``Dir::Etc::SourceParts``.
- ``rewrite_text`` changes the URIs of enabled entries in such a copy through
  a callback (``apt_mirrors.MirrorPolicy.rewrite_for``, #1661) and keeps
  every other field of the entry: types, options, components and
  ``Signed-By``. A deb822 paragraph whose suites go to different hosts is
  split into one paragraph per host. The real ``/etc/apt`` is never written.
"""

from __future__ import annotations

import re
import shutil
from collections.abc import Callable, Sequence
from pathlib import Path
from urllib.parse import urlsplit

# Known add-on repositories a job never needs. packages.microsoft.com is the
# only one on GitHub's Ubuntu 24.04 and 26.04 images (runs 42736549231 and
# 43039395926 fetch nothing else besides the Ubuntu archives).
THIRD_PARTY_HOSTS = frozenset(
    {"packages.microsoft.com", "ppa.launchpadcontent.net", "ppa.launchpad.net"},
)
# The distribution's own deb822 sources, kept whatever host they point at.
DISTRIBUTION_SOURCES = frozenset({"ubuntu.sources", "debian.sources"})

# apt's boolean parser (StringToBool) reads these words as false.
DISABLED_VALUES = frozenset({"no", "false", "0", "off", "without", "disable"})
# StringToBool first tries strtol(value, &end, 0) and uses it only when the
# whole value is that number (leading whitespace allowed): 0 or 1 decides, in
# decimal, octal or hex, with an optional sign. apt-pkg/contrib/strutl.cc.
_STRTOL_PREFIX = re.compile(r"\s*([+-]?)(0[xX][0-9a-fA-F]+|0[0-7]*|[1-9][0-9]*)")
# One-line entry: prefix (type and [options]), URI, then suite and the rest.
_LIST_ENTRY = re.compile(r"^(\s*deb(?:-src)?\s+(?:\[[^\]]*\]\s+)?)(\S+)(\s+(\S+).*)?$")

# One deb822 paragraph to write: its URIs and its suites.
Group = tuple[list[str], list[str]]
# Maps one entry's URI and one of its suites ("" when it has none) to the URI
# apt should use for that suite.
Rewrite = Callable[[str, str], str]


def apt_false(value: str) -> bool:
    """Tell whether apt's StringToBool reads ``value`` as false.

    Args:
        value: A deb822 field value, such as ``Enabled``.

    Returns:
        True for a value that is wholly a number equal to 0, or a false word.
    """
    match = _STRTOL_PREFIX.fullmatch(value)
    if match:
        digits = match.group(2)
        if digits[:2].lower() == "0x":
            base = 16
        elif len(digits) > 1 and digits.startswith("0"):
            base = 8
        else:
            base = 10
        number = int(digits, base)
        if match.group(1) == "-":
            number = -number
        # strtol saturates at the 64-bit long range, and apt keeps the result
        # in a 32-bit int, so the value wraps: 4294967296 reads as 0.
        number = max(-(2**63), min(number, 2**63 - 1))
        number = (number + 2**31) % 2**32 - 2**31
        if number in (0, 1):
            return number == 0
    return value.strip().lower() in DISABLED_VALUES


def deb822_paragraphs(text: str) -> list[dict[str, str]]:
    """Parse deb822 text into paragraphs of lower-cased field names.

    Continuation lines (starting with a space or tab) extend the previous
    field's value on a new line; ``#`` lines are comments.

    Args:
        text: File contents.

    Returns:
        One mapping per paragraph.
    """
    paragraphs: list[dict[str, str]] = []
    current: dict[str, str] = {}
    key = ""
    for raw in text.splitlines():
        if raw.startswith("#"):
            continue
        if not raw.strip():
            if current:
                paragraphs.append(current)
            current, key = {}, ""
            continue
        if raw[0] in " \t":
            if key:
                current[key] += "\n" + raw.strip()
            continue
        name, sep, value = raw.partition(":")
        if not sep:
            continue
        key = name.strip().lower()
        current[key] = value.strip()
    if current:
        paragraphs.append(current)
    return paragraphs


def _enabled(paragraph: dict[str, str]) -> bool:
    """Return whether apt uses a deb822 paragraph (``Enabled`` not false)."""
    return not apt_false(paragraph.get("enabled", "yes"))


def source_uris(text: str, deb822: bool) -> list[str]:
    """Extract the URIs of the enabled entries of one sources file.

    Args:
        text: File contents.
        deb822: True for a ``.sources`` file, False for a one-line ``.list``.

    Returns:
        Every URI of an entry apt would use, in file order. deb822
        paragraphs with ``Enabled: no`` are skipped.
    """
    if deb822:
        return [
            uri
            for paragraph in deb822_paragraphs(text)
            if _enabled(paragraph)
            for uri in paragraph.get("uris", "").split()
        ]
    uris: list[str] = []
    for line in text.splitlines():
        match = _LIST_ENTRY.match(line)
        if match and not line.lstrip().startswith("#"):
            uris.append(match.group(2))
    return uris


def host_of(uri: str) -> str:
    """Return the lower-cased host of a URI, or an empty string."""
    try:
        host = urlsplit(uri).hostname or ""
    except ValueError:
        return ""
    return host.rstrip(".")


def is_third_party(path: Path) -> bool:
    """Return whether a sources file only points at known third-party hosts.

    Args:
        path: A ``.list`` or ``.sources`` file.

    Returns:
        True when the file has enabled URIs and every one of them is on a
        ``THIRD_PARTY_HOSTS`` host. A hostless URI is never third party, and
        the distribution's own sources are always kept.
    """
    if path.name in DISTRIBUTION_SOURCES:
        return False
    text = path.read_text(encoding="utf-8", errors="replace")
    uris = source_uris(text, deb822=path.suffix == ".sources")
    return bool(uris) and all(host_of(uri) in THIRD_PARTY_HOSTS for uri in uris)


def _plan(uris: Sequence[str], suites: Sequence[str], rewrite: Rewrite) -> list[Group]:
    """Group an entry's (target URI, suite) pairs into paragraphs.

    Args:
        uris: The entry's URIs.
        suites: Its suites (empty when it has no ``Suites`` field).
        rewrite: Maps a URI and a suite to the URI to use.

    Returns:
        ``(uris, suites)`` per paragraph to write, in first-seen order; one
        group equal to the input when nothing changes.
    """
    targets: dict[str, list[str]] = {}
    for uri in uris:
        for suite in suites or [""]:
            seen = targets.setdefault(rewrite(uri, suite), [])
            if suite not in seen:
                seen.append(suite)
    groups: dict[tuple[str, ...], list[str]] = {}
    for target, its_suites in targets.items():
        groups.setdefault(tuple(its_suites if suites else []), []).append(target)
    return [(group_uris, list(key)) for key, group_uris in groups.items()]


def _ending(line: str) -> str:
    """Return a line's own line ending (``\\r\\n`` or ``\\n``), or ""."""
    return line[len(line.rstrip("\r\n")) :]


def _set_field(lines: list[str], field: str, value: str) -> list[str]:
    """Replace a deb822 field's whole value, as apt reads it.

    apt drops ``#`` comment lines before it parses a paragraph
    (``pkgTagFile::SUPPORT_COMMENTS``), so a comment inside a field does not
    end it: the field runs on through every following line that starts with
    a space or a tab, comments in between. All of those continuation lines
    go; the comments stay where they were. The new value keeps the field
    line's own line ending.
    """
    for index, line in enumerate(lines):
        name, sep, _ = line.partition(":")
        if line[:1] in ("#", " ", "\t") or not sep or name.strip().lower() != field:
            continue
        end = index + 1
        while end < len(lines) and lines[end][:1] in ("#", " ", "\t"):
            end += 1
        kept = [extra for extra in lines[index + 1 : end] if extra.startswith("#")]
        eol = _ending(line) or "\n"
        return [*lines[:index], f"{name}: {value}{eol}", *kept, *lines[end:]]
    return lines


def _rewrite_paragraph(lines: list[str], rewrite: Rewrite) -> list[str]:
    """Rewrite one deb822 paragraph, split by suite when its targets differ.

    A paragraph whose suites now go to different hosts (an archive and the
    security host) becomes one paragraph per host; each copy keeps every
    other field, ``Signed-By`` included. A paragraph with no URI (disabled,
    or without a ``URIs`` field) is returned as it is.
    """
    parsed = deb822_paragraphs("".join(lines))
    if not parsed or not _enabled(parsed[0]):
        return lines
    uris = parsed[0].get("uris", "").split()
    suites = parsed[0].get("suites", "").split()
    if not uris:
        return lines
    groups = _plan(uris, suites, rewrite)
    if groups == [(uris, suites)]:
        return lines
    # Line ending of the paragraph's first line, for lines this code adds.
    eol = _ending(lines[0]) or "\n"
    if not _ending(lines[-1]):
        lines = [*lines[:-1], lines[-1] + eol]
    out: list[str] = []
    for number, (targets, its_suites) in enumerate(groups):
        if number:
            out.append(eol)
        copy = _set_field(lines, "uris", " ".join(targets))
        if its_suites:
            copy = _set_field(copy, "suites", " ".join(its_suites))
        out.extend(copy)
    return out


def _rewrite_deb822(text: str, rewrite: Rewrite) -> str:
    """Rewrite the URIs of every enabled paragraph of a deb822 file."""
    out: list[str] = []
    paragraph: list[str] = []
    for line in text.splitlines(keepends=True):
        if line.strip():
            paragraph.append(line)
            continue
        if paragraph:
            out.extend(_rewrite_paragraph(paragraph, rewrite))
        out.append(line)
        paragraph = []
    if paragraph:
        out.extend(_rewrite_paragraph(paragraph, rewrite))
    return "".join(out)


def _rewrite_list(text: str, rewrite: Rewrite) -> str:
    """Rewrite the URI of every uncommented one-line entry."""
    out: list[str] = []
    for line in text.splitlines(keepends=True):
        body = line.rstrip("\r\n")
        match = None if body.lstrip().startswith("#") else _LIST_ENTRY.match(body)
        if match:
            target = rewrite(match.group(2), match.group(4) or "")
            rest = match.group(3) or ""
            line = f"{match.group(1)}{target}{rest}{line[len(body) :]}"
        out.append(line)
    return "".join(out)


def rewrite_text(text: str, deb822: bool, rewrite: Rewrite) -> str:
    """Return a sources file with each enabled entry's URIs passed through ``rewrite``.

    Args:
        text: File contents.
        deb822: True for a ``.sources`` file, False for a one-line ``.list``.
        rewrite: Maps a URI and one of the entry's suites to the URI to use.

    Returns:
        The new contents; equal to ``text`` when no URI changed. Only
        ``URIs`` (and ``Suites``, when a paragraph is split by host) change:
        comments, disabled entries and every other field stay.
    """
    if deb822:
        return _rewrite_deb822(text, rewrite)
    return _rewrite_list(text, rewrite)


def filter_sources(
    source_parts: Path,
    dest: Path,
    keep_third_party: bool,
    rewrite_for: Callable[[str], Rewrite | None] | None = None,
) -> list[str]:
    """Copy the sources files apt should read into ``dest``.

    Args:
        source_parts: The real ``sources.list.d`` directory.
        dest: Empty directory that becomes ``Dir::Etc::SourceParts``.
        keep_third_party: Copy third-party files too.
        rewrite_for: Returns the ``Rewrite`` for a file name, or None to copy
            that file as it is. A copy whose URIs all stay is byte for byte
            the original.

    Returns:
        Names of the files left out, sorted.
    """
    skipped: list[str] = []
    if not source_parts.is_dir():
        return skipped
    for path in sorted(source_parts.iterdir()):
        if path.suffix not in (".list", ".sources") or not path.is_file():
            continue
        if not keep_third_party and is_third_party(path):
            skipped.append(path.name)
            continue
        rewrite = rewrite_for(path.name) if rewrite_for else None
        if rewrite is not None:
            # surrogateescape round-trips any byte that is not UTF-8.
            text = path.read_bytes().decode("utf-8", errors="surrogateescape")
            new = rewrite_text(text, deb822=path.suffix == ".sources", rewrite=rewrite)
            if new != text:
                data = new.encode("utf-8", errors="surrogateescape")
                (dest / path.name).write_bytes(data)
                continue
        shutil.copyfile(path, dest / path.name)
    return skipped
