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

Stdlib only (``argparse``, ``xml.etree.ElementTree``). Do not pass
``kcov --merge``; it yields empty bash coverage.

Usage:
    python3 scripts/ci/actions/merge-cobertura.py \\
        --output merged.xml shard0/cov.xml shard1/cov.xml
"""

from __future__ import annotations

import argparse
import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def _local_tag(tag: str) -> str:
    """Return the element tag without an XML namespace prefix.

    Args:
        tag: Raw ElementTree tag, possibly ``{namespace}name``.

    Returns:
        The local name.
    """
    if tag.startswith("{") and "}" in tag:
        return tag.split("}", 1)[1]
    return tag


def _iter_class_elements(root: ET.Element) -> list[ET.Element]:
    """Return every Cobertura ``class`` element under ``root``.

    Args:
        root: Parsed coverage document root.

    Returns:
        Class elements that carry a ``filename`` attribute.
    """
    classes: list[ET.Element] = []
    for elem in root.iter():
        if _local_tag(elem.tag) != "class":
            continue
        if "filename" not in elem.attrib:
            continue
        classes.append(elem)
    return classes


def _iter_line_hits(class_elem: ET.Element) -> list[tuple[int, int]]:
    """Return ``(line_number, hits)`` pairs for one class.

    Args:
        class_elem: A Cobertura ``class`` element.

    Returns:
        Line hits. Malformed ``number``/``hits`` values are skipped.
    """
    hits: list[tuple[int, int]] = []
    for elem in class_elem.iter():
        if _local_tag(elem.tag) != "line":
            continue
        raw_number = elem.attrib.get("number")
        if raw_number is None:
            continue
        try:
            number = int(raw_number)
            count = int(elem.attrib.get("hits", "0"))
        except ValueError:
            continue
        if number < 0 or count < 0:
            continue
        hits.append((number, count))
    return hits


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
        ValueError: When a path cannot be parsed as Cobertura XML.
    """
    merged: dict[str, dict[int, int]] = {}
    for path in input_paths:
        try:
            tree = ET.parse(path)
        except (ET.ParseError, OSError) as exc:
            raise ValueError(f"cannot parse Cobertura XML {path}: {exc}") from exc
        for class_elem in _iter_class_elements(tree.getroot()):
            filename = class_elem.attrib["filename"]
            file_hits = merged.setdefault(filename, {})
            for number, count in _iter_line_hits(class_elem):
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
    coverage = ET.Element(
        "coverage",
        {
            "line-rate": line_rate,
            "branch-rate": "0",
            "lines-covered": str(lines_covered),
            "lines-valid": str(lines_valid),
            "version": "lgtm-ci-merge-cobertura",
        },
    )
    sources = ET.SubElement(coverage, "sources")
    ET.SubElement(sources, "source").text = "."
    packages = ET.SubElement(coverage, "packages")
    package = ET.SubElement(
        packages,
        "package",
        {
            "name": "merged",
            "line-rate": line_rate,
            "complexity": "0",
        },
    )
    classes = ET.SubElement(package, "classes")
    for filename in sorted(merged):
        file_hits = merged[filename]
        file_total = len(file_hits)
        file_covered = sum(1 for count in file_hits.values() if count > 0)
        file_rate = f"{(file_covered / file_total) if file_total else 0:.4f}"
        class_elem = ET.SubElement(
            classes,
            "class",
            {
                "filename": filename,
                "name": Path(filename).name,
                "line-rate": file_rate,
            },
        )
        ET.SubElement(class_elem, "methods")
        lines_elem = ET.SubElement(class_elem, "lines")
        for number in sorted(file_hits):
            ET.SubElement(
                lines_elem,
                "line",
                {
                    "number": str(number),
                    "hits": str(file_hits[number]),
                },
            )
    tree = ET.ElementTree(coverage)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    tree.write(
        output_path,
        encoding="utf-8",
        xml_declaration=True,
    )


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
