#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""``report`` mode of the comment sanitiser: markdown a tool wrote from untrusted data.

The mode does not parse markdown. Its protections hold however GitHub reads
the structure (code, HTML blocks, lists, tables, quotes), because they apply to
the whole text and never delete or reorder anything:

1. Control and invisible characters are removed first, zero-width spaces
   included, so a second pass starts from the same text.
2. A literal zero-width space (U+200B) is inserted after every ``@``; before
   and after every ``$`` (GitHub renders ``$...$`` as math when only the
   space after it is there); after ``#`` before a digit; between ``GH`` and
   ``-`` before a digit;
   after ``<`` before a letter, ``/``, ``!`` or ``?``; between ``!`` and
   ``[``; after ``]`` before ``(``, ``[`` or ``:``; before ``://``; after
   ``www`` before ``.``; after ``&`` that starts an entity other than
   ``&amp;``, ``&lt;``, ``&gt;``, ``&quot;`` and ``&#8203;``; and before the
   number or hash in ``/issues/N``, ``/pull/N``, ``/pulls/N``,
   ``/discussions/N`` and ``/commit/SHA``, which GitHub links as references
   even when the URL's scheme is broken.
3. Three kinds of construct keep some of those points, and only their own:
   the layout tags in ``ALLOWED_TAGS`` keep their ``<``; an inline link
   ``[label](https://...)`` keeps its ``](`` and the ``://`` of its
   destination; a bare HTTPS URL, or the same URL as ``<https://...>``
   (lychee's form), keeps its ``://`` (and the autolink its ``<``). A URL
   qualifies only when it passes the ``url`` rules, is not on a GitHub host
   (a link there to an issue or commit would create a cross-reference), has
   no ``@ $ & ( ) | ` \\`` and holds no other break point at all, so an
   exemption never switches off any other protection. A bare URL runs, as
   GitHub's autolink does, up to the next space, tab, newline or ``<``; the
   URL of a link or autolink is judged on that same run, because a backslash
   before ``[`` or ``<`` makes GitHub read it as a bare URL: after its
   closing ``)`` or ``>`` only trailing punctuation may follow. A link label
   still gets every insertion.

Removing every inserted U+200B gives back the cleaned input, and step 1
removes them again, so ``report(report(x)) == report(x)`` for every ``x``.
Standard library only, Python 3.10 compatible.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import comment_sanitize as _core
except ImportError:  # python3 -I leaves this lib/ directory off sys.path
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import comment_sanitize as _core  # pylint: disable=ungrouped-imports

ZWSP = "\u200b"
#: Exact layout tags lgtm-ci's own report bodies use (validate, link check).
ALLOWED_TAGS = (
    "<details>",
    "</details>",
    "<summary>",
    "</summary>",
    "<sub>",
    "</sub>",
)
_SAFE_ENTITIES = ("&amp;", "&lt;", "&gt;", "&quot;", "&#8203;")
_GITHUB_HOSTS = re.compile(
    r"(?:.+\.)?(?:github\.com|githubusercontent\.com|githubassets\.com"
    r"|github\.io|github\.dev|gh\.io|git\.io)"
)
_LINK = re.compile(r"\[[^\[\]`!\n]*(\]\()(https://[^\s&\\<>()|`]+)\)", re.IGNORECASE)
_BARE = re.compile(r"https://[^ \t\n<]+", re.IGNORECASE)
_AUTOLINK = re.compile(r"<(https://[^\s<>]+)>", re.IGNORECASE)
_TRAILING = ".,:;!?'\"*_~"
#: Where GitHub's bare-URL autolink stops.
_BOUNDARY = re.compile(r"[ \t\n<]")
_SCHEME = "://"
#: (pattern, offset): insert U+200B at match start + offset (-1: match end).
_BREAKS = (
    (re.compile(r"@"), 1),
    (re.compile(r"\$"), 0),  # before and after: GitHub math needs both
    (re.compile(r"\$"), 1),
    (re.compile(r"#(?=[0-9])"), 1),
    (re.compile(r"(?i)gh(?=-[0-9])"), 2),
    (re.compile(r"<(?=[A-Za-z/!?])"), 1),
    (re.compile(r"!(?=\[)"), 1),
    (re.compile(r"\](?=[(\[:])"), 1),
    (re.compile(_SCHEME), 0),
    (re.compile(r"(?i)www(?=\.)"), 3),
    (re.compile(r"&(?=#|[A-Za-z0-9]+;)"), 1),
    # GitHub links ".../issues/1" or ".../commit/<sha>" even with the scheme
    # broken.
    (re.compile(r"(?i)/(?:issues|pulls?|discussions)/(?=[0-9])"), -1),
    (re.compile(r"(?i)/commits?/(?=[0-9a-f]{7})"), -1),
)


def _plain_url(value: str, start: int, points: set[int]) -> bool:
    """Tell whether the URL at ``start`` may stay linked; see the docstring.

    Args:
        value: The URL.
        start: Its position in the text.
        points: Every break point of the text.

    Returns:
        ``True`` when it passes the rules and its only break point is the
        ``://`` after its scheme.
    """
    if _core.url(value) != value or re.search(r"[@$&()|`\\]", value):
        return False
    if _GITHUB_HOSTS.fullmatch(_core.host(value) or ""):
        return False
    scheme = start + len("https")
    return not {p for p in points if start < p < start + len(value)} - {scheme}


def _closed(text: str, end: int, closer: str) -> bool:
    """Tell whether the URL ending at ``end`` also ends there as a bare URL.

    With a backslash before its ``[`` or ``<`` GitHub reads a link or autolink
    as plain text and links the URL on to the next space or ``<``, so
    ``\\[a](https://ok.example)@evil.example`` would point at another host.

    Args:
        text: The whole text.
        end: The position just after the URL.
        closer: The ``)`` or ``>`` that closes the construct.

    Returns:
        ``True`` when the closer follows and only trailing punctuation, which
        GitHub trims off a bare URL, stands between it and that boundary.
    """
    stop = _BOUNDARY.search(text, end)
    rest = text[end : stop.start() if stop else len(text)]
    return rest.startswith(closer) and not rest[1:].strip(_TRAILING + ")")


def _bare_end(text: str, start: int, end: int) -> int:
    """Trim trailing punctuation and unbalanced ``)`` off a bare URL."""
    while end > start:
        last = text[end - 1]
        opened = text.count("(", start, end)
        unbalanced = last == ")" and text.count(")", start, end) > opened
        if last not in _TRAILING and not unbalanced:
            break
        end -= 1
    return end


def _exempt(text: str, points: set[int]) -> set[int]:
    """Return the break points step 3 keeps from being inserted."""
    kept: set[int] = set()
    links: list[tuple[int, int]] = []
    for found in _LINK.finditer(text):
        inner = points - {found.start(1) + 1}
        plain = _plain_url(found.group(2), found.start(2), inner)
        if plain and _closed(text, found.end(2), ")"):
            kept.update({found.start(1) + 1, found.start(2) + len("https")})
            links.append((found.start(), found.end()))
    for found in _AUTOLINK.finditer(text):
        inner = points - {found.start() + 1}
        plain = _plain_url(found.group(1), found.start(1), inner)
        if plain and _closed(text, found.end(1), ">"):
            kept.update({found.start() + 1, found.start(1) + len("https")})
    for found in _BARE.finditer(text):
        end = _bare_end(text, found.start(), found.end())
        in_link = any(start <= found.start() < stop for start, stop in links)
        if not in_link and _plain_url(text[found.start() : end], found.start(), points):
            kept.add(found.start() + len("https"))
    for allowed in ALLOWED_TAGS + _SAFE_ENTITIES:
        for found in re.finditer(re.escape(allowed), text):
            kept.update(range(found.start() + 1, found.end()))
    return kept


def _break_points(text: str) -> set[int]:
    """Return the positions where step 2 inserts a zero-width space."""
    points = {
        found.end() if offset < 0 else found.start() + offset
        for pattern, offset in _BREAKS
        for found in pattern.finditer(text)
    }
    return points - _exempt(text, points)


def report(value: str, *, max_chars: int | None = None) -> str:
    """Neutralise markdown that a tool wrote from untrusted data.

    Args:
        value: The markdown.
        max_chars: Optional cap on the length, applied before any insertion.

    Returns:
        The text with invisible characters removed and a zero-width space
        inserted at every point listed in the module docstring.
    """
    cleaned = _core.strip_invisible(value, keep_tabs=True)
    if max_chars is not None:
        cleaned = _core.cap(cleaned, max_chars)
    points = _break_points(cleaned)
    out = []
    for index, char in enumerate(cleaned):
        out.append(ZWSP + char if index in points else char)
    if len(cleaned) in points:  # a ``$`` or ``@`` at the very end
        out.append(ZWSP)
    return "".join(out)
