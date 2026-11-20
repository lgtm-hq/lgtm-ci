#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Make untrusted text safe to insert into a pull request comment (#1676).

Modes (the full contract is in ``docs/comment-sanitize.md``):

- ``text`` / ``cell``: inert inline text on one line. Control, ANSI and
  ``Cf`` characters removed, line breaks flattened, length capped, HTML and
  markdown punctuation escaped, mentions, references and URLs broken.
- ``code`` / ``cell-code``: one inline code span, backticks included.
- ``fence``: a fenced code block longer than any backtick run inside.
- ``markdown``: trusted-producer markdown; hidden content removed only.
- ``report``: markdown a tool wrote from untrusted data (``comment_report.py``):
  structure kept, mentions, references, raw HTML, images and unsafe links
  removed.
- ``url`` / ``host`` / ``link``: HTTPS links with a plain ASCII host;
  ``link`` shows the host as the visible text.

Every mode neutralises the reserved marker ``<!-- lgtm-ci:`` and treats its
input as raw text, never as already escaped.

Command line (the value never travels on argv)::

    python3 -I -S comment_sanitize.py MODE [--env NAME] [--nul | --json] [--max N]

Standard library only and Python 3.10 compatible: composite actions run it
on the caller's runner (3.10 on ``ubuntu-22.04``).
"""

from __future__ import annotations

import importlib
import json
import os
import re
import sys
import unicodedata
from collections.abc import Callable
from functools import partial
from pathlib import Path
from urllib.parse import urlsplit

#: Default cap, in characters, for one inline value.
MAX_TEXT_CHARS = 2000
#: Cap for a linkable URL.
MAX_URL_CHARS = 2048
#: Prefix of every marker the posting code matches.
RESERVED_MARKER = "<!-- lgtm-ci:"

_ZWSP = "\u200b"
_ZWSP_ENTITY = "&#8203;"
_ELLIPSIS = "\u2026"
_ANSI = re.compile(
    r"\x1b\[[0-?]*[ -/]*[@-~]"  # CSI: colours, cursor movement
    r"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"  # OSC: titles, terminal hyperlinks
    r"|\x1b[@-_]",  # any other two-byte escape
)
_HIDDEN = frozenset({"Cc", "Cf", "Cs"})
_BREAKS = re.compile(r"\r\n|[\r\n\v\f\x1c-\x1e\x85\u2028\u2029]")
_INVISIBLE_LETTERS = frozenset("\u115f\u1160\u3164\uffa0")
_MARKER = re.compile(r"<!--(?=\s*lgtm-ci)", re.IGNORECASE)
_ENTITY_AHEAD = re.compile(r"#|[A-Za-z0-9]+;")
_FIXED_ESCAPES = {"<": "&lt;", ">": "&gt;", **{c: "\\" + c for c in "\\`*[]|~$"}}
_SCHEME = re.compile(r"([A-Za-z][A-Za-z0-9+.-]*):(?=//)")
_WWW = re.compile(r"(?i)(?<![A-Za-z0-9])(www)(?=\.)")
_GH_REF = re.compile(r"(?i)(?<![A-Za-z0-9])(gh)(?=-[0-9])")
_URL_CHARS = re.compile(r"[A-Za-z0-9\-._~:/?#@!$&'*+,;=%()]+")
_NETLOC = re.compile(r"[A-Za-z0-9.-]+(?::[0-9]{1,5})?")
_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")


def strip_invisible(value: str, *, keep_tabs: bool) -> str:
    """Remove ANSI escapes, control and invisible characters; keep ``\\n``.

    Args:
        value: Raw text.
        keep_tabs: Keep tabs (code); otherwise a tab becomes a space.

    Returns:
        The text with every line break normalised to ``\\n``.
    """
    value = _BREAKS.sub("\n", _ANSI.sub("", value))
    kept = []
    for char in value:
        if char == "\n" or (char == "\t" and keep_tabs):
            kept.append(char)
        elif char == "\t":
            kept.append(" ")
        elif unicodedata.category(char) in _HIDDEN or char in _INVISIBLE_LETTERS:
            continue
        else:
            kept.append(char)
    return "".join(kept)


def cap(value: str, limit: int) -> str:
    """Cut ``value`` to ``limit`` characters, ending with an ellipsis."""
    if limit < 1:
        return ""
    return value if len(value) <= limit else value[: limit - 1] + _ELLIPSIS


def neutralise_marker(value: str) -> str:
    """Insert a zero-width space after ``<!--`` where ``lgtm-ci`` follows."""
    return _MARKER.sub("<!--" + _ZWSP, value)


def _escape_char(value: str, index: int) -> str:
    """Return the escaped form of ``value[index]`` for inline markdown."""
    char = value[index]
    if char in _FIXED_ESCAPES:
        return _FIXED_ESCAPES[char]
    before = value[index - 1] if index else ""
    after = value[index + 1] if index + 1 < len(value) else ""
    escaped = char
    if char == "&" and _ENTITY_AHEAD.match(value, index + 1):
        escaped = "&amp;"
    elif char == "_" and not (before.isalnum() and after.isalnum()):
        escaped = "\\_"
    elif char == "#":
        escaped = "\\#" + (_ZWSP_ENTITY if after.isdigit() else "")
    elif char == "@" and (after.isalnum() or after in "_.+-"):
        # Every character a mention or an email autolink's domain can start with.
        escaped = "@" + _ZWSP_ENTITY
    return escaped


def text(value: str, *, max_chars: int = MAX_TEXT_CHARS) -> str:
    """Render untrusted text as inert inline markdown on one line.

    Args:
        value: Untrusted text.
        max_chars: Cap applied before escaping.

    Returns:
        Text with no raw ``<``, no line break and no working mention, link
        or reference.
    """
    flat = cap(strip_invisible(value, keep_tabs=False).replace("\n", " "), max_chars)
    escaped = "".join(_escape_char(flat, index) for index in range(len(flat)))
    escaped = _SCHEME.sub(r"\1" + _ZWSP_ENTITY + ":", escaped)
    escaped = _WWW.sub(r"\1" + _ZWSP_ENTITY, escaped)
    return _GH_REF.sub(r"\1" + _ZWSP_ENTITY, escaped)


def cell(value: str, *, max_chars: int = MAX_TEXT_CHARS) -> str:
    """Render untrusted text for a markdown table cell (same as :func:`text`)."""
    return text(value, max_chars=max_chars)


def code(value: str, *, max_chars: int = MAX_TEXT_CHARS) -> str:
    """Render untrusted text as one inline code span, backticks included.

    Args:
        value: Untrusted text.
        max_chars: Cap applied to the content.

    Returns:
        A code span that no backtick inside can close early.
    """
    flat = cap(strip_invisible(value, keep_tabs=False).replace("\n", " "), max_chars)
    flat = neutralise_marker(flat)
    longest = max((len(run) for run in re.findall(r"`+", flat)), default=0)
    ticks = "`" * (longest + 1)
    edge = flat[:1] + flat[-1:]
    pad = " " if "`" in edge or (flat.startswith(" ") and flat.endswith(" ")) else ""
    return f"{ticks}{pad}{flat}{pad}{ticks}" if flat else "` `"


def cell_code(value: str, *, max_chars: int = MAX_TEXT_CHARS) -> str:
    """Render untrusted text as a code span inside a markdown table cell.

    A backslash right before a pipe gets a zero-width space after it, so it
    cannot pair with the pipe's escaping backslash and split the row.
    """
    span = code(value, max_chars=max_chars)

    def escape(match: re.Match[str]) -> str:
        """Escape one pipe, splitting it from a backslash right before it."""
        return (match.group(1) + _ZWSP if match.group(1) else "") + "\\|"

    return re.sub(r"(\\?)\|", escape, span)


def fence(value: str, *, max_chars: int | None = None, info: str = "") -> str:
    """Render untrusted text as a fenced code block, fences included.

    Args:
        value: Untrusted text, possibly several lines.
        max_chars: Optional cap on the content; a cut adds a
            ``\u2026 (truncated)`` line.
        info: Info string after the opening fence, written by the renderer.

    Returns:
        ``<fence><info>\\n<content>\\n<fence>`` with no trailing newline.
    """
    body = strip_invisible(value, keep_tabs=True).rstrip("\n")
    if max_chars is not None and len(body) > max_chars:
        body = body[:max_chars] + "\n" + _ELLIPSIS + " (truncated)"
    body = neutralise_marker(body)
    longest = max((len(run) for run in re.findall(r"`+", body)), default=0)
    ticks = "`" * max(3, longest + 1)
    return f"{ticks}{info}\n{body}\n{ticks}"


def markdown(value: str, *, max_chars: int | None = None) -> str:
    """Pass trusted-producer markdown through with only hidden content removed.

    Args:
        value: Markdown from a producer trusted to write markdown.
        max_chars: Optional cap on the length.

    Returns:
        The markdown without control, ANSI or ``Cf`` characters and with the
        reserved marker neutralised. Trailing newlines are kept.
    """
    cleaned = strip_invisible(value, keep_tabs=True)
    if max_chars is not None:
        cleaned = cap(cleaned, max_chars)
    return neutralise_marker(cleaned)


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


def _plain_host(netloc: str) -> bool:
    """Tell whether ``netloc`` is an ASCII host name with an optional port.

    Args:
        netloc: The authority of an URL already limited to URL characters.

    Returns:
        ``True`` for letters, digits, dots and hyphens in valid labels, no
        ``xn--`` (punycode) label, no userinfo, and a port from 1 to 65535.
    """
    if not _NETLOC.fullmatch(netloc):
        return False
    name, _, port = netloc.lower().partition(":")
    labels = name.split(".")
    valid = all(_LABEL.fullmatch(label) and label[:4] != "xn--" for label in labels)
    return valid and len(name) <= 253 and (not port or 0 < int(port) < 65536)


def host(value: str) -> str | None:
    """Return the lower-case host of a safe URL, else ``None``."""
    safe = url(value)
    return urlsplit(safe).hostname if safe else None


def link(value: str) -> str:
    """Render ``[host](url)`` for a safe URL, else the value as inert text."""
    safe = url(value)
    if safe is None:
        return text(value)
    return f"[{text(urlsplit(safe).hostname or '')}]({safe})"


def labelled_link(value: str, label: str) -> str:
    """Render ``[label](url)`` with a label the renderer wrote itself.

    Args:
        value: Untrusted URL.
        label: Renderer-authored label, inserted as is. Never pass caller
            text: use :func:`link`, whose visible text is the host.

    Returns:
        The link, or the URL as inert text when it is not safe to link.
    """
    safe = url(value)
    return text(value) if safe is None else f"[{label}]({safe})"


def report(value: str, *, max_chars: int | None = None) -> str:
    """Neutralise markdown a tool wrote from untrusted data (``comment_report.py``).

    Args:
        value: The markdown.
        max_chars: Optional cap on the length.

    Returns:
        The markdown with its structure kept and its active parts removed.
    """
    here = str(Path(__file__).resolve().parent)
    if here not in sys.path:  # python3 -I leaves this lib/ directory off sys.path
        sys.path.insert(0, here)
    sys.modules.setdefault("comment_sanitize", sys.modules[__name__])
    # Loaded by name: comment_report imports this module for its helpers.
    module = importlib.import_module("comment_report")
    result: str = module.report(value, max_chars=max_chars)
    return result


def _optional(func: Callable[[str], str | None]) -> Callable[[str], str]:
    """Adapt a validator that may return ``None`` to return ``""`` instead."""
    return lambda value: func(value) or ""


#: Mode name to function; the capped ones also take ``max_chars``.
MODES: dict[str, Callable[..., str]] = {
    "text": text,
    "cell": cell,
    "code": code,
    "cell-code": cell_code,
    "fence": fence,
    "markdown": markdown,
    "report": report,
    "url": _optional(url),
    "host": _optional(host),
    "link": link,
}
_CAPPED = {"text", "cell", "code", "cell-code", "fence", "markdown", "report"}
_USAGE = "usage: comment_sanitize.py MODE [--env NAME] [--nul | --json] [--max N]\n"


def _parse(argv: list[str]) -> dict[str, str] | None:
    """Parse the command line; ``None`` on a usage error."""
    if not argv or argv[0] not in MODES:
        return None
    options = {"mode": argv[0]}
    rest = argv[1:]
    while rest:
        flag = rest.pop(0)
        if flag in {"--nul", "--json"} and "batch" not in options:
            options["batch"] = flag
        elif flag in {"--env", "--max"} and rest and flag not in options:
            options[flag] = rest.pop(0)
        else:
            return None
    limit = options.get("--max")
    if limit is not None and (options["mode"] not in _CAPPED or not limit.isdigit()):
        return None
    if "--env" in options and "batch" in options:
        return None
    return options


def _encode(value: str) -> bytes:
    """Encode output as UTF-8; nothing unencodable survives the modes."""
    return value.encode("utf-8", errors="replace")


def main(argv: list[str]) -> int:
    """Run the command line; see the module docstring.

    Args:
        argv: Arguments after the program name.

    Returns:
        The exit status.
    """
    options = _parse(argv)
    if options is None:
        sys.stderr.write(_USAGE)
        return 2
    func = MODES[options["mode"]]
    if "--max" in options:
        func = partial(func, max_chars=int(options["--max"]))
    if "--env" in options:
        data = os.environ.get(options["--env"], "")
    else:
        data = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    out = sys.stdout.buffer
    if options.get("batch") == "--json":
        try:
            values = json.loads(data)
        except ValueError:
            values = None
        if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
            sys.stderr.write("comment_sanitize: --json needs a JSON array of strings\n")
            return 2
        out.write(_encode(json.dumps([func(v) for v in values], ensure_ascii=False)))
    elif options.get("batch") == "--nul":
        records = data.split("\0")
        if records and records[-1] == "":
            records.pop()
        out.write(b"".join(_encode(func(r)) + b"\0" for r in records))
    else:
        out.write(_encode(func(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
