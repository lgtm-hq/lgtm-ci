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
the same input. Each output is removed before collection starts, and again
when a command fails after it began writing, so a failed collection never
leaves a file behind; the upload step reads it only after this one ends.

Trust. ``shard`` reads only files its own job wrote moments earlier: the
report, the file list, the side files and the test files of its checkout.
It reads them as they are. ``merge`` reads shard documents that other jobs
uploaded as artifacts, so each one is read with a size bound and checked in
full (schema and types, run, attempt, shard index, every path one of the
run's test files, no file in two shards); a bad one is dropped on its own.
``merge`` publishes nothing when it cannot list the run's test files, and
names every shard it could not use in the job summary.

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
import html
import json
import math
import os
import posixpath
import re
import sys
from collections import Counter, defaultdict
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# The sibling module also loads when tests load this script by path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from bats_durations_tap import (  # noqa: E402  # pylint: disable=wrong-import-position
    DurationsError,
    attribute,
    parse_tap,
    read_tests,
)

__all__ = ["DurationsError", "attribute", "main", "parse_tap", "read_tests"]

SCHEMA_VERSION = 1
SHARD_FILE_NAME = "bats-durations-shard.json"
# A shard document comes from another job's artifact and is a few kilobytes;
# anything larger is dropped unread.
MAX_SHARD_DOCUMENT_BYTES = 16 * 1024 * 1024
# A reason shown in the job summary is cut to this many characters.
_SUMMARY_REASON_CHARS = 300
# The job summary is dropped whole above 1 MiB: list this many refusals.
_SUMMARY_MAX_REFUSALS = 50
_VERSION = re.compile(r"^[0-9][0-9A-Za-z.+-]{0,63}$")
_MARKDOWN = re.compile(r"([\\`*_\[\]|~!#])")


def repo_path(path: str, prefix: str) -> str:
    """Return ``path`` (relative to the working directory) from the repo root.

    Args:
        path: Path as bats was given it.
        prefix: The job's working directory, relative to the repo root.

    Returns:
        A normalized POSIX path; an absolute ``path`` stays absolute.
    """
    return posixpath.normpath(posixpath.join(prefix or ".", path))


def _read_text(path: Path) -> str:
    """Read a file this job wrote, invalid UTF-8 replaced."""
    return path.read_text(encoding="utf-8", errors="replace")


def read_file_list(path: Path) -> list[str]:
    """Read ``bats-files.txt``: one path per line, blank lines ignored.

    Args:
        path: The list file.

    Returns:
        The paths in run order.
    """
    return [line for line in _read_text(path).splitlines() if line.strip()]


def _read_side_file(path: Path) -> str | None:
    """Read a one-line side file of ``run-coverage``; None when unreadable."""
    try:
        return _read_text(path).strip()
    except OSError:
        return None


def read_wall_seconds(path: Path) -> float | None:
    """Read the shard's wall time that ``run-coverage`` wrote, in seconds.

    Args:
        path: ``bats-duration-ms.txt`` (whole milliseconds).

    Returns:
        Seconds, or None when the file is absent or not a number.
    """
    text = _read_side_file(path)
    # Under 16 digits: a longer number is not a duration, and it must cost
    # only the wall time, not the shard's durations.
    if not text or not text.isdecimal() or len(text) >= 16:
        return None
    return round(int(text) / 1000, 3)


def read_bats_version(path: Path) -> str | None:
    """Read the bats version that ``run-coverage`` recorded.

    Args:
        path: ``bats-version.txt`` (for example ``1.14.0``).

    Returns:
        The version, or None when the file is absent or malformed.
    """
    text = _read_side_file(path)
    return text if text and _VERSION.match(text) else None


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
    """Write a document deterministically (sorted keys, two-space indent).

    Args:
        path: Target file; parent directories are created. Nothing reads it
            while this step runs, and :func:`main` removes it when the step
            fails after this began, so it is written in place.
        document: JSON-serializable mapping.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(document, indent=2, sort_keys=True, allow_nan=False) + "\n"
    path.write_text(text, encoding="utf-8")


def _is_seconds(value: object) -> bool:
    """True for a finite, non-negative int or float (bool excluded)."""
    if isinstance(value, bool) or not isinstance(value, int | float):
        return False
    try:
        return math.isfinite(value) and value >= 0
    # A shard document crosses a job boundary: an int too large for a float
    # (10**400) drops that document, not the whole merge.
    except OverflowError:
        return False


def _is_count(value: object) -> bool:
    """True for a non-negative int (bool excluded)."""
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


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
    expected: set[str],
) -> dict[str, Any]:
    """Check a shard document read back from an artifact against the run.

    Args:
        document: Parsed JSON.
        identity: The run the merge was asked for.
        shard_total: The run's shard count.
        expected: The run's test files (repo-relative), as the aggregate job
            lists them from its own checkout.

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
    unknown = sorted(set(checked["test_counts"]) - expected)
    if unknown:
        raise DurationsError(f"{unknown[0]!r} is not a test file of this run")
    return checked


@dataclass(frozen=True)
class Refusal:
    """A shard document the merge did not use, for the job summary.

    Attributes:
        shard: The shard index, when the document names one in range.
        source: The artifact folder the document came from.
        reason: Why it was not used.
        claimed: True when ``shard`` is only what a document that failed
            its checks says about itself. Another, valid document may hold
            that shard's real data.
    """

    shard: int | None
    source: str
    reason: str
    claimed: bool = False


def _refuse(
    path: Path,
    shard: int | None,
    reason: str,
    *,
    claimed: bool = False,
) -> Refusal:
    """Warn that a shard document was dropped and return the refusal."""
    _warning(f"dropped shard durations {path}: {reason}")
    return Refusal(shard, path.parent.name, reason, claimed)


def _shard_of(document: object, shard_total: int) -> int | None:
    """Return the in-range shard index a refused document names, if any."""
    index = document.get("shard_index") if isinstance(document, dict) else None
    if isinstance(index, int) and _is_count(index) and index < shard_total:
        return index
    return None


def _read_document(path: Path) -> object:
    """Parse a shard document of at most :data:`MAX_SHARD_DOCUMENT_BYTES`.

    The document comes from another job's artifact, so only a regular file
    is opened: a FIFO would block the merge until the step timed out, and a
    symlink could point anywhere.

    Raises:
        DurationsError: The document is not a regular file, or is larger.
    """
    if path.is_symlink() or not path.is_file():
        raise DurationsError("the document is not a regular file")
    with path.open("rb") as handle:
        data = handle.read(MAX_SHARD_DOCUMENT_BYTES + 1)
    if len(data) > MAX_SHARD_DOCUMENT_BYTES:
        raise DurationsError("the document is too large to read")
    return json.loads(data.decode("utf-8", errors="replace"))


def _read_candidates(
    root: Path,
    identity: RunIdentity,
    shard_total: int,
    expected: set[str],
) -> tuple[list[tuple[Path, dict[str, Any]]], list[Refusal]]:
    """Read and check every shard document under ``root``, one at a time.

    Args:
        root: Directory of the downloaded shard artifacts.
        identity: The run the merge was asked for.
        shard_total: The run's shard count.
        expected: The run's test files.

    Returns:
        The valid documents with their paths, and the refused ones.
    """
    candidates: list[tuple[Path, dict[str, Any]]] = []
    refusals: list[Refusal] = []
    for path in sorted(root.rglob(SHARD_FILE_NAME)) if root.is_dir() else []:
        raw: object = None
        try:
            raw = _read_document(path)
            checked = validate_shard_document(raw, identity, shard_total, expected)
            candidates.append((path, checked))
        # RecursionError: JSON nested deeper than the parser's stack. This
        # input comes from another job, so it drops only this document.
        except (OSError, ValueError, RecursionError, DurationsError) as error:
            claim = _shard_of(raw, shard_total)
            refusals.append(_refuse(path, claim, str(error), claimed=True))
    return candidates, refusals


def _latest_per_shard(
    candidates: Sequence[tuple[Path, dict[str, Any]]],
) -> tuple[list[tuple[Path, dict[str, Any]]], list[Refusal]]:
    """Keep each shard's document of the latest attempt.

    An earlier attempt's document is dropped with a notice. Two documents
    for one shard in its latest attempt are both refused with a warning:
    neither copy can be trusted.

    Args:
        candidates: Valid documents with their paths.

    Returns:
        One document per shard index at most, and the refused ones.
    """
    by_index: dict[int, list[tuple[Path, dict[str, Any]]]] = defaultdict(list)
    for path, document in candidates:
        by_index[document["shard_index"]].append((path, document))
    kept: list[tuple[Path, dict[str, Any]]] = []
    refusals: list[Refusal] = []
    for index, group in sorted(by_index.items()):
        latest = max(document["run_attempt"] for _path, document in group)
        best = [entry for entry in group if entry[1]["run_attempt"] == latest]
        for path, document in group:
            if len(best) > 1:
                reason = f"it appears twice in attempt {latest}"
                refusals.append(_refuse(path, index, reason))
            elif document["run_attempt"] != latest:
                _notice(
                    f"dropped shard durations {path}: attempt "
                    f"{document['run_attempt']} of shard {index} is superseded "
                    f"by attempt {latest}",
                )
            else:
                kept.append((path, document))
    return kept, refusals


def load_shard_documents(
    root: Path,
    identity: RunIdentity,
    shard_total: int,
    expected: set[str],
) -> tuple[list[dict[str, Any]], list[Refusal]]:
    """Read, check and select the shard documents under ``root``.

    A document is refused with a warning when it is unreadable, invalid,
    from another commit, run or later attempt, names a file that is not one
    of ``expected``, when its shard index appears twice in the same attempt,
    or when one of its files also appears in another kept document. An
    earlier attempt's document for a shard that a later attempt also
    reported is dropped with a notice (not a refusal).

    Args:
        root: Directory of the downloaded shard artifacts.
        identity: The run the merge was asked for.
        shard_total: The run's shard count.
        expected: The run's test files.

    Returns:
        The kept documents sorted by shard index, and the refused ones.
    """
    candidates, refusals = _read_candidates(root, identity, shard_total, expected)
    latest, duplicates = _latest_per_shard(candidates)
    refusals += duplicates
    owners = Counter(name for _path, doc in latest for name in doc["test_counts"])
    kept: list[dict[str, Any]] = []
    for path, document in latest:
        shared = sorted(n for n in document["test_counts"] if owners[n] > 1)
        if not shared:
            kept.append(document)
            continue
        reason = f"{shared[0]} is reported by more than one shard"
        refusals.append(_refuse(path, document["shard_index"], reason))
    return sorted(kept, key=lambda doc: doc["shard_index"]), refusals


def expected_files(test_root: Path, prefix: str, test_path: str) -> set[str]:
    """List the repo-relative ``.bats`` files the run was asked to cover.

    Mirrors ``run-coverage``: a file ``test_path`` is the only file, a
    directory contributes every ``*.bats`` below it that is a regular file.
    Like its ``find -type f``, a symlink (to a file or a directory) is not
    followed or listed: bats never runs it, so it is not expected.

    Args:
        test_root: The working directory on disk.
        prefix: The working directory relative to the repo root.
        test_path: ``test-path`` relative to the working directory.

    Returns:
        Repo-relative paths.

    Raises:
        DurationsError: ``test_path`` does not exist, or it or ``prefix``
            leads outside the repository (an absolute path or ``..``).
    """
    target = test_root / test_path
    if target.is_file():
        return _inside_repo({repo_path(test_path, prefix)})
    if not target.is_dir():
        raise DurationsError(f"test path {test_path} not found under {test_root}")
    found: set[str] = set()
    for directory, _subdirs, names in os.walk(target):
        for name in names:
            candidate = Path(directory) / name
            if not name.endswith(".bats") or candidate.is_symlink():
                continue
            if candidate.is_file():
                relative = candidate.relative_to(test_root).as_posix()
                found.add(repo_path(relative, prefix))
    return _inside_repo(found)


def _inside_repo(paths: set[str]) -> set[str]:
    """Return ``paths`` when each is a normal path inside the repository.

    A shard document's paths are accepted when they are in this set, so the
    set itself must hold only repo-relative paths: an absolute ``test-path``
    or prefix, or one with ``..``, would otherwise let such a path through.

    Raises:
        DurationsError: A path is absolute, has ``..``, is not normalized
            or contains a NUL.
    """
    for path in sorted(paths):
        # With "/" appended, an empty path and ".." fail the prefix test too.
        outside = f"{path}/".startswith(("/", "../"))
        if outside or "\0" in path or path != posixpath.normpath(path):
            raise DurationsError(f"test file {path!r} is not inside the repository")
    return paths


def merge_documents(
    documents: Sequence[Mapping[str, Any]],
    unaccounted: Iterable[str],
) -> dict[str, Any]:
    """Merge checked shard documents (no index or file twice).

    Args:
        documents: Kept shard documents, sorted by shard index.
        unaccounted: The run's test files: each one no kept document times
            is listed as missing.

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


def _plain(text: str) -> str:
    """Make a reason safe as one Markdown list item of the job summary.

    A reason can quote a shard document, which another job wrote: control
    characters become spaces, it is cut to a bounded length, and HTML and
    Markdown syntax are escaped so it renders as the text it is.
    """
    text = "".join(char if char.isprintable() else " " for char in text)
    if len(text) > _SUMMARY_REASON_CHARS:
        text = text[: _SUMMARY_REASON_CHARS - 3] + "..."
    text = _MARKDOWN.sub(r"\\\1", html.escape(text, quote=False))
    # GitHub also links bare URLs and @names: break them with entities.
    for bare, entity in (("@", "&#64;"), ("://", "&#58;//"), ("www.", "www&#46;")):
        text = text.replace(bare, entity)
    return text


def summary_lines(
    refusals: Sequence[Refusal],
    absent: Iterable[int],
    shard_total: int,
) -> list[str]:
    """Say, in plain words, which shards the merge could not use and why.

    Args:
        refusals: The refused shard documents.
        absent: Shard indexes with no kept document.
        shard_total: The run's shard count.

    Returns:
        One line per refused document, then one per absent shard that no
        refusal explains (its shard job recorded nothing).
    """
    lines: list[str] = []
    explained: set[int] = set()
    for refusal in refusals:
        if refusal.shard is None:
            who = f"A durations file in {_plain(refusal.source)}"
        elif refusal.claimed:
            # The index is the refused document's own word, not a checked one.
            who = (
                f"A durations file in {_plain(refusal.source)} (it claims "
                f"shard {refusal.shard}/{shard_total})"
            )
            explained.add(refusal.shard)
        else:
            who = f"Shard {refusal.shard}/{shard_total}"
            explained.add(refusal.shard)
        lines.append(f"{who} was refused: {_plain(refusal.reason)}.")
    if len(lines) > _SUMMARY_MAX_REFUSALS:
        more = len(lines) - _SUMMARY_MAX_REFUSALS
        lines = lines[:_SUMMARY_MAX_REFUSALS]
        lines.append(f"{more} more refused file(s) are not listed; see the warnings.")
    for index in absent:
        if index not in explained:
            lines.append(
                f"Shard {index}/{shard_total} sent no durations: its step "
                '"Record shard BATS durations" refused the data or did not '
                "run, and that step's warning says why.",
            )
    return lines


def _write_summary(lines: Sequence[str]) -> None:
    """Append the lines to the job summary, when the runner provides one.

    Args:
        lines: Lines of :func:`summary_lines` or a closing remark; nothing
            is written for none. A summary that cannot be written is
            skipped: it must not undo a published file.
    """
    target = os.environ.get("GITHUB_STEP_SUMMARY", "")
    if not lines or not target:
        return
    text = "### BATS durations\n\n" + "".join(f"- {line}\n" for line in lines)
    with contextlib.suppress(OSError), Path(target).open("a", encoding="utf-8") as out:
        out.write(text + "\n")


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
        report = _read_text(tap_path)
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
    try:
        expected = expected_files(Path(args.root), args.path_prefix, args.test_path)
    except DurationsError as error:
        # Without the run's files no path of a shard document can be
        # checked, so nothing is published.
        _warning(f"{error}; nothing to publish")
        _write_summary([f"Nothing was published: {_plain(str(error))}."])
        return
    documents, refusals = load_shard_documents(
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
    lines = summary_lines(refusals, absent, args.shard_total)
    merged = merge_documents(documents, expected)
    if not merged["durations"]:
        _warning("no shard recorded a duration; nothing to publish")
        _write_summary([*lines, "Nothing was published: no shard recorded a duration."])
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
    _write_summary(lines)


def _at_least(minimum: int) -> Callable[[str], int]:
    """Return an argparse type for a decimal integer of at least ``minimum``.

    Args:
        minimum: Smallest accepted value.

    Returns:
        The converter argparse calls with the raw argument.
    """

    def convert(raw: str) -> int:
        """Parse ``raw`` as an integer of at least ``minimum`` (argparse type)."""
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
        # A write cut short leaves no partial file for the upload step.
        with contextlib.suppress(OSError):
            Path(args.output).unlink(missing_ok=True)
        _warning(f"{args.command} failed: {error}; no durations recorded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
