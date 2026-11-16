# SPDX-License-Identifier: MIT
"""Read egress allow-list entries from documents (#1548).

Used by ``check-egress-dns.py``: the ``host:port`` values of
``*allowed-endpoints*`` keys in ``examples/`` and in the fenced code blocks of
``docs/``. Reading fails closed: a value that cannot be read reliably, or a
token that is not ``host:port``, is an error, never a silently dropped host.
"""

from __future__ import annotations

import re
from collections.abc import Iterator
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

ENDPOINT = re.compile(r"^(?P<host>[a-z0-9.*-]+):(?P<port>\d{1,5})$")
_KEY = r"[\w-]*allowed-endpoints[\w-]*"
BLOCK_KEY = re.compile(
    rf"^(?P<lead>\s*(?:-\s+)?)[\"']?(?P<key>{_KEY})[\"']?\s*:(?P<rest>(?:\s.*)?)$",
)
FLOW_KEY = re.compile(rf"[{{,]\s*[\"']?{_KEY}[\"']?\s*:")
KEY_NAME = re.compile(_KEY)
EXPRESSION = re.compile(r"\$\{\{.*?\}\}", re.DOTALL)
SCALAR_MARK = re.compile(r"^[>|][+-]?$")
FENCE = re.compile(r"^ {0,3}(?P<marks>`{3,}|~{3,})(?P<info>.*)$")
TOKEN_SPLIT = re.compile(r"[\s,{}\[\]]+")


class DnsCheckError(Exception):
    """Raised when the check cannot reach a trustworthy verdict; it fails closed."""


def _indent(line: str) -> int:
    """Return the number of leading spaces of a line."""
    return len(line) - len(line.lstrip(" "))


def _fence_opening(line: str) -> str:
    """Return the fence marks a line opens a code block with, or ``""``."""
    match = FENCE.match(line)
    if match is None:
        return ""
    marks = match.group("marks")
    # A backtick fence's info string cannot hold a backtick (CommonMark).
    if marks[0] == "`" and "`" in match.group("info"):
        return ""
    return marks


def _closes_fence(line: str, fence: str) -> bool:
    """Tell whether a line closes the fence opened with ``fence`` marks."""
    match = FENCE.match(line)
    if match is None or match.group("info").strip():
        return False
    marks = match.group("marks")
    return marks[0] == fence[0] and len(marks) >= len(fence)


def _split_flow(body: str) -> list[str]:
    """Split a flow mapping's body at its top-level commas."""
    entries: list[str] = []
    depth, start = 0, 0
    for index, char in enumerate(body):
        if char in "{[":
            depth += 1
        elif char in "}]":
            depth -= 1
        elif char == "," and depth == 0:
            entries.append(body[start:index])
            start = index + 1
    entries.append(body[start:])
    return entries


def _flow_values(text: str, number: int) -> Iterator[str]:
    """Yield the allow-list values of a flow mapping on one line.

    Each ``key: value`` entry is judged by its own key, so a ``*-mode`` key
    does not hide its siblings and an unrelated key's value is never read.

    Args:
        text: The line from its first ``{`` on.
        number: The 1-based line number, for errors.

    Yields:
        The value of each allow-list key, nested mappings included.

    Raises:
        DnsCheckError: When the mapping does not close on its line.
    """
    depth = 0
    for index, char in enumerate(text):
        depth += (char in "{[") - (char in "}]")
        if depth == 0:
            body = text[1:index]
            break
    else:
        raise DnsCheckError(
            f"line {number}: an allow-list in a flow mapping that spans lines "
            "is not supported; write it as a block mapping",
        )
    for entry in _split_flow(body):
        key, _, value = entry.partition(":")
        key = key.strip().strip("'\"")
        if value.strip().startswith("{"):
            yield from _flow_values(value.strip(), number)
        elif KEY_NAME.fullmatch(key) and not key.endswith("-mode"):
            yield value


def _endpoint_tokens(values: list[tuple[int, str]]) -> Iterator[tuple[int, str]]:
    """Yield the ``host:port`` tokens of an allow-list value.

    Expressions (``${{ ... }}``), comments, block scalar marks (``>-``) and
    list punctuation are not entries. Anything else must look like
    ``host:port``: a typo such as ``my_host.example:443`` is an error, not a
    silently dropped host.

    Args:
        values: ``(line number, text)`` pairs of the value's lines.

    Yields:
        ``(line number, token)`` pairs.

    Raises:
        DnsCheckError: On a token that is not a ``host:port`` entry.
    """
    joined = "\n".join(text for _, text in values)
    joined = EXPRESSION.sub(lambda found: "\n" * found.group().count("\n"), joined)
    for (number, _), text in zip(values, joined.split("\n"), strict=True):
        text = text.split(" #", 1)[0]
        if text.lstrip().startswith("#"):
            continue
        for token in TOKEN_SPLIT.split(text):
            token = token.strip("'\"")
            if not token or SCALAR_MARK.match(token):
                continue
            if not ENDPOINT.match(token.lower()):
                raise DnsCheckError(
                    f"line {number}: {token!r} in an allow-list is not host:port",
                )
            yield number, token


def allow_list_entries(lines: list[str], markdown: bool) -> Iterator[tuple[int, str]]:
    """Yield the ``host:port`` tokens of allow-list values in a document.

    An allow-list value is the value of a YAML key containing
    ``allowed-endpoints`` (``allowed-endpoints``, ``allowed-endpoints-build``,
    ``publish-allowed-endpoints``, ...; ``*-mode`` keys excluded). As a block
    key it is the rest of its line plus every following line indented deeper
    than the key's line, so folded, literal and plain multi-line scalars are
    all covered; the key may be quoted. Inside a flow mapping
    (``with: {key: value}``) it is that entry's value only. In Markdown only
    fenced code blocks are read, never prose; a fence closes only on a line
    of the same character at least as long as its opening.

    Args:
        lines: The document's lines.
        markdown: True to read only fenced code blocks.

    Yields:
        ``(line number, token)`` pairs, 1-based.

    Raises:
        DnsCheckError: On an allow-list value that cannot be read reliably.
    """
    fence = "" if markdown else "always"
    index = 0
    while index < len(lines):
        line = lines[index]
        index += 1
        if markdown:
            if not fence:
                fence = _fence_opening(line)
                continue
            if _closes_fence(line, fence):
                fence = ""
                continue
        match = BLOCK_KEY.match(line)
        if match is None:
            flow = FLOW_KEY.search(line)
            if flow is not None and not line.lstrip().startswith("#"):
                for value in _flow_values(line[line.index("{") :], index):
                    yield from _endpoint_tokens([(index, value)])
            continue
        if match.group("key").endswith("-mode"):
            continue
        key_indent = len(match.group("lead"))
        values = [(index, match.group("rest"))]
        while index < len(lines):
            follow = lines[index]
            if markdown and _closes_fence(follow, fence):
                break
            if follow.strip() and _indent(follow) <= key_indent:
                break
            index += 1
            values.append((index, follow))
        yield from _endpoint_tokens(values)


def document_endpoints(root: Path = ROOT) -> list[tuple[str, str]]:
    """Read the allow-list entries in ``docs/`` and ``examples/``.

    Args:
        root: Repository root.

    Returns:
        ``(path:line, endpoint)`` pairs, sorted by path.

    Raises:
        DnsCheckError: When a document cannot be read.
    """
    paths = sorted(
        path
        for folder in ("docs", "examples")
        for path in (root / folder).rglob("*")
        if path.suffix in {".md", ".yml", ".yaml"} and path.is_file()
    )
    pairs: list[tuple[str, str]] = []
    for path in paths:
        try:
            lines = path.read_text("utf-8").splitlines()
        except (OSError, UnicodeDecodeError) as error:
            raise DnsCheckError(f"could not read {path}: {error}") from error
        relative = path.relative_to(root).as_posix()
        try:
            for number, token in allow_list_entries(lines, path.suffix == ".md"):
                pairs.append((f"{relative}:{number}", token))
        except DnsCheckError as error:
            raise DnsCheckError(f"{relative}: {error}") from error
    return pairs
