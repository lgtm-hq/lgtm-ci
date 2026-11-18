#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Fail on Python under ``scripts/ci`` that breaks the source standard (#1626).

Usage: validate_source_standard.py [--repo-root DIR] [--exceptions FILE]
    [--base-exceptions FILE | --base-ref REV] [--summary]

Reads every ``*.py`` file under ``scripts/ci`` and reports two rules:

``missing-docstring``
    A module, class or function without a docstring. Private and nested
    functions and dunder methods count too, which ruff's ``D1`` rules skip.
    ``__init__`` is the exception: its class docstring documents it, and
    pydoclint (``DOC301``) rejects a docstring on it. There is no baseline:
    the tree has none left.
``module-length``
    A module over ``LIMIT`` (400) lines that ``module-length-exceptions.txt``
    does not list. Each entry there is ``path reason``, the reason saying why
    the module is still long (a split planned in #1626, or what binds it to
    one file). An entry whose module is now within the limit, or gone, is
    stale and fails too: delete it in the same pull request.

The exception list may only shrink. Given the base revision's list
(``--base-exceptions FILE``, or ``--base-ref REV`` to read it with git), the
check fails on an entry the base does not have: split a new long module
instead of listing it. In a GitHub Actions ``pull_request`` or ``merge_group``
run the base is ``HEAD^1``, the commit the merge commit was built on; the
caller checks it out with ``fetch-depth: 2``. A push runs no ratchet: the pull
request already did. A base without this script predates the check and
allows the first list; a base with the script but without the list allows
nothing.

``--summary`` prints the count per rule. Standard library only.
"""

from __future__ import annotations

import argparse
import ast
import sys
from collections.abc import Sequence
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

# pylint: disable=wrong-import-position
from standard_offence import Offence  # noqa: E402
from standard_ratchet import base_file, ci_base_ref, has_commit, read  # noqa: E402

ROOT = HERE.parents[2]
SOURCE = "scripts/ci"
LIMIT = 400
EXCEPTIONS = HERE / "module-length-exceptions.txt"
EXCEPTIONS_PATH = "scripts/ci/quality/module-length-exceptions.txt"
SCRIPT_PATH = "scripts/ci/quality/validate_source_standard.py"
RULES = ("missing-docstring", "module-length")
DEFINITIONS = (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)
DOCUMENTED_BY_CLASS = "__init__"

Exceptions = dict[str, str]


def source_files(repo: Path) -> list[Path]:
    """Return every Python file under ``scripts/ci``, sorted.

    Args:
        repo: The repository root.

    Returns:
        The ``*.py`` files under ``SOURCE``.
    """
    return sorted((repo / SOURCE).rglob("*.py"))


def _documented(node: ast.AST) -> bool:
    """Return whether a module, class or function has a non-blank docstring."""
    docstring = ast.get_docstring(node)  # type: ignore[arg-type]
    return bool(docstring and docstring.strip())


def missing_docstrings(relative: str, tree: ast.Module) -> list[Offence]:
    """Return one offence per module, class or function without a docstring.

    A constructor (``__init__`` directly in a class body) is skipped: the
    class docstring documents it. An empty or blank docstring counts as none.

    Args:
        relative: The file's repository-relative path.
        tree: The parsed file.

    Returns:
        The offences in source order.
    """
    offences = []
    if not _documented(tree):
        offences.append(Offence(relative, 1, RULES[0], "module has no docstring"))
    constructors = {
        id(item)
        for owner in ast.walk(tree)
        if isinstance(owner, ast.ClassDef)
        for item in owner.body
        if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef))
        and item.name == DOCUMENTED_BY_CLASS
    }
    nodes = [node for node in ast.walk(tree) if isinstance(node, DEFINITIONS)]
    for node in sorted(nodes, key=lambda node: node.lineno):
        if id(node) not in constructors and not _documented(node):
            kind = "class" if isinstance(node, ast.ClassDef) else "function"
            what = f"{kind} {node.name} has no docstring"
            offences.append(Offence(relative, node.lineno, RULES[0], what))
    return offences


def check(repo: Path) -> tuple[list[Offence], dict[str, int], list[str]]:
    """Scan every Python file under ``scripts/ci``.

    Args:
        repo: The repository root.

    Returns:
        The docstring offences, the line count of each module over ``LIMIT``,
        and one error per file that does not read or parse (or one error when
        the repository has no ``scripts/ci`` directory).
    """
    if not (repo / SOURCE).is_dir():
        hint = "is --repo-root the repository root?"
        return [], {}, [f"{repo / SOURCE}: no such directory; {hint}"]
    offences: list[Offence] = []
    long: dict[str, int] = {}
    errors: list[str] = []
    for path in source_files(repo):
        relative = path.relative_to(repo).as_posix()
        try:
            text = path.read_text(encoding="utf-8")
            tree = ast.parse(text, filename=relative)
        except (OSError, UnicodeDecodeError) as error:
            errors.append(f"{relative}:1: does not read: {error}")
            continue
        except SyntaxError as error:
            errors.append(f"{relative}:{error.lineno}: does not parse: {error.msg}")
            continue
        except ValueError as error:  # a NUL byte, on Pythons that raise this
            errors.append(f"{relative}:1: does not parse: {error}")
            continue
        offences.extend(missing_docstrings(relative, tree))
        lines = len(text.splitlines())
        if lines > LIMIT:
            long[relative] = lines
    return offences, long, errors


def parse_exceptions(text: str) -> tuple[Exceptions, list[str]]:
    """Read the exception list: ``path reason`` per line, ``#`` comment lines.

    Args:
        text: The list's content.

    Returns:
        The reason per listed path, and one error per bad line.
    """
    listed: Exceptions = {}
    errors: list[str] = []
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split(maxsplit=1)
        if len(fields) != 2 or not fields[0].startswith(f"{SOURCE}/"):
            message = f"expected '{SOURCE}/<path>.py reason': {raw!r}"
            errors.append(f"exceptions line {number}: {message}")
        elif fields[0] in listed:
            errors.append(f"exceptions line {number}: duplicate entry {fields[0]}")
        else:
            listed[fields[0]] = fields[1]
    return listed, errors


def compare(long: dict[str, int], listed: Exceptions) -> list[str]:
    """Return one line per long module not listed and per stale entry.

    Args:
        long: The line count of each module over ``LIMIT``.
        listed: The exception list.

    Returns:
        The offences of the ``module-length`` rule, sorted by path.
    """
    lines = []
    for relative in sorted(long.keys() - listed.keys()):
        what = f"{long[relative]} lines, over the {LIMIT}-line limit and not listed"
        lines.append(Offence(relative, 1, RULES[1], what).render())
    for relative in sorted(listed.keys() - long.keys()):
        lines.append(
            f"{relative}: stale exception entry: the module is gone or within "
            f"{LIMIT} lines; remove the entry",
        )
    return lines


def ratchet(listed: Exceptions, base: Exceptions) -> list[str]:
    """Return one line per exception entry the base revision does not have.

    Args:
        listed: The exception list of the change.
        base: The exception list of the revision the change is built on.

    Returns:
        A line per new entry; removed entries and changed reasons are fine.
    """
    new = sorted(listed.keys() - base.keys())
    return [f"{relative}: new exception entry" for relative in new]


def base_exceptions(repo: Path, ref: str) -> tuple[str | None, str]:
    """Read the exception list of a base revision with git.

    Args:
        repo: The repository root.
        ref: The base revision.

    Returns:
        The base list's text (``""`` when the base allows nothing, ``None``
        when the base predates the check), and a message naming the base.

    Raises:
        ValueError: When the base revision is not in the checkout.
    """
    if not has_commit(repo, ref):
        raise ValueError(
            f"base revision {ref} is not available; fetch it or pass --base-exceptions"
        )
    names = ("the exception list", "no exception list")
    text: str | None
    name: str
    text, name = base_file(repo, ref, (EXCEPTIONS_PATH, SCRIPT_PATH), names)
    return text, name


def _base(args: argparse.Namespace) -> tuple[str | None, str]:
    """Return the base exception list the arguments or the CI event ask for."""
    if args.base_exceptions is not None:
        name = f"the base exception list {args.base_exceptions}"
        return read(args.base_exceptions, "base exception list"), name
    ref = args.base_ref
    if ref is None:
        ref, skipped = ci_base_ref()
        if skipped is not None:
            return None, skipped
    if ref is None:
        return None, "no base given (--base-ref or --base-exceptions)"
    return base_exceptions(args.repo_root, ref)


def _arguments(argv: Sequence[str] | None) -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--exceptions", type=Path, default=EXCEPTIONS)
    base = parser.add_mutually_exclusive_group()
    base.add_argument(
        "--base-exceptions",
        type=Path,
        help="the base revision's exception list",
    )
    base.add_argument("--base-ref", help="the base revision, read with git")
    parser.add_argument(
        "--summary",
        action="store_true",
        help="print the count per rule",
    )
    return parser.parse_args(argv)


def _ratchet_errors(
    listed: Exceptions,
    base_text: str | None,
    base_name: str,
) -> list[str]:
    """Return the errors of comparing the list with the base list's text.

    Args:
        listed: The exception list of the change.
        base_text: The base list's text, or None when no ratchet runs.
        base_name: What the base is, for the messages.

    Returns:
        One error per bad base line, then a heading and one line per new entry.
    """
    if base_text is None:
        print(f"Exception list ratchet skipped: {base_name}")
        return []
    base, base_errors = parse_exceptions(base_text)
    errors = [f"base {line}" for line in base_errors]
    grown = ratchet(listed, base)
    if grown:
        errors.append(
            f"The exception list grew against {base_name}; it may only shrink:",
        )
        errors.extend(f"  {line}" for line in grown)
    return errors


def main(argv: Sequence[str] | None = None) -> int:
    """Run the check.

    Args:
        argv: Command-line arguments, defaulting to ``sys.argv[1:]``.

    Returns:
        0 when the source meets the standard and the list did not grow, 1 otherwise.
    """
    args = _arguments(argv)
    offences, long, errors = check(args.repo_root)
    try:
        listed, list_errors = parse_exceptions(read(args.exceptions, "exception list"))
        base_text, base_name = _base(args)
    except ValueError as error:
        print(f"ERROR: {error}")
        return 1
    errors.extend(list_errors)
    errors.extend(_ratchet_errors(listed, base_text, base_name))
    length_lines = compare(long, listed)
    if args.summary:
        print(f"{RULES[0]}: {len(offences)}")
        counts = f"{len(long)} modules over {LIMIT} lines, {len(listed)} listed"
        print(f"{RULES[1]}: {counts}")
    lines = errors + [offence.render() for offence in offences] + length_lines
    if lines:
        print("Python source under scripts/ci that breaks the source standard (#1626):")
        print("\n".join(lines))
        print(
            "Add a Google-style docstring to every module, class and function; split "
            f"a module over {LIMIT} lines; remove an exception entry once its module "
            "fits.",
        )
        return 1
    print("OK: scripts/ci Python source meets the source standard")
    return 0


if __name__ == "__main__":
    sys.exit(main())
