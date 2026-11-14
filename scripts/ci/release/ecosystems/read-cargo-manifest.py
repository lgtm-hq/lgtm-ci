#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read and set version data in Cargo manifests without running cargo.

Usage:
    python3 -I read-cargo-manifest.py version-source <Cargo.toml>
    python3 -I read-cargo-manifest.py literal-tables <Cargo.toml>
    python3 -I read-cargo-manifest.py workspace-version <Cargo.toml>
    python3 -I read-cargo-manifest.py inheriting <cargo-metadata.json>
    python3 -I read-cargo-manifest.py set-version <Cargo.toml> <version> <table>...

``version-source`` prints ``workspace`` when ``[package] version`` is
inherited (``version.workspace = true``, ``version = { workspace = true }``
or any other spelling of that key) and ``literal`` otherwise (a literal
version, or no ``[package]`` at all, as in a virtual workspace root).

``literal-tables`` prints, one per line, which of ``package`` and
``workspace.package`` set ``version`` to a string.

``workspace-version`` prints the ``[workspace.package] version`` string.

``inheriting`` reads the JSON ``cargo metadata --no-deps`` printed and, for
each package whose manifest inherits its version, prints ``<name> <version>``
with the version cargo resolved.

``set-version`` prints the manifest with the string ``version`` of each named
table (``package`` or ``workspace.package``) set to ``<version>``, and every
other byte (spacing, comments, line endings, the rest of the line) kept.
The manifest is scanned as TOML, strings included, so a ``version = "..."``
inside a multiline string is never taken for the key. The result is then
parsed again and must differ from the original in those values only.

Only data is read (stdlib ``tomllib`` and ``json``); ``rust.sh`` runs this
with ``-I`` from an empty directory so nothing from the checkout is imported.
``tomllib`` needs Python 3.11; TOML 1.1 syntax (an inline table over several
lines, or with a trailing comma) only parses on Python 3.15 or later, and is
reported as unparseable before that.

Exit status:
    0  printed the answer
    1  usage error, or a file cannot be read
    4  a manifest cannot be understood (bad TOML, or a ``version`` that is
       neither a string nor ``{ workspace = true }``), or the metadata is
       not what cargo prints
    5  no string ``version`` to read or set: ``workspace-version`` without a
       ``[workspace.package] version``, ``literal-tables`` with neither table
       setting one, ``set-version`` naming a table without one
    6  Python is older than 3.11 (no ``tomllib``)
    7  ``set-version`` cannot make the edit as a change of that value only
"""

# pylint: disable=invalid-name  # CLI script; hyphenated filename is the invocation contract

from __future__ import annotations

import copy
import json
import math
import sys
from pathlib import Path
from typing import Any

try:
    import tomllib
except ImportError:  # pragma: no cover - Python < 3.11
    print(
        "ERROR: python3 is older than 3.11 (no tomllib); the rust release step"
        " needs Python >= 3.11",
        file=sys.stderr,
    )
    raise SystemExit(6) from None

EXIT_UNREADABLE = 4
EXIT_NO_VERSION = 5
EXIT_CANNOT_SET = 7
INHERIT_FORM = "{ workspace = true }"
TABLES = {"package": ("package",), "workspace.package": ("workspace", "package")}
TOML11_HINT = (
    "TOML 1.1 syntax (an inline table over several lines, such as"
    " `version = {\\n  workspace = true,\\n}`, or one with a trailing comma)"
    " needs Python >= 3.15 to parse; write it on one line"
)


def parse_error(path: Path, exc: Exception) -> SystemExit:
    """Report a manifest tomllib cannot parse.

    Args:
        path: The manifest.
        exc: The parse error.

    Returns:
        The ``SystemExit`` to raise, with ``EXIT_UNREADABLE``.
    """
    print(f"ERROR: cannot parse {path}: {exc}", file=sys.stderr)
    if sys.version_info < (3, 15):
        version = ".".join(str(part) for part in sys.version_info[:3])
        print(f"ERROR: {TOML11_HINT} (this is Python {version})", file=sys.stderr)
    return SystemExit(EXIT_UNREADABLE)


def read_text(path: Path) -> str:
    """Read a manifest as UTF-8 text, line endings kept.

    Args:
        path: The ``Cargo.toml`` to read.

    Returns:
        Its text.

    Raises:
        SystemExit: With ``EXIT_UNREADABLE`` when it is not UTF-8.
    """
    try:
        with path.open(encoding="utf-8", newline="") as handle:
            return handle.read()
    except UnicodeDecodeError as exc:
        raise parse_error(path, exc) from exc


def load_manifest(path: Path) -> dict[str, Any]:
    """Parse a Cargo manifest.

    Args:
        path: The ``Cargo.toml`` to read.

    Returns:
        The parsed manifest.

    Raises:
        SystemExit: With ``EXIT_UNREADABLE`` when it is not valid TOML.
    """
    try:
        return tomllib.loads(read_text(path))
    except tomllib.TOMLDecodeError as exc:
        raise parse_error(path, exc) from exc


def lookup(data: dict[str, Any], path: tuple[str, ...]) -> Any:
    """Return the value at a key path, or ``None`` when it is absent.

    Args:
        data: A parsed TOML document.
        path: The keys to follow.

    Returns:
        The value found, or ``None``.
    """
    value: Any = data
    for key in path:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def version_source(path: Path) -> str:
    """Return how the manifest's ``[package]`` sets its version.

    Args:
        path: The ``Cargo.toml`` to read.

    Returns:
        ``workspace`` when the version is inherited, else ``literal``.

    Raises:
        SystemExit: With ``EXIT_UNREADABLE`` when ``[package] version`` is
            neither a string nor ``{ workspace = true }``.
    """
    package = load_manifest(path).get("package")
    if not isinstance(package, dict) or "version" not in package:
        return "literal"
    version = package["version"]
    if isinstance(version, str):
        return "literal"
    if version == {"workspace": True}:
        return "workspace"
    print(
        f"ERROR: {path}: [package] version is neither a string nor {INHERIT_FORM}",
        file=sys.stderr,
    )
    raise SystemExit(EXIT_UNREADABLE)


def literal_tables(path: Path) -> list[str]:
    """List the tables of a manifest that set ``version`` to a string.

    Args:
        path: The ``Cargo.toml`` to read.

    Returns:
        ``package`` and/or ``workspace.package``.

    Raises:
        SystemExit: With ``EXIT_NO_VERSION`` when neither does.
    """
    manifest = load_manifest(path)
    tables = [
        name
        for name, keys in TABLES.items()
        if isinstance(lookup(manifest, (*keys, "version")), str)
    ]
    if not tables:
        where = "[package] or [workspace.package]"
        print(f"ERROR: {path} sets no string version in {where}", file=sys.stderr)
        raise SystemExit(EXIT_NO_VERSION)
    return tables


def workspace_version(path: Path) -> str:
    """Return the ``[workspace.package] version`` of a root manifest.

    Args:
        path: The workspace root ``Cargo.toml``.

    Returns:
        The version string.

    Raises:
        SystemExit: With ``EXIT_NO_VERSION`` when there is none.
    """
    version = lookup(load_manifest(path), ("workspace", "package", "version"))
    if not isinstance(version, str):
        print(f"ERROR: {path} has no [workspace.package] version", file=sys.stderr)
        raise SystemExit(EXIT_NO_VERSION)
    return version


def package_entry(package: dict[str, Any]) -> tuple[Any, Any, Path]:
    """Return a cargo metadata package's name, version and manifest path.

    Args:
        package: One entry of the metadata's ``packages``.

    Returns:
        The ``name``, ``version`` and ``manifest_path`` it records.
    """
    return package["name"], package["version"], Path(package["manifest_path"])


def inheriting(metadata_path: Path) -> list[str]:
    """List the packages in cargo metadata whose manifest inherits its version.

    Args:
        metadata_path: A file holding ``cargo metadata --no-deps`` JSON.

    Returns:
        One ``<name> <version>`` line per inheriting package.

    Raises:
        SystemExit: With ``EXIT_UNREADABLE`` when the metadata is malformed.
    """
    try:
        packages = json.loads(metadata_path.read_text(encoding="utf-8"))["packages"]
        entries = [package_entry(pkg) for pkg in packages]
    except (ValueError, KeyError, TypeError) as exc:
        print(f"ERROR: unexpected cargo metadata: {exc}", file=sys.stderr)
        raise SystemExit(EXIT_UNREADABLE) from exc
    lines = []
    for name, version, manifest in entries:
        if not all(isinstance(v, str) and v.isprintable() for v in (name, version)):
            print("ERROR: unexpected package name or version", file=sys.stderr)
            raise SystemExit(EXIT_UNREADABLE)
        if version_source(manifest) == "workspace":
            lines.append(f"{name} {version}")
    return lines


class ScanError(Exception):
    """The manifest text is not laid out as the scanner expects."""


def decode_key(text: str) -> tuple[str, ...]:
    """Decode a TOML key (bare, quoted or dotted) into its parts.

    Args:
        text: The key as written, such as ``"package" . version``.

    Returns:
        The key path, such as ``("package", "version")``.

    Raises:
        ScanError: When ``text`` is not a key.
    """
    try:
        value: Any = tomllib.loads(f"{text} = 0")
    except tomllib.TOMLDecodeError as exc:
        raise ScanError(f"not a key: {text!r}") from exc
    path = []
    while isinstance(value, dict):
        # `<key> = 0` parses to exactly one key per nesting level.
        key = next(iter(value))
        value = value[key]
        path.append(key)
    return tuple(path)


class Scanner:
    """Find the string values of one key path in TOML text.

    A small TOML reader that knows where every string, comment, table
    header and key/value pair starts and ends, and records the span of each
    string value whose full key path is ``target``. It does not interpret
    values: tomllib checks the edited text afterwards.

    Args:
        text: The manifest text.
        targets: Full key paths whose string values are wanted.
    """

    def __init__(self, text: str, targets: set[tuple[str, ...]]) -> None:
        self.text = text
        self.pos = 0
        self.targets = targets
        self.spans: list[tuple[tuple[str, ...], int, int]] = []

    def peek(self, count: int = 1) -> str:
        """Return the next ``count`` characters (fewer at the end)."""
        return self.text[self.pos : self.pos + count]

    def expect(self, char: str) -> None:
        """Consume ``char`` or fail."""
        if self.peek() != char:
            raise ScanError(f"expected {char!r} at offset {self.pos}")
        self.pos += 1

    def skip_blank(self, *, newlines: bool) -> None:
        """Skip spaces, tabs and comments, and newlines when asked."""
        while self.pos < len(self.text):
            char = self.text[self.pos]
            if char in " \t" or (newlines and char in "\r\n"):
                self.pos += 1
            elif char == "#":
                while self.pos < len(self.text) and self.text[self.pos] not in "\r\n":
                    self.pos += 1
            else:
                return

    def skip_string(self) -> None:
        """Consume a basic or literal string, single or multiline."""
        quote = self.peek()
        if self.peek(3) == quote * 3:
            self.pos += 3
            end = self.find_quote(quote, multiline=True)
            # Up to two quotes may end the content: """a""""" is a"".
            run = 3
            while run < 5 and self.text[end + run : end + run + 1] == quote:
                run += 1
            self.pos = end + run
            return
        self.pos += 1
        self.pos = self.find_quote(quote, multiline=False) + 1

    def find_quote(self, quote: str, *, multiline: bool) -> int:
        """Return the offset of the closing quote(s) of the current string."""
        closing = quote * 3 if multiline else quote
        pos = self.pos
        while pos < len(self.text):
            char = self.text[pos]
            if quote == '"' and char == "\\":
                pos += 2
                continue
            if not multiline and char in "\r\n":
                break
            if self.text.startswith(closing, pos):
                return pos
            pos += 1
        raise ScanError(f"unterminated string at offset {self.pos}")

    def read_key(self, stop: str) -> str:
        """Return the key text up to ``stop`` (outside quotes), consumed."""
        start = self.pos
        while self.pos < len(self.text):
            char = self.text[self.pos]
            if char in "\"'":
                self.skip_string()
            elif char == stop:
                return self.text[start : self.pos]
            elif char in "\r\n#":
                break
            else:
                self.pos += 1
        raise ScanError(f"expected {stop!r} after key at offset {start}")

    def header(self) -> tuple[str, ...] | None:
        """Consume a table header; return its path, or None for ``[[...]]``."""
        self.expect("[")
        array = self.peek() == "["
        if array:
            self.pos += 1
        path = decode_key(self.read_key("]"))
        self.expect("]")
        if array:
            self.expect("]")
        return None if array else path

    def keyval(self, prefix: tuple[str, ...] | None) -> None:
        """Consume ``key = value`` under ``prefix`` (None: not addressable)."""
        key = decode_key(self.read_key("="))
        self.expect("=")
        self.skip_blank(newlines=False)
        self.value(None if prefix is None else prefix + key)

    def value(self, path: tuple[str, ...] | None) -> None:
        """Consume a value, recording it when ``path`` is a target string."""
        char = self.peek()
        start = self.pos
        if char in "\"'":
            self.skip_string()
            if path in self.targets:
                self.spans.append((path, start, self.pos))
        elif char in "[{":
            self.pos += 1
            close = "]" if char == "[" else "}"
            while True:
                self.skip_blank(newlines=True)
                if self.peek() == close:
                    break
                if char == "[":
                    self.value(None)
                else:
                    self.keyval(path)
                self.skip_blank(newlines=True)
                if self.peek() != ",":
                    break
                self.pos += 1
            self.expect(close)
        else:
            while self.pos < len(self.text) and self.text[self.pos] not in ",]}#\r\n":
                self.pos += 1
            if self.pos == start:
                raise ScanError(f"missing value at offset {start}")

    def end_of_line(self) -> None:
        """Consume trailing blanks and a comment; require a newline or EOF."""
        self.skip_blank(newlines=False)
        if self.pos < len(self.text) and self.text[self.pos] not in "\r\n":
            raise ScanError(f"unexpected text at offset {self.pos}")

    def scan(self) -> list[tuple[tuple[str, ...], int, int]]:
        """Scan the whole text; return ``(path, start, end)`` per target string."""
        table: tuple[str, ...] | None = ()
        while True:
            self.skip_blank(newlines=True)
            if self.pos >= len(self.text):
                return self.spans
            if self.peek() == "[":
                table = self.header()
            else:
                self.keyval(table)
            self.end_of_line()


def same_value(left: Any, right: Any) -> bool:
    """Compare parsed TOML values, treating NaN as equal to NaN.

    TOML allows ``nan``; ``float('nan') != float('nan')``, so a plain ``==``
    would report a change wherever a manifest holds one.

    Args:
        left: A parsed TOML value.
        right: Another parsed TOML value.

    Returns:
        True when both values are the same.
    """
    if isinstance(left, float) and isinstance(right, float):
        return left == right or (math.isnan(left) and math.isnan(right))
    if isinstance(left, dict) and isinstance(right, dict):
        return left.keys() == right.keys() and all(
            same_value(left[key], right[key]) for key in left
        )
    if isinstance(left, list) and isinstance(right, list):
        return len(left) == len(right) and all(
            same_value(a, b) for a, b in zip(left, right, strict=True)
        )
    return type(left) is type(right) and left == right


def set_version(path: Path, version: str, tables: list[str]) -> str:
    """Return the manifest with ``version`` set in each of ``tables``.

    Args:
        path: The ``Cargo.toml`` to edit.
        version: The new version.
        tables: ``package`` and/or ``workspace.package``.

    Returns:
        The edited text.

    Raises:
        SystemExit: With ``EXIT_NO_VERSION`` when a table sets no string
            version, or ``EXIT_CANNOT_SET`` when the edit cannot be made as
            a change of those values only.
    """
    if not version.isprintable() or any(c in version for c in "\"'\\"):
        print(f"ERROR: unusable version {version!r}", file=sys.stderr)
        raise SystemExit(EXIT_CANNOT_SET)
    text = read_text(path)
    before = load_manifest(path)
    targets = {(*TABLES[name], "version") for name in tables}
    for target in targets:
        if not isinstance(lookup(before, target), str):
            print(
                f"ERROR: {path} has no string [{'.'.join(target[:-1])}] version",
                file=sys.stderr,
            )
            raise SystemExit(EXIT_NO_VERSION)
    try:
        spans = Scanner(text, targets).scan()
    except ScanError as exc:
        print(f"ERROR: cannot scan {path}: {exc}", file=sys.stderr)
        raise SystemExit(EXIT_CANNOT_SET) from exc
    if sorted(span[0] for span in spans) != sorted(targets):
        print(
            f"ERROR: {path}: did not find exactly one version value per table",
            file=sys.stderr,
        )
        raise SystemExit(EXIT_CANNOT_SET)
    edited = text
    for _, start, end in sorted(spans, key=lambda span: span[1], reverse=True):
        # Keep the delimiter as written: ', ", ''' or """.
        quote = text[start] * (3 if text.startswith(text[start] * 3, start) else 1)
        edited = f"{edited[:start]}{quote}{version}{quote}{edited[end:]}"
    expected = copy.deepcopy(before)
    for target in targets:
        lookup(expected, target[:-1])[target[-1]] = version
    try:
        after = tomllib.loads(edited)
    except tomllib.TOMLDecodeError:
        after = None
    if after is None or not same_value(after, expected):
        print(
            f"ERROR: {path}: the edit would change more than the version",
            file=sys.stderr,
        )
        raise SystemExit(EXIT_CANNOT_SET)
    return edited


def usage(commands: list[str]) -> None:
    """Print usage and exit 1."""
    print(
        f"Usage: {sys.argv[0]} {{{'|'.join(commands)}}} <file>\n"
        f"       {sys.argv[0]} set-version <Cargo.toml> <version> <table>...",
        file=sys.stderr,
    )
    sys.exit(1)


def main() -> None:
    """Run the subcommand named in ``sys.argv``."""
    commands = {
        "version-source": lambda p: [version_source(p)],
        "literal-tables": literal_tables,
        "workspace-version": lambda p: [workspace_version(p)],
        "inheriting": inheriting,
    }
    args = sys.argv[1:]
    try:
        if args[:1] == ["set-version"]:
            if len(args) < 4 or not set(args[3:]) <= TABLES.keys():
                usage(list(commands))
            text = set_version(Path(args[1]), args[2], args[3:])
            sys.stdout.buffer.write(text.encode("utf-8"))
            return
        if len(args) != 2 or args[0] not in commands:
            usage(list(commands))
        lines = commands[args[0]](Path(args[1]))
    except OSError as exc:
        print(f"ERROR: cannot read {exc.filename or args[1]}: {exc}", file=sys.stderr)
        sys.exit(1)
    for line in lines:
        print(line)


if __name__ == "__main__":
    main()
