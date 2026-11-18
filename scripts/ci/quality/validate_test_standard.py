#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Fail on Python test code that breaks the test standard (#1625).

Usage: validate_test_standard.py [--repo-root DIR] [--baseline FILE]
    [--base-baseline FILE | --base-ref REV] [--summary] [--all]

Reads every ``*.py`` file under ``tests/`` except ``tests/fixtures/`` (data
that other tests run in a sandbox project) and reports three rules:

``bare-assert``
    An ``assert`` statement anywhere in a scanned file: tests, helpers,
    fixtures and ``conftest.py`` alike. Assertions use ``assertpy``;
    exceptions use ``pytest.raises``.
``unittest-class``
    A class derived from ``unittest.TestCase`` (or ``IsolatedAsyncioTestCase``),
    directly, under an alias or through another class in the scanned files.
    Bases are resolved through imports, module aliases and attribute chains
    by module and name (see ``standard_graph.py``). Tests are pytest
    functions with fixtures.
``missing-docstring``
    A ``test*`` function pytest collects with no docstring: at module level
    or in a test class (``Test*`` or ``__test__ = True`` without ``__init__``,
    or a unittest class), inherited methods included and reported where they
    are defined, nested test classes and ``if``/``try``/``with`` blocks too,
    function bodies not. Each test says in one line what it proves.

The standard is enforced by ratchet while later slices of #1625 convert the
rest: ``test-standard-baseline.txt`` records, per file and rule, how many
offences are left (a count, so an offence may move within its file). The
check fails when a file has more offences than its entry allows (or has none
and is not listed), naming every offence in that file as
``file:line: [rule] what``, and when an entry is stale (the file now has
fewer, or no longer exists), so each pull request lowers the baseline it
earned.

The baseline itself may only shrink. Given the base revision's baseline
(``--base-baseline FILE``, or ``--base-ref REV`` to read it with git), the
check fails on an entry the base does not have and on a raised count. In a
GitHub Actions ``pull_request`` or ``merge_group`` run the base is ``HEAD^1``,
the commit the merge commit was built on. The caller checks it out with
``fetch-depth: 2``; failing that, the check fetches it, which needs a public
repository (the checkout keeps no credentials). A base that cannot be read
fails the check. A push runs
no ratchet: the pull request already did. A base without the baseline file
allows nothing, except before this check existed (the base has no
``validate_test_standard.py``): the pull request that adds the check
establishes the first baseline.

``--summary`` prints the totals per rule; ``--all`` prints every offence,
baseline or not. Needs Python 3.9 or newer.
"""

from __future__ import annotations

import argparse
import ast
import os
import subprocess
import sys
from collections import Counter
from collections.abc import Sequence
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

# pylint: disable=wrong-import-position
from standard_scan import RULES, Graph, Offence, collected, scan  # noqa: E402

__all__ = [
    "Offence",
    "check",
    "compare",
    "main",
    "parse_baseline",
    "ratchet",
    "scanned_files",
]

ROOT = HERE.parents[2]
BASELINE = HERE / "test-standard-baseline.txt"
BASELINE_PATH = "scripts/ci/quality/test-standard-baseline.txt"
SCRIPT_PATH = "scripts/ci/quality/validate_test_standard.py"
TESTS = "tests"
EXCLUDED = ("tests/fixtures/",)
RATCHET_EVENTS = ("pull_request", "merge_group")
MINIMUM_PYTHON = (3, 9)
PRIVATE_HINT = (
    "private repository? the checkout does not persist credentials; "
    "set fetch-depth: 2 on the caller's checkout"
)

Allowed = dict[tuple[str, str], int]


def scanned_files(repo: Path) -> list[Path]:
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


def _parse(path: Path, relative: str) -> ast.Module:
    """Read and parse one file; raise ``ValueError`` naming file and line."""
    try:
        data = path.read_bytes()
    except OSError as error:
        reason = error.strerror or error
        raise ValueError(f"{relative}:1: does not read: {reason}") from error
    try:
        return ast.parse(data.decode("utf-8"), filename=relative)
    except UnicodeDecodeError as error:
        line = data[: error.start].count(b"\n") + 1
        raise ValueError(f"{relative}:{line}: does not read: not UTF-8") from error
    except SyntaxError as error:
        where = f"{relative}:{error.lineno}"
        raise ValueError(f"{where}: does not parse: {error.msg}") from error


def check(repo: Path) -> tuple[list[Offence], list[str]]:
    """Scan every test file of a repository.

    Args:
        repo: The repository root.

    Returns:
        Every offence, and one error per file that does not read or parse
        (or one error when the repository has no ``tests/`` directory).
    """
    if not (repo / TESTS).is_dir():
        hint = "is --repo-root the repository root?"
        return [], [f"{repo / TESTS}: no such directory; {hint}"]
    trees: dict[str, ast.Module] = {}
    errors: list[str] = []
    for path in scanned_files(repo):
        relative = path.relative_to(repo).as_posix()
        try:
            trees[relative] = _parse(path, relative)
        except ValueError as error:
            errors.append(str(error))
    graph = Graph(trees)
    tests = collected(graph, trees)
    offences: list[Offence] = []
    for relative, tree in trees.items():
        offences.extend(scan(relative, tree, graph, tests))
    return offences, errors


def parse_baseline(text: str) -> tuple[Allowed, list[str]]:
    """Read the baseline: ``file rule count`` per line, ``#`` comments.

    Args:
        text: The baseline file's content.

    Returns:
        The allowed count per file and rule, and one error per bad line.
    """
    allowed: Allowed = {}
    errors: list[str] = []
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = line.split()
        if (
            len(fields) != 3
            or fields[1] not in RULES
            or not fields[2].isdigit()
            or int(fields[2]) < 1
        ):
            message = f"expected 'file rule count>0': {raw!r}"
            errors.append(f"baseline line {number}: {message}")
            continue
        key = (fields[0], fields[1])
        if key in allowed:
            message = f"duplicate entry for {fields[0]} {fields[1]}"
            errors.append(f"baseline line {number}: {message}")
            continue
        allowed[key] = int(fields[2])
    return allowed, errors


def compare(offences: Sequence[Offence], allowed: Allowed) -> list[str]:
    """Return one block of lines per file and rule that differs from the baseline.

    Args:
        offences: Every offence found.
        allowed: The baseline count per file and rule.

    Returns:
        For each file and rule over its entry, a heading and every offence of
        that rule in the file; for each entry above the count found, one
        line asking to lower it.
    """
    grouped: dict[tuple[str, str], list[Offence]] = {}
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


def ratchet(allowed: Allowed, base: Allowed) -> list[str]:
    """Return one line per baseline entry that grew against the base revision.

    Args:
        allowed: The baseline of the change.
        base: The baseline of the revision the change is built on.

    Returns:
        A line for each entry the base does not have and each raised count;
        lowered and removed entries are fine.
    """
    lines: list[str] = []
    for key in sorted(allowed):
        if key not in base:
            lines.append(f"{key[0]}: new baseline entry {key[1]} {allowed[key]}")
        elif allowed[key] > base[key]:
            limit = f"{key[1]} {base[key]} raised to {allowed[key]}"
            lines.append(f"{key[0]}: baseline entry {limit}")
    return lines


def _git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    """Run git in the repository, capturing its output, never prompting."""
    return subprocess.run(  # noqa: S603 - fixed argv, no shell
        ["git", "-C", str(repo), *args],  # noqa: S607 - git from PATH, as in CI
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
    )


def base_baseline(repo: Path, ref: str, fetch: bool) -> tuple[str | None, str]:
    """Read the baseline of a base revision with git.

    Args:
        repo: The repository root.
        ref: The base revision.
        fetch: Fetch one more level of history when ``ref`` is missing from a
            shallow checkout (CI checks out the merge commit alone).

    Returns:
        The base baseline's text (``""`` when the base allows nothing, ``None``
        on the bootstrap pull request), and a message naming the base.

    Raises:
        ValueError: When the base revision cannot be read.
    """
    commit = f"{ref}^{{commit}}"
    fetched = ""
    if _git(repo, "rev-parse", "--verify", "--quiet", commit).returncode != 0 and fetch:
        head = _git(repo, "rev-parse", "HEAD").stdout.strip()
        depth = ("--quiet", "--no-tags", "--depth=2", "origin", head)
        result = _git(repo, "fetch", *depth)
        if result.returncode != 0:
            fetched = f"; git fetch failed: {result.stderr.strip() or 'no output'}"
            fetched += f" ({PRIVATE_HINT})"
    if _git(repo, "rev-parse", "--verify", "--quiet", commit).returncode != 0:
        hint = "fetch it or pass --base-baseline"
        raise ValueError(f"base revision {ref} is not available; {hint}{fetched}")
    shown = _git(repo, "show", f"{ref}:{BASELINE_PATH}")
    if shown.returncode == 0:
        return shown.stdout, f"the baseline of {ref}"
    has_script = _git(repo, "cat-file", "-e", f"{ref}:{SCRIPT_PATH}").returncode == 0
    if has_script:
        return "", f"{ref}, which has no baseline file"
    return None, f"{ref}, which predates the check"


def _read(path: Path, what: str) -> str:
    """Return a file's text; raise ``ValueError`` saying which file is unreadable."""
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise ValueError(f"cannot read the {what} {path}: {error}") from error


def _base(args: argparse.Namespace) -> tuple[str | None, str]:
    """Return the base baseline text the arguments or the CI event ask for."""
    if args.base_baseline is not None:
        name = f"the base baseline {args.base_baseline}"
        return _read(args.base_baseline, "base baseline"), name
    ref, fetch = args.base_ref, False
    if ref is None and os.environ.get("GITHUB_ACTIONS") == "true":
        if os.environ.get("GITHUB_EVENT_NAME") not in RATCHET_EVENTS:
            return None, "a push, which the pull request already ratcheted"
        ref, fetch = "HEAD^1", True
    if ref is None:
        return None, "no base given (--base-ref or --base-baseline)"
    return base_baseline(args.repo_root, ref, fetch)


def summary(offences: Sequence[Offence]) -> list[str]:
    """Return the number of offences and of files per rule.

    Args:
        offences: Every offence found.

    Returns:
        One ``rule: N in M files`` line per rule.
    """
    counts = Counter(offence.rule for offence in offences)
    files = {rule: {o.file for o in offences if o.rule == rule} for rule in RULES}
    return [f"{rule}: {counts[rule]} in {len(files[rule])} files" for rule in RULES]


def _arguments(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--baseline", type=Path, default=BASELINE)
    base = parser.add_mutually_exclusive_group()
    base.add_argument(
        "--base-baseline",
        type=Path,
        help="the base revision's baseline file",
    )
    base.add_argument("--base-ref", help="the base revision, read with git")
    parser.add_argument("--summary", action="store_true", help="print totals per rule")
    parser.add_argument("--all", action="store_true", help="print every offence")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Run the check.

    Args:
        argv: Command-line arguments, defaulting to ``sys.argv[1:]``.

    Returns:
        0 when every file matches a baseline that did not grow, 1 otherwise.
    """
    if sys.version_info < MINIMUM_PYTHON:
        message = "ERROR: validate_test_standard.py needs Python 3.9 or newer"
        print(message, file=sys.stderr)
        return 1
    args = _arguments(argv)
    offences, errors = check(args.repo_root)
    try:
        allowed, baseline_errors = parse_baseline(_read(args.baseline, "baseline"))
        base_text, base_name = _base(args)
    except ValueError as error:
        print(f"ERROR: {error}")
        return 1
    errors.extend(baseline_errors)
    if base_text is None:
        print(f"Baseline ratchet skipped: {base_name}")
    else:
        base, base_errors = parse_baseline(base_text)
        errors.extend(f"base {line}" for line in base_errors)
        grown = ratchet(allowed, base)
        if grown:
            heading = f"The baseline grew against {base_name}; it may only shrink:"
            errors.append(heading)
            errors.extend(f"  {line}" for line in grown)
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
