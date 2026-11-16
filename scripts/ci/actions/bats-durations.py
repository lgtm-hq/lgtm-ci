#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Per-file BATS durations for sharded kcov BATS runs (#1422).

Coverage shards of ``reusable-test-shell.yml`` are assigned by
``cksum(path) % N`` because no timing data exists. This script records how
long each ``.bats`` file takes so later work can balance the shards by
recorded duration.

Source. ``run-bats-tests.sh`` (``run-coverage``) passes ``--timing`` to bats
when bats supports it, so a timed result line of the report TAP
(``bats-report.tap``, #1539) ends in `` # in <N> ms``. A skipped test's line
ends in ``# skip [reason]`` and carries no time. TAP names no file, so
results are tied to files by test number: bats numbers tests across the
whole run in the order of the files on its command line, so file *k* owns
the numbers after the tests of files 1 to *k-1*. ``run-coverage`` writes
that file list to ``bats-files.txt``; each file's tests are read statically
from its source (``bats_durations_tap.read_tests``), executing nothing.

Limits. Attribution compares the names and the count of the statically
read tests with the report, shard by shard: the counts must add up to the
TAP plan, and each result line's description must match the static name at
its position (compared as lower-cased ASCII letters and digits only). A
shard with a file whose tests cannot be read statically records nothing:
tests registered by a loaded helper, generated tests, an ``@test`` line in
dead code, and any test definition inside heredoc text (refused on
reading, as bats may or may not register it). A test name that bash would
expand (``$``, a backtick, an unescaped double quote) is not compared. A
passing test whose name contains `` # skip `` prints its time in bats'
internal `` in <N>ms`` form after an apparent skip directive; that line
gives no value and its file is listed as missing.

A file's duration is the sum of its tests' times. Bats has no file-level
timing to offer: its JUnit report's per-file ``time`` is the same sum. So
``setup_file`` and ``teardown_file`` time is not included, nor bats' fixed
start-up cost per file; the shard's wall time and the test counts are
recorded so a consumer can fit that cost. A file counts only when every test
number in its range has a timed or skipped result line; a file whose
``setup_file`` failed (one ``not ok`` line with no time) or that a cut-short
run never reached is listed as missing, never given a made-up value. A
``teardown_file failed`` line carries the next file's first number and no
time, so it changes nothing.

Nothing is recorded (a notice or warning, no file) when the run used a test
filter (``run-coverage`` writes a marker file), when the report has more than
one plan line or a test number measured twice (a concatenated report), or
when the static tests differ from the report in count or name.

``shard`` writes ``bats-durations-shard.json`` for one shard; ``merge`` (on
the aggregate job) checks every shard document found under a directory
against the run it was asked for and merges the valid ones into
``bats-durations.json``. A shard document of an earlier attempt of the same
run counts (shards not re-run by "Re-run failed jobs"); of two documents
for one shard, the later attempt wins. ``docs/workflows/testing.md``
documents both schemas. Keys are sorted and the output is deterministic for
the same input. Each output is removed before collection starts and written
through a temporary file and an atomic rename, so a failed collection never
leaves an earlier file behind. Every input is read only when it is a
regular file, so a FIFO or a device cannot block the step.

Both commands are best effort and always exit 0 (argparse usage errors
aside): missing, empty, truncated or malformed input produces a
``::warning::`` and no file, never a failed step.

Usage:
    python3 scripts/ci/actions/bats-durations.py shard \\
        --tap bats-report.tap --files bats-files.txt \\
        --output bats-durations-shard.json \\
        --shard-index 3 --shard-total 8 --path-prefix . \\
        --sha "$GITHUB_SHA" --run-id "$GITHUB_RUN_ID" \\
        --run-attempt "$GITHUB_RUN_ATTEMPT"
    python3 scripts/ci/actions/bats-durations.py merge \\
        --dir "$RUNNER_TEMP/shard-taps" --shard-total 8 \\
        --sha "$GITHUB_SHA" --run-id "$GITHUB_RUN_ID" \\
        --run-attempt "$GITHUB_RUN_ATTEMPT" \\
        --test-path tests/bats --path-prefix . \\
        --output "$RUNNER_TEMP/bats-durations/bats-durations.json"
"""

# pylint: disable=invalid-name  # hyphenated CLI filename is the contract

from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
import posixpath
import re
import sys
import tempfile
from collections import Counter, defaultdict
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# The sibling module also loads when tests load this script by path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from bats_durations_tap import (  # noqa: E402  # pylint: disable=wrong-import-position
    MAX_SIDE_FILE_BYTES,
    MAX_TAP_BYTES,
    DurationsError,
    attribute,
    parse_tap,
    read_regular,
    read_tests,
)

__all__ = ["DurationsError", "attribute", "main", "parse_tap", "read_tests"]

SCHEMA_VERSION = 1
SHARD_FILE_NAME = "bats-durations-shard.json"
_VERSION = re.compile(r"^[0-9][0-9A-Za-z.+-]{0,63}$")


def repo_path(path: str, prefix: str) -> str:
    """Return ``path`` (relative to the working directory) from the repo root.

    Args:
        path: Path as bats was given it.
        prefix: The job's working directory, relative to the repo root.

    Returns:
        A normalized POSIX path; an absolute ``path`` stays absolute.
    """
    return posixpath.normpath(posixpath.join(prefix or ".", path))


def is_repo_path(path: str) -> bool:
    """True for a normalized repository-relative POSIX path.

    Args:
        path: A path read from a shard document.

    Returns:
        False for an absolute path, a ``..`` segment, an empty or ``.``
        path, a NUL byte, or a path that is not in normal form.
    """
    if not path or path == "." or path.startswith("/") or "\0" in path:
        return False
    return ".." not in path.split("/") and posixpath.normpath(path) == path


def _read_text(path: Path, what: str, limit: int = MAX_SIDE_FILE_BYTES) -> str:
    """Read a regular file as text, invalid UTF-8 replaced."""
    data: bytes = read_regular(path, limit, what)
    return data.decode("utf-8", errors="replace")


def read_file_list(path: Path) -> list[str]:
    """Read ``bats-files.txt``: one path per line, blank lines ignored.

    Args:
        path: The list file.

    Returns:
        The paths in run order.
    """
    lines = _read_text(path, "file list").splitlines()
    return [line for line in lines if line.strip()]


def read_wall_seconds(path: Path) -> float | None:
    """Read the shard's wall time that ``run-coverage`` wrote, in seconds.

    Args:
        path: ``bats-duration-ms.txt`` (whole milliseconds).

    Returns:
        Seconds, or None when the file is absent, not a regular file or
        not a number.
    """
    try:
        text = _read_text(path, "wall-time file").strip()
    except DurationsError:
        return None
    return round(int(text) / 1000, 3) if text.isdigit() and len(text) < 16 else None


def read_bats_version(path: Path) -> str | None:
    """Read the bats version that ``run-coverage`` recorded.

    Args:
        path: ``bats-version.txt`` (for example ``1.14.0``).

    Returns:
        The version, or None when the file is absent or malformed.
    """
    try:
        text = _read_text(path, "version file").strip()
    except DurationsError:
        return None
    return text if _VERSION.match(text) else None


@dataclass(frozen=True)
class RunIdentity:
    """The run a document belongs to.

    Attributes:
        sha: Commit the run tested.
        run_id: Workflow run id.
        run_attempt: Attempt of that run.
    """

    sha: str
    run_id: int
    run_attempt: int


def write_json(path: Path, document: Mapping[str, Any]) -> None:
    """Write a document deterministically, through a temporary file.

    Args:
        path: Target file; parent directories are created. It is replaced
            atomically, so a reader never sees a partial file.
        document: JSON-serializable mapping.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(document, indent=2, sort_keys=True, allow_nan=False) + "\n"
    descriptor, temporary = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(temporary)
        raise


def _is_seconds(value: object) -> bool:
    """True for a finite, non-negative int or float (bool excluded)."""
    if isinstance(value, bool) or not isinstance(value, int | float):
        return False
    try:
        return math.isfinite(value) and value >= 0
    except OverflowError:  # an int too large for a float, e.g. 10**400
        return False


def _is_count(value: object) -> bool:
    """True for a non-negative int (bool excluded)."""
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _check_paths(paths: Iterable[str], expected: set[str] | None) -> None:
    """Refuse a path that is not repository-relative or not expected.

    Args:
        paths: The document's paths.
        expected: The run's test files, or None when unknown.

    Raises:
        DurationsError: A path is absolute, has a ``..`` segment, is not
            normalized, or is not one of ``expected``.
    """
    for path in sorted(paths):
        if not is_repo_path(path):
            raise DurationsError(f"{path!r} is not a repository-relative path")
        if expected is not None and path not in expected:
            raise DurationsError(f"{path} is not a test file of this run")


def _check_structure(document: object) -> dict[str, Any]:
    """Check the fields and types of a shard document.

    Args:
        document: Parsed JSON.

    Returns:
        The document, unchanged.

    Raises:
        DurationsError: It does not follow the shard schema.
    """
    if not isinstance(document, dict):
        raise DurationsError("not a JSON object")
    version = document.get("schema_version")
    if not _is_count(version) or version != SCHEMA_VERSION:
        raise DurationsError(f"schema_version is not {SCHEMA_VERSION}")
    for key in ("shard_index", "shard_total", "run_id", "run_attempt"):
        if not _is_count(document.get(key)):
            raise DurationsError(f"{key} is not a non-negative integer")
    if not isinstance(document.get("sha"), str):
        raise DurationsError("sha is not a string")
    bats_version = document.get("bats_version")
    if bats_version is not None and not isinstance(bats_version, str):
        raise DurationsError("bats_version is not a string or null")
    wall = document.get("wall_seconds")
    if wall is not None and not _is_seconds(wall):
        raise DurationsError("wall_seconds is not seconds or null")
    counts = document.get("test_counts")
    if not isinstance(counts, dict) or not all(
        isinstance(key, str) and _is_count(value) for key, value in counts.items()
    ):
        raise DurationsError("test_counts is not a map of path to test count")
    durations = document.get("durations")
    if not isinstance(durations, dict) or not all(
        isinstance(key, str) and _is_seconds(value) for key, value in durations.items()
    ):
        raise DurationsError("durations is not a map of path to seconds")
    missing = document.get("missing")
    if not isinstance(missing, list) or not all(isinstance(m, str) for m in missing):
        raise DurationsError("missing is not a list of paths")
    if set(durations) & set(missing) or set(durations) | set(missing) != set(counts):
        raise DurationsError("durations and missing do not split the tested files")
    return document


def validate_shard_document(
    document: object,
    identity: RunIdentity,
    shard_total: int,
    expected: set[str] | None = None,
) -> dict[str, Any]:
    """Check a shard document read back from an artifact against the run.

    Args:
        document: Parsed JSON.
        identity: The run the merge was asked for.
        shard_total: The run's shard count.
        expected: The run's test files (repo-relative), or None when unknown.

    Returns:
        The document, unchanged.

    Raises:
        DurationsError: It does not follow the shard schema, names a path
            outside the run's test files, or belongs to another commit,
            run, shard layout or a later attempt.
    """
    checked = _check_structure(document)
    for key, value in (
        ("sha", identity.sha),
        ("run_id", identity.run_id),
        ("shard_total", shard_total),
    ):
        if checked[key] != value:
            raise DurationsError(f"{key} is {checked[key]!r}, expected {value!r}")
    attempt = checked["run_attempt"]
    if not 1 <= attempt <= identity.run_attempt:
        raise DurationsError(
            f"run_attempt {attempt} is not between 1 and {identity.run_attempt}",
        )
    if checked["shard_index"] >= shard_total:
        raise DurationsError(f"shard_index {checked['shard_index']} is out of range")
    _check_paths(checked["test_counts"], expected)
    return checked


def claimed_files(document: object) -> set[str]:
    """Return the repository paths a (possibly invalid) shard document names.

    Args:
        document: Parsed JSON.

    Returns:
        Every string key of ``test_counts`` and ``durations`` and string
        entry of ``missing`` that is a repository-relative path; empty when
        the document has none.
    """
    if not isinstance(document, dict):
        return set()
    files: set[str] = set()
    for key in ("test_counts", "durations"):
        value = document.get(key)
        if isinstance(value, dict):
            files.update(name for name in value if isinstance(name, str))
    listed = document.get("missing")
    if isinstance(listed, list):
        files.update(name for name in listed if isinstance(name, str))
    return {name for name in files if is_repo_path(name)}


def _read_candidates(
    root: Path,
    identity: RunIdentity,
    shard_total: int,
    expected: set[str] | None,
) -> tuple[list[tuple[Path, dict[str, Any]]], set[str]]:
    """Read and check every shard document under ``root``, one at a time.

    Args:
        root: Directory of the downloaded shard artifacts.
        identity: The run the merge was asked for.
        shard_total: The run's shard count.
        expected: The run's test files, or None when unknown.

    Returns:
        The valid documents with their paths, and the files the invalid
        ones named.
    """
    candidates: list[tuple[Path, dict[str, Any]]] = []
    dropped_files: set[str] = set()
    for path in sorted(root.rglob(SHARD_FILE_NAME)) if root.is_dir() else []:
        raw: object = None
        try:
            raw = json.loads(_read_text(path, "shard document"))
            checked = validate_shard_document(raw, identity, shard_total, expected)
            candidates.append((path, checked))
        # RecursionError: JSON nested deeper than the parser's stack.
        except (ValueError, RecursionError, DurationsError) as error:
            _warning(f"dropped shard durations {path}: {error}")
            dropped_files |= claimed_files(raw)
    return candidates, dropped_files


def _latest_per_shard(
    candidates: Sequence[tuple[Path, dict[str, Any]]],
) -> tuple[list[tuple[Path, dict[str, Any]]], set[str]]:
    """Keep each shard's document of the latest attempt.

    An earlier attempt's document is dropped with a notice. Two documents
    for one shard in its latest attempt are both dropped with a warning:
    neither copy can be trusted.

    Args:
        candidates: Valid documents with their paths.

    Returns:
        One document per shard index at most, and the files the dropped
        documents named.
    """
    by_index: dict[int, list[tuple[Path, dict[str, Any]]]] = defaultdict(list)
    for path, document in candidates:
        by_index[document["shard_index"]].append((path, document))
    kept: list[tuple[Path, dict[str, Any]]] = []
    dropped_files: set[str] = set()
    for index, group in sorted(by_index.items()):
        latest = max(document["run_attempt"] for _path, document in group)
        best = [entry for entry in group if entry[1]["run_attempt"] == latest]
        for path, document in group:
            if len(best) > 1:
                _warning(
                    f"dropped shard durations {path}: shard_index {index} "
                    f"appears twice in attempt {latest}",
                )
            elif document["run_attempt"] != latest:
                _notice(
                    f"dropped shard durations {path}: attempt "
                    f"{document['run_attempt']} of shard {index} is superseded "
                    f"by attempt {latest}",
                )
            else:
                kept.append((path, document))
                continue
            dropped_files |= claimed_files(document)
    return kept, dropped_files


def load_shard_documents(
    root: Path,
    identity: RunIdentity,
    shard_total: int,
    expected: set[str] | None = None,
) -> tuple[list[dict[str, Any]], set[str]]:
    """Read, check and select the shard documents under ``root``.

    A document is dropped with a warning when it is unreadable, invalid,
    from another commit, run or later attempt, when its shard index appears
    twice in the same attempt, or when one of its files also appears in
    another kept document. An earlier attempt's document for a shard that
    a later attempt also reported is dropped with a notice.

    Args:
        root: Directory of the downloaded shard artifacts.
        identity: The run the merge was asked for.
        shard_total: The run's shard count.
        expected: The run's test files, or None when unknown.

    Returns:
        The kept documents sorted by shard index, and the files the
        dropped documents named.
    """
    candidates, dropped_files = _read_candidates(
        root,
        identity,
        shard_total,
        expected,
    )
    latest, superseded = _latest_per_shard(candidates)
    dropped_files |= superseded
    owners = Counter(name for _path, doc in latest for name in doc["test_counts"])
    kept: list[dict[str, Any]] = []
    for path, document in latest:
        shared = sorted(n for n in document["test_counts"] if owners[n] > 1)
        if not shared:
            kept.append(document)
            continue
        reason = f"{shared[0]} is reported by more than one shard"
        _warning(f"dropped shard durations {path}: {reason}")
        dropped_files |= claimed_files(document)
    return sorted(kept, key=lambda doc: doc["shard_index"]), dropped_files


def expected_files(test_root: Path, prefix: str, test_path: str) -> set[str]:
    """List the repo-relative ``.bats`` files the run was asked to cover.

    Mirrors ``run-coverage``: a file ``test_path`` is the only file, a
    directory contributes every ``*.bats`` below it (symlinked directories
    not followed, like ``find``).

    Args:
        test_root: The working directory on disk.
        prefix: The working directory relative to the repo root.
        test_path: ``test-path`` relative to the working directory.

    Returns:
        Repo-relative paths.

    Raises:
        DurationsError: ``test_path`` does not exist.
    """
    target = test_root / test_path
    if target.is_file():
        return {repo_path(test_path, prefix)}
    if not target.is_dir():
        raise DurationsError(f"test path {test_path} not found under {test_root}")
    found: set[str] = set()
    for directory, _subdirs, names in os.walk(target):
        for name in names:
            candidate = Path(directory) / name
            if name.endswith(".bats") and candidate.is_file():
                relative = candidate.relative_to(test_root).as_posix()
                found.add(repo_path(relative, prefix))
    return found


def merge_documents(
    documents: Sequence[Mapping[str, Any]],
    unaccounted: Iterable[str],
) -> dict[str, Any]:
    """Merge checked shard documents (no index or file twice).

    Args:
        documents: Kept shard documents, sorted by shard index.
        unaccounted: Files that no kept document times and that must be
            listed as missing (from dropped documents and the test path).

    Returns:
        The merged fields ``durations``, ``missing``, ``test_counts``,
        ``shards`` and ``bats_version``.
    """
    durations: dict[str, float] = {}
    counts: dict[str, int] = {}
    missing: set[str] = set(unaccounted)
    shards: list[dict[str, Any]] = []
    versions = {doc["bats_version"] for doc in documents} - {None}
    for document in documents:
        durations.update({k: float(v) for k, v in document["durations"].items()})
        counts.update(document["test_counts"])
        missing.update(document["missing"])
        shards.append(
            {
                "index": document["shard_index"],
                "run_attempt": document["run_attempt"],
                "wall_seconds": document["wall_seconds"],
                "files": sorted(document["test_counts"]),
                "tests": sum(document["test_counts"].values()),
            },
        )
    if len(versions) > 1:
        _warning(f"shards ran different bats versions: {', '.join(sorted(versions))}")
    return {
        "durations": dict(sorted(durations.items())),
        "missing": sorted(missing - durations.keys()),
        "test_counts": dict(sorted(counts.items())),
        "shards": shards,
        "bats_version": versions.pop() if len(versions) == 1 else None,
    }


def _warning(message: str) -> None:
    """Print a GitHub warning annotation."""
    print(f"::warning::bats-durations: {message}")


def _notice(message: str) -> None:
    """Print a GitHub notice annotation."""
    print(f"::notice::bats-durations: {message}")


def _discard(path: Path) -> None:
    """Remove an earlier output so a failed collection publishes nothing.

    Args:
        path: The output file.
    """
    path.unlink(missing_ok=True)


def _identity(args: argparse.Namespace) -> RunIdentity:
    """Return the run identity given on the command line."""
    return RunIdentity(args.sha, args.run_id, args.run_attempt)


def _shard_command(args: argparse.Namespace) -> None:
    """Write this shard's durations, or say why there are none."""
    output = Path(args.output)
    _discard(output)
    tap_path = Path(args.tap)
    files_path = Path(args.files)
    shard = f"shard {args.shard_index}/{args.shard_total}"
    marker = Path(args.filter_marker)
    # The marker is never opened: its presence, in any form, is the signal.
    if marker.exists() or marker.is_symlink():
        _notice(f"{shard}: the run used a test filter; durations not recorded")
        return
    if not files_path.exists():
        _warning(f"{shard}: no {files_path} (the run did not start); no durations")
        return
    files = read_file_list(files_path)
    durations: dict[str, float] = {}
    missing: list[str] = []
    if files and not tap_path.exists():
        _warning(f"{shard}: no {tap_path}; no durations")
        return
    tests = {path: read_tests(Path(path)) for path in files}
    if files:
        report = _read_text(tap_path, "TAP report", MAX_TAP_BYTES)
        durations, missing = attribute(files, tests, parse_tap(report))
    else:
        _notice(f"{shard}: no test files assigned; empty durations")
    prefix = args.path_prefix
    identity = _identity(args)
    document = {
        "schema_version": SCHEMA_VERSION,
        "sha": identity.sha,
        "run_id": identity.run_id,
        "run_attempt": identity.run_attempt,
        "shard_index": args.shard_index,
        "shard_total": args.shard_total,
        "bats_version": read_bats_version(Path(args.bats_version_file)),
        "wall_seconds": read_wall_seconds(Path(args.wall_ms_file)),
        "test_counts": dict(
            sorted((repo_path(p, prefix), len(names)) for p, names in tests.items()),
        ),
        "durations": dict(
            sorted((repo_path(p, prefix), s) for p, s in durations.items()),
        ),
        "missing": sorted({repo_path(path, prefix) for path in missing}),
    }
    write_json(output, document)
    if missing:
        _warning(f"{shard}: no complete results for {', '.join(document['missing'])}")
    print(
        f"bats-durations {shard}: {len(durations)} file(s) timed, "
        f"{len(missing)} without a duration -> {output}",
    )


def _merge_command(args: argparse.Namespace) -> None:
    """Merge the shard files, or warn why there is nothing to publish."""
    output = Path(args.output)
    _discard(output)
    expected: set[str] | None = None
    try:
        expected = expected_files(Path(args.root), args.path_prefix, args.test_path)
    except DurationsError as error:
        _warning(f"{error}; files no shard ran are not listed")
    documents, dropped = load_shard_documents(
        Path(args.dir),
        _identity(args),
        args.shard_total,
        expected,
    )
    seen = [doc["shard_index"] for doc in documents]
    absent = sorted(set(range(args.shard_total)) - set(seen))
    if absent:
        names = ", ".join(str(index) for index in absent)
        _warning(f"no durations from shard(s) {names}")
    # Every test file of the run is a candidate for missing; a dropped
    # document's own paths count only when the run's files are unknown.
    unaccounted = dropped if expected is None else expected
    merged = merge_documents(documents, unaccounted)
    if not merged["durations"]:
        _warning("no shard recorded a duration; nothing to publish")
        return
    document = {
        "schema_version": SCHEMA_VERSION,
        "sha": args.sha,
        "run_id": args.run_id,
        "run_attempt": args.run_attempt,
        "shard_total": args.shard_total,
        **merged,
    }
    write_json(output, document)
    missing = merged["missing"]
    if missing:
        shown = ", ".join(missing[:20]) + (" ..." if len(missing) > 20 else "")
        _warning(f"{len(missing)} file(s) without a duration: {shown}")
    _notice(
        f"{len(merged['durations'])} file(s) timed across {len(seen)} of "
        f"{args.shard_total} shard(s) -> {output}",
    )


def _at_least(minimum: int) -> Callable[[str], int]:
    """Return an argparse type for a decimal integer of at least ``minimum``.

    Args:
        minimum: Smallest accepted value.

    Returns:
        The converter argparse calls with the raw argument.
    """

    def convert(raw: str) -> int:
        if not raw.isdigit() or int(raw) < minimum:
            raise argparse.ArgumentTypeError(f"expected an integer >= {minimum}: {raw}")
        return int(raw)

    return convert


def _sha(raw: str) -> str:
    """Accept a non-empty commit SHA (argparse type)."""
    if not raw.strip():
        raise argparse.ArgumentTypeError("expected a commit SHA")
    return raw.strip()


def _parser() -> argparse.ArgumentParser:
    """Build the command-line parser."""
    parser = argparse.ArgumentParser(
        description="Record per-file BATS durations of sharded runs.",
        epilog="See lgtm-ci#1422.",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    shard = commands.add_parser("shard", help="Write one shard's durations.")
    shard.add_argument("--tap", required=True, help="bats --timing TAP report.")
    shard.add_argument("--files", required=True, help="Run-ordered file list.")
    shard.add_argument("--output", required=True)
    shard.add_argument("--shard-index", required=True, type=_at_least(0))
    shard.add_argument(
        "--filter-marker",
        default="bats-filter-used.txt",
        help="Present when the run used a test filter: nothing is recorded.",
    )
    shard.add_argument(
        "--wall-ms-file",
        default="bats-duration-ms.txt",
        help="The shard's wall time in milliseconds.",
    )
    shard.add_argument(
        "--bats-version-file",
        default="bats-version.txt",
        help="The bats version the run used.",
    )
    merge = commands.add_parser("merge", help="Merge the shards' durations.")
    merge.add_argument("--dir", required=True, help="Downloaded shard artifacts.")
    merge.add_argument("--test-path", default="tests/bats")
    merge.add_argument(
        "--root",
        default=".",
        help="The working directory on disk (for listing the test files).",
    )
    merge.add_argument("--output", required=True)
    for command in (shard, merge):
        command.add_argument("--shard-total", required=True, type=_at_least(1))
        command.add_argument("--sha", required=True, type=_sha)
        command.add_argument("--run-id", required=True, type=_at_least(1))
        command.add_argument("--run-attempt", required=True, type=_at_least(1))
        command.add_argument(
            "--path-prefix",
            default=".",
            help="Working directory relative to the repo root.",
        )
    return parser


def main(argv: list[str] | None = None) -> int:
    """Dispatch ``shard`` / ``merge``; never fails on bad data.

    Args:
        argv: Optional argument vector (defaults to ``sys.argv[1:]``).

    Returns:
        0 always, apart from argparse usage errors (2): durations are best
        effort and must never fail a run.
    """
    args = _parser().parse_args(argv)
    try:
        if args.command == "shard":
            _shard_command(args)
        else:
            _merge_command(args)
    # Best effort by contract (#1422): any failure is a warning, not a red job.
    except Exception as error:  # pylint: disable=broad-exception-caught
        _warning(f"{args.command} failed: {error}; no durations recorded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
