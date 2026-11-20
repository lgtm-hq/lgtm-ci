#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""URL rules of the shared comment sanitiser (#1676, #1677).

``comment_sanitize`` re-exports :func:`url`, :func:`host`,
:func:`display_host` and :func:`github_host`; every link mode and report mode
use these rules. The contract is in ``docs/comment-sanitize.md``.

A URL is safe to link when it is ``https``, at most 2,048 characters of URL
characters, with an ASCII host name (letters, digits, dots and hyphens in
valid labels, no ``xn--`` label, no userinfo) and an optional port. A host
that a browser reads as an IPv4 address in any form other than a canonical
dotted quad (``0x08080808``, ``010.010.010.010``, ``134744072``, ``1.2.3``)
is refused: the visible host would not be the address the browser opens.

Standard library only and Python 3.10 compatible.
"""

from __future__ import annotations

import re
from urllib.parse import urlsplit

#: Cap for a linkable URL.
MAX_URL_CHARS = 2048
#: Hosts where a link to an issue, pull request, discussion or commit
#: creates a cross-reference; never linked from untrusted text.
GITHUB_HOSTS = re.compile(
    r"(?:.+\.)?(?:github\.com|githubusercontent\.com|githubassets\.com"
    r"|github\.io|github\.dev|gh\.io|git\.io)",
)

#: GitHub links ".../issues/1" or ".../commit/<sha>" as a reference even when
#: the URL's scheme is broken; the break goes before the number.
_REF_PATH = re.compile(
    r"(?i)(/(?:issues|pulls?|discussions)/)(?=[0-9])|(/commits?/)(?=[0-9a-f]{7})",
)
_URL_CHARS = re.compile(r"[A-Za-z0-9\-._~:/?#@!$&'*+,;=%()]+")
_NETLOC = re.compile(r"[A-Za-z0-9.-]+(?::[0-9]{1,5})?")
_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")
#: A label a browser's host parser reads as a number (WHATWG "ends in a number").
_NUMERIC = re.compile(r"[0-9]+|0x[0-9a-f]*")
_OCTET = re.compile(r"0|[1-9][0-9]{0,2}")


def _numeric_host_ok(labels: list[str]) -> bool:
    """Tell whether a host is not an IPv4 address, or is a canonical dotted quad.

    A browser reads the host as IPv4 whenever its last label is a number
    (decimal, or ``0x`` hex). Only four decimal octets, 0 to 255, without
    leading zeros, are kept: every other form names one address while
    showing another.
    """
    if not _NUMERIC.fullmatch(labels[-1]):
        return True
    return len(labels) == 4 and all(
        _OCTET.fullmatch(label) and int(label) <= 255 for label in labels
    )


def _plain_host(netloc: str) -> bool:
    """Tell whether ``netloc`` is an ASCII host name with an optional port.

    Args:
        netloc: The authority of an URL already limited to URL characters.

    Returns:
        ``True`` for letters, digits, dots and hyphens in valid labels, no
        ``xn--`` (punycode) label, no userinfo, no non-canonical numeric
        host, and a port from 1 to 65535.
    """
    if not _NETLOC.fullmatch(netloc):
        return False
    name, _, port = netloc.lower().partition(":")
    labels = name.split(".")
    valid = all(_LABEL.fullmatch(label) and label[:4] != "xn--" for label in labels)
    return (
        valid
        and len(name) <= 253
        and _numeric_host_ok(labels)
        and (not port or 0 < int(port) < 65536)
    )


def url(value: str) -> str | None:
    """Return ``value`` when it is safe to link, else ``None``.

    Args:
        value: An untrusted URL; surrounding ASCII whitespace is ignored.

    Returns:
        The URL with ``(`` and ``)`` percent-encoded, or ``None``.
    """
    candidate = value.strip(" \t\r\n")
    safe = (
        0 < len(candidate) <= MAX_URL_CHARS
        and _URL_CHARS.fullmatch(candidate) is not None
        and candidate.lower().startswith("https://")
        and _plain_host(urlsplit(candidate).netloc)
    )
    return candidate.replace("(", "%28").replace(")", "%29") if safe else None


def host(value: str) -> str | None:
    """Return the lower-case host of a safe URL, else ``None``."""
    safe = url(value)
    return urlsplit(safe).hostname if safe else None


def display_host(value: str) -> str | None:
    """Return the host of a safe URL with any port other than 443, else ``None``.

    The visible text of a link, so it never hides a non-default port.
    """
    safe = url(value)
    if safe is None:
        return None
    parts = urlsplit(safe)
    name = parts.hostname or ""
    return name if parts.port in (None, 443) else f"{name}:{parts.port}"


def github_host(value: str) -> bool:
    """Tell whether ``value`` is a safe URL on a GitHub host (see ``GITHUB_HOSTS``)."""
    return GITHUB_HOSTS.fullmatch(host(value) or "") is not None


def break_references(escaped: str, mark: str = "&#8203;") -> str:
    """Put ``mark`` before the number of an ``/issues/N``-style path.

    GitHub links ``owner/repo/issues/N``, ``/pull/N``, ``/discussions/N`` and
    ``/commit/<sha>`` as a cross-reference even when the URL's scheme is
    broken, so ``text`` and ``html`` break the path itself.
    """
    return _REF_PATH.sub(lambda m: (m.group(1) or m.group(2)) + mark, escaped)
