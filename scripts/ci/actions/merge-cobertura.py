#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Merge kcov Cobertura XML reports from sharded BATS coverage runs.

kcov v43 does not merge bash coverage across separate invocations, so sharded
``reusable-test-shell.yml`` jobs each emit their own ``cov.xml`` /
``cobertura.xml``. This script unions those reports: every instrumented file
appears once, and each ``(file, line)`` keeps the maximum hit count seen in
any input. A file present in only one input is copied as-is.

The merged line-rate is recomputed as covered-lines / valid-lines (a line is
covered when hits > 0). The integer percent (rounded half-up) is printed to
stdout and written to ``GITHUB_OUTPUT`` as ``coverage-percent`` when that
file is set.

Parsing is regex-based on the Cobertura schema kcov emits (``class`` /
``line`` tags). That keeps this script stdlib-only and avoids
``xml.etree.ElementTree``, which bandit B314/B405 and semgrep XXE rules
flag even for trusted CI artifacts. Do not pass ``kcov --merge``; it yields
empty bash coverage.

Usage:
    python3 scripts/ci/actions/merge-cobertura.py \\
        --output merged.xml shard0/cov.xml shard1/cov.xml
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

_CLASS_BLOCK = re.compile(
    r"<((?:[\w.-]+:)?class)\b([^>]*)>(.*?)</\1\s*>",
    flags=re.DOTALL | re.IGNORECASE,
)
_LINE_TAG = re.compile(
    r"<(?:[\w.-]+:)?line\b([^>]*)/?>",
    flags=re.IGNORECASE,
)
_ATTR = re.compile(r'([\w:.-]+)\s*=\s*"([^"]*)"')


def _unescape_xml(value: str) -> str:
    """Decode the XML predefined entities in ``value``.

    Args:
        value: Attribute text that may contain ``&amp;`` / ``&lt;`` / etc.

    Returns:
        The unescaped string. ``&amp;`` is decoded last so ``&amp;lt;``
        stays ``&lt;``.
    """
    return (
        value.replace("&quot;", '"')
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
    )


def _escape_xml(value: str) -> str:
    """Escape XML special characters for an attribute or text node.

    Args:
        value: Raw string.

    Returns:
        XML-safe string. ``&`` is escaped first.
    """
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def _attrs(raw: str) -> dict[str, str]:
    """Parse ``name="value"`` pairs from a tag's attribute blob.

    Args:
        raw: Text between the tag name and ``>``.

    Returns:
        Local attribute name (prefix stripped) to unescaped value.
    """
    found: dict[str, str] = {}
    for match in _ATTR.finditer(raw):
        name = match.group(1)
        if ":" in name:
            name = name.rsplit(":", 1)[1]
        found[name] = _unescape_xml(match.group(2))
    return found


def _iter_class_hits(text: str) -> list[tuple[str, list[tuple[int, int]]]]:
    """Return ``(filename, [(line, hits), ...])`` from a Cobertura document.

    Args:
        text: Raw Cobertura XML.

    Returns:
        Class entries that carry a ``filename`` attribute. Malformed
        ``number``/``hits`` values are skipped.
    """
    classes: list[tuple[str, list[tuple[int, int]]]] = []
    for class_match in _CLASS_BLOCK.finditer(text):
        filename = _attrs(class_match.group(2)).get("filename")
        if filename is None or filename == "":
            continue
        hits: list[tuple[int, int]] = []
        for line_match in _LINE_TAG.finditer(class_match.group(3)):
            line_attrs = _attrs(line_match.group(1))
            raw_number = line_attrs.get("number")
            if raw_number is None:
                continue
            try:
                number = int(raw_number)
                count = int(line_attrs.get("hits", "0"))
            except ValueError:
                continue
            if number < 0 or count < 0:
                continue
            hits.append((number, count))
        classes.append((filename, hits))
    return classes


def merge_line_hits(input_paths: list[Path]) -> dict[str, dict[int, int]]:
    """Union per-file line hits across Cobertura documents.

    Per ``(filename, line)`` the maximum hit count wins. A file that appears
    in only one input is included with that input's lines unchanged.

    Args:
        input_paths: Cobertura XML files (kcov ``cov.xml`` or
            ``cobertura.xml``).

    Returns:
        Mapping of filename to line-number → max hits.

    Raises:
        ValueError: When a path cannot be read as text.
    """
    merged: dict[str, dict[int, int]] = {}
    for path in input_paths:
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            raise ValueError(f"cannot parse Cobertura XML {path}: {exc}") from exc
        for filename, hits in _iter_class_hits(text):
            file_hits = merged.setdefault(filename, {})
            for number, count in hits:
                file_hits[number] = max(file_hits.get(number, 0), count)
    return merged


def coverage_percent(merged: dict[str, dict[int, int]]) -> int:
    """Return the merged line-rate as a rounded integer percent.

    Args:
        merged: Filename → line-number → hits mapping.

    Returns:
        Integer percent in ``[0, 100]``. Zero valid lines yields ``0``.
        Rounding is half-up so it matches awk ``printf '%.0f'`` used by
        ``parse-coverage``.
    """
    total = 0
    covered = 0
    for file_hits in merged.values():
        for count in file_hits.values():
            total += 1
            if count > 0:
                covered += 1
    if total == 0:
        return 0
    return int((covered / total) * 100 + 0.5)


def write_cobertura(
    merged: dict[str, dict[int, int]],
    output_path: Path,
    percent: int,
) -> None:
    """Write a Cobertura document for the merged hit map.

    Args:
        merged: Filename → line-number → hits mapping.
        output_path: Destination XML path.
        percent: Already-rounded integer line-rate percent.
    """
    line_rate = f"{percent / 100:.4f}"
    lines_covered = 0
    lines_valid = 0
    for file_hits in merged.values():
        lines_valid += len(file_hits)
        for count in file_hits.values():
            if count > 0:
                lines_covered += 1

    chunks: list[str] = [
        '<?xml version="1.0" encoding="utf-8"?>',
        (
            f'<coverage line-rate="{line_rate}" branch-rate="0" '
            f'lines-covered="{lines_covered}" lines-valid="{lines_valid}" '
            'version="lgtm-ci-merge-cobertura">'
        ),
        "<sources><source>.</source></sources>",
        "<packages>",
        (f'<package name="merged" line-rate="{line_rate}" complexity="0">'),
        "<classes>",
    ]
    for filename in sorted(merged):
        file_hits = merged[filename]
        file_total = len(file_hits)
        file_covered = sum(1 for count in file_hits.values() if count > 0)
        file_rate = f"{(file_covered / file_total) if file_total else 0:.4f}"
        escaped_name = _escape_xml(filename)
        escaped_basename = _escape_xml(Path(filename).name)
        chunks.append(
            f'<class filename="{escaped_name}" name="{escaped_basename}" '
            f'line-rate="{file_rate}">',
        )
        chunks.append("<methods />")
        chunks.append("<lines>")
        for number in sorted(file_hits):
            chunks.append(
                f'<line number="{number}" hits="{file_hits[number]}" />',
            )
        chunks.append("</lines></class>")
    chunks.append("</classes></package></packages></coverage>")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(chunks) + "\n", encoding="utf-8")


def _emit_percent(percent: int) -> None:
    """Print the merged percent and append ``coverage-percent`` to GITHUB_OUTPUT.

    Args:
        percent: Rounded integer coverage percent.
    """
    print(percent)
    github_output = os.environ.get("GITHUB_OUTPUT", "")
    if github_output:
        with Path(github_output).open("a", encoding="utf-8") as handle:
            handle.write(f"coverage-percent={percent}\n")


def main(argv: list[str] | None = None) -> int:
    """Merge Cobertura inputs and write the combined report.

    Args:
        argv: Optional argument vector (defaults to ``sys.argv[1:]``).

    Returns:
        Process exit code: 0 on success, 2 on usage error, 1 on parse/write
        failure.
    """
    parser = argparse.ArgumentParser(
        description="Merge kcov Cobertura XML reports by max per-line hits.",
        epilog="See lgtm-ci#874. kcov v43 cannot merge bash coverage itself.",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Path to write the merged Cobertura XML.",
    )
    parser.add_argument(
        "inputs",
        nargs="+",
        help="Cobertura XML files to merge (cov.xml or cobertura.xml).",
    )
    args = parser.parse_args(argv)

    input_paths = [Path(raw) for raw in args.inputs]
    missing = [path for path in input_paths if not path.is_file()]
    if missing:
        names = ", ".join(str(path) for path in missing)
        print(
            f"[ERROR] input file(s) not found: {names}",
            file=sys.stderr,
        )
        return 2

    try:
        merged = merge_line_hits(input_paths)
        percent = coverage_percent(merged)
        write_cobertura(
            merged=merged,
            output_path=Path(args.output),
            percent=percent,
        )
    except ValueError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"[ERROR] cannot write merged coverage: {exc}", file=sys.stderr)
        return 1

    _emit_percent(percent)
    print(f"[INFO] merged coverage: {percent}%", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
