#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Fail on Python test code that breaks the test standard (#1625).

Usage: validate_test_standard.py [--repo-root DIR] [--baseline FILE] [--summary] [--all]

Reads every ``*.py`` file under ``tests/`` except ``tests/fixtures/`` (data
that other tests run in a sandbox project) and reports three rules:

``bare-assert``
    An ``assert`` statement. Assertions use ``assertpy``; exceptions use
    ``pytest.raises``.
``unittest-class``
    A class derived from ``unittest.TestCase`` (or ``IsolatedAsyncioTestCase``),
    directly or through another class in the scanned files. Tests are pytest
    functions with fixtures.
``missing-docstring``
    A function named ``test*`` at module level or directly in a class with no
    docstring. Each test says in one line what it proves.

The standard is enforced by ratchet while later slices of #1625 convert the
rest: ``test-standard-baseline.txt`` records, per file and rule, how many
offences are left. The check fails when a file has more offences than its
entry allows (or has none and is not listed), naming every offence in that
file as ``file:line: [rule] what``, and when an entry is stale (the file now
has fewer, or no longer exists), so each pull request lowers the baseline it
earned. ``--summary`` prints the totals per rule; ``--all`` prints every
offence, baseline or not.
"""

from __future__ import annotations

import argparse
import ast
import sys
from collections import Counter
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

__all__ = [
    "Offence",
    "Rule",
    "check",
    "compare",
    "main",
    "parse_baseline",
    "scan",
    "test_files",
]

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
BASELINE = HERE / "test-standard-baseline.txt"
TESTS = "tests"
EXCLUDED = ("tests/fixtures/",)
UNITTEST_BASES = frozenset({"TestCase", "IsolatedAsyncioTestCase"})


class Rule(StrEnum):
    """A rule of the test standard, spelled as in reports and the baseline."""

    BARE_ASSERT = "bare-assert"
    UNITTEST_CLASS = "unittest-class"
    MISSING_DOCSTRING = "missing-docstring"


@dataclass(frozen=True)
class Offence:
    """One place in a test file that breaks a rule."""

    file: str
    line: int
    rule: Rule
    what: str

    def render(self) -> str:
        """Return the offence as ``file:line: [rule] what``."""
        return f"{self.file}:{self.line}: [{self.rule}] {self.what}"


def test_files(repo: Path) -> list[Path]:
    """Return the scanned Python files under ``tests/``, sorted.

    Args:
        repo: The repository root.

    Returns:
        Every ``*.py`` file under ``tests/`` outside ``EXCLUDED``.
    """
    files = []
    for path in sorted((repo / TESTS).rglob("*.py")):
        relative = path.relative_to(repo).as_posix()
        if not relative.startswith(EXCLUDED):
            files.append(path)
    return files


def _base_name(node: ast.expr) -> str | None:
    """Return the last name of a base class expression, if it has one."""
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return node.attr
    return None


def _unittest_classes(trees: Iterable[ast.Module]) -> set[str]:
    """Return the names of every class that derives from a unittest base.

    Subclasses are matched by name across all files, to a fixed point, so a
    case class derived from a shared base in another helper module counts.
    """
    edges: list[tuple[str, set[str]]] = []
    for tree in trees:
        for node in ast.walk(tree):
            if isinstance(node, ast.ClassDef):
                bases = {name for name in map(_base_name, node.bases) if name}
                edges.append((node.name, bases))
    found = set(UNITTEST_BASES)
    changed = True
    while changed:
        changed = False
        for name, bases in edges:
            if name not in found and bases & found:
                found.add(name)
                changed = True
    return found - UNITTEST_BASES


Function = ast.FunctionDef | ast.AsyncFunctionDef


def _tests_in(body: Sequence[ast.stmt]) -> Iterable[Function]:
    """Yield the ``test*`` functions defined directly in a body."""
    for node in body:
        if isinstance(node, Function) and node.name.startswith("test"):
            yield node


def scan(relative: str, tree: ast.Module, unittest_classes: set[str]) -> list[Offence]:
    """Return every offence in one parsed file, in line order.

    Args:
        relative: The file's repository-relative path, for the report.
        tree: The parsed file.
        unittest_classes: Names of the classes that derive from a unittest base.

    Returns:
        The offences.
    """
    found: list[Offence] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Assert):
            what = "bare assert; use assertpy (assert_that)"
            found.append(Offence(relative, node.lineno, Rule.BARE_ASSERT, what))
        elif isinstance(node, ast.ClassDef):
            bases = {name for name in map(_base_name, node.bases) if name}
            if bases & (UNITTEST_BASES | unittest_classes):
                what = f"class {node.name} is a unittest.TestCase; use pytest functions"
                found.append(Offence(relative, node.lineno, Rule.UNITTEST_CLASS, what))
    scopes: list[Sequence[ast.stmt]] = [tree.body]
    scopes.extend(node.body for node in tree.body if isinstance(node, ast.ClassDef))
    for body in scopes:
        for function in _tests_in(body):
            if not (ast.get_docstring(function) or "").strip():
                what = f"{function.name} has no docstring saying what it proves"
                rule = Rule.MISSING_DOCSTRING
                found.append(Offence(relative, function.lineno, rule, what))
    return sorted(found, key=lambda offence: (offence.line, offence.rule))


def check(repo: Path) -> tuple[list[Offence], list[str]]:
    """Scan every test file of a repository.

    Args:
        repo: The repository root.

    Returns:
        Every offence, and one error per file that does not parse.
    """
    trees: dict[str, ast.Module] = {}
    errors: list[str] = []
    for path in test_files(repo):
        relative = path.relative_to(repo).as_posix()
        try:
            text = path.read_text(encoding="utf-8")
            trees[relative] = ast.parse(text, filename=relative)
        except SyntaxError as error:
            errors.append(f"{relative}:{error.lineno}: does not parse: {error.msg}")
    classes = _unittest_classes(trees.values())
    offences: list[Offence] = []
    for relative, tree in trees.items():
        offences.extend(scan(relative, tree, classes))
    return offences, errors


def parse_baseline(text: str) -> tuple[dict[tuple[str, Rule], int], list[str]]:
    """Read the baseline: ``file rule count`` per line, ``#`` comments.

    Args:
        text: The baseline file's content.

    Returns:
        The allowed count per file and rule, and one error per bad line.
    """
    allowed: dict[tuple[str, Rule], int] = {}
    errors: list[str] = []
    rules = {rule.value: rule for rule in Rule}
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = line.split()
        if (
            len(fields) != 3
            or fields[1] not in rules
            or not fields[2].isdigit()
            or int(fields[2]) < 1
        ):
            message = f"expected 'file rule count>0': {raw!r}"
            errors.append(f"baseline line {number}: {message}")
            continue
        key = (fields[0], rules[fields[1]])
        if key in allowed:
            message = f"duplicate entry for {fields[0]} {fields[1]}"
            errors.append(f"baseline line {number}: {message}")
            continue
        allowed[key] = int(fields[2])
    return allowed, errors


def compare(
    offences: Sequence[Offence],
    allowed: dict[tuple[str, Rule], int],
) -> list[str]:
    """Return one block of lines per file and rule that differs from the baseline.

    Args:
        offences: Every offence found.
        allowed: The baseline count per file and rule.

    Returns:
        For each file and rule over its entry, a heading and every offence of
        that rule in the file; for each entry above the count found, one
        line asking to lower it.
    """
    grouped: dict[tuple[str, Rule], list[Offence]] = {}
    for offence in offences:
        grouped.setdefault((offence.file, offence.rule), []).append(offence)
    lines: list[str] = []
    for key in sorted(grouped):
        count, limit = len(grouped[key]), allowed.get(key, 0)
        if count > limit:
            heading = f"{count} {key[1]} offences, baseline allows {limit}:"
            lines.append(f"{key[0]}: {heading}")
            lines.extend(f"  {offence.render()}" for offence in grouped[key])
    for key in sorted(allowed):
        count, limit = len(grouped.get(key, [])), allowed[key]
        if count < limit:
            lines.append(
                f"{key[0]}: stale baseline entry: {key[1]} {limit}, now {count}; "
                + ("remove the entry" if count == 0 else f"lower it to {count}"),
            )
    return lines


def summary(offences: Sequence[Offence]) -> list[str]:
    """Return the number of offences and of files per rule.

    Args:
        offences: Every offence found.

    Returns:
        One ``rule: N in M files`` line per rule.
    """
    counts = Counter(offence.rule for offence in offences)
    files = {rule: {o.file for o in offences if o.rule is rule} for rule in Rule}
    return [f"{rule}: {counts[rule]} in {len(files[rule])} files" for rule in Rule]


def main(argv: Sequence[str] | None = None) -> int:
    """Run the check.

    Args:
        argv: Command-line arguments, defaulting to ``sys.argv[1:]``.

    Returns:
        0 when every file matches the baseline, 1 otherwise.
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--baseline", type=Path, default=BASELINE)
    parser.add_argument("--summary", action="store_true", help="print totals per rule")
    parser.add_argument("--all", action="store_true", help="print every offence")
    args = parser.parse_args(argv)
    offences, errors = check(args.repo_root)
    allowed, baseline_errors = parse_baseline(args.baseline.read_text(encoding="utf-8"))
    errors.extend(baseline_errors)
    if args.summary:
        print("\n".join(summary(offences)))
    if args.all:
        print("\n".join(offence.render() for offence in offences))
    lines = errors + compare(offences, allowed)
    if lines:
        print("Test code that does not match the test standard baseline (#1625):")
        print("\n".join(lines))
        print(
            "Convert new or changed tests to the standard (pytest functions, assertpy, "
            "a docstring per test); lower the baseline when a file gets cleaner.",
        )
        return 1
    print("OK: test code matches the test standard baseline")
    return 0


if __name__ == "__main__":
    sys.exit(main())
