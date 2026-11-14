#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Shard completion manifests for sharded kcov BATS runs (#1531).

A cancelled or timed-out shard of ``reusable-test-shell.yml`` still uploads
its partial TAP and Cobertura output (the uploads run under ``always()``).
Merged as if complete, those partial reports published a coverage
percentage and a test total for a run that never finished. A shard therefore
proves it finished by writing ``shard-complete.json`` into its coverage
directory, and the aggregate publishes a percentage or a total only when
every expected shard has one.

The gate is GitHub's own step state, not the TAP stream. Under kcov the
stream also carries xtrace output and nested TAP from tests that run bats
themselves (lines like ``ok 1 mocked == *--allow-empty-suite* ]]``), and
Bats records no interruption, so no TAP-based rule can prove a run
finished. The workflow runs ``write`` in its own step only when
``!cancelled()``, the coverage step wrote an ``exit-code`` output other
than ``124``, and it did not write ``interrupted=true``. The coverage step
writes ``exit-code`` only at its end, after kcov returns (test failures
included); a cancel or a job timeout stops it first, and ``timeout(1)``
reports 124. A step timeout signals the script while kcov may still return
(even with exit 0), so its INT/TERM trap writes ``interrupted=true``.

``write`` writes the manifest only when:

- the exit code is below 124 (not a ``timeout(1)`` expiry or failure, 124-127,
  and not a signal, 128 and above). A test failure (exit 1) still counts;
- a Cobertura report exists in the coverage directory, or the shard is empty
  (``EMPTY_SHARD`` marker).

The manifest records the run that wrote it: ``GITHUB_RUN_ID``,
``GITHUB_RUN_ATTEMPT`` and ``GITHUB_SHA``.

``check`` (run on the aggregate) lists the expected shard indexes that have
no valid manifest under the downloaded coverage artifacts. It prints the
incomplete reason on stdout and exits 1 when any is missing. It needs a
non-empty ``--run-id`` and ``--sha`` (exit 2 otherwise): without them any
run's manifests would pass. A manifest from
another run ID or commit counts as missing.

``check --download-outcome`` takes the final outcome of the workflow's
download of the coverage artifacts (``steps.<id>.outcome`` after its bounded
retries, #1562). Any outcome other than ``success`` (or empty, when the
caller passes none) means the artifacts were never fully downloaded, so a
missing manifest says nothing about the shard. ``check`` then reports the
download failure for ``--artifact-pattern`` and exits 1, even when every
manifest is present (the download may be partial). "Did not finish" is
reserved for artifacts that were downloaded and carry no manifest.

Accepted residual: a manifest from an earlier attempt of the same run (same
run ID and SHA) is accepted on purpose. It proves that shard once finished
at this commit, so its coverage is genuine. If a later rerun of that same
shard is cancelled or times out, the earlier manifest may still be found,
but the shard job of this attempt fails and so does the required check.
Rejecting earlier attempts would mark coverage incomplete on every "Re-run
failed jobs", because passing shards keep their earlier artifacts.

Usage:
    python3 scripts/ci/actions/shard-completion.py write \\
        --coverage-dir coverage-report \\
        --shard-index 3 --shard-total 8 --exit-code 0 \\
        --run-id "$GITHUB_RUN_ID" --run-attempt "$GITHUB_RUN_ATTEMPT" \\
        --sha "$GITHUB_SHA"
    python3 scripts/ci/actions/shard-completion.py check \\
        --dir "$RUNNER_TEMP/shard-coverage" --expected 8 \\
        --run-id "$GITHUB_RUN_ID" --sha "$GITHUB_SHA" \\
        --download-outcome success --artifact-pattern "p-coverage-*-shard-*"
"""

# pylint: disable=invalid-name  # hyphenated CLI filename is the contract

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import TypeGuard

MANIFEST_NAME = "shard-complete.json"
MANIFEST_SCHEMA = "lgtm-ci.shard-complete.v1"
EMPTY_MARKER = "EMPTY_SHARD"
# GNU timeout: 124 expired, 125-127 its own failure; 128+N killed by signal N.
FIRST_ABNORMAL_EXIT = 124

_COVERAGE_TAG = re.compile(r"<(?:[\w.-]+:)?coverage\b([^>]*)>", flags=re.IGNORECASE)
_ATTR = re.compile(r'([\w:.-]+)\s*=\s*"([^"]*)"')


class IncompleteShardError(Exception):
    """The shard did not finish, so no completion manifest is written."""


@dataclass(frozen=True)
class RunIdentity:
    """The workflow run a manifest belongs to (empty strings when unknown).

    Attributes:
        run_id: ``GITHUB_RUN_ID``.
        run_attempt: ``GITHUB_RUN_ATTEMPT``; recorded, never compared.
        sha: ``GITHUB_SHA``.
    """

    run_id: str = ""
    run_attempt: str = ""
    sha: str = ""


@dataclass(frozen=True)
class ShardRef:
    """One shard of a sharded run.

    Attributes:
        index: Zero-based shard index.
        total: Number of shards.
    """

    index: int
    total: int


def find_cobertura(coverage_dir: Path) -> Path | None:
    """Return the shard's Cobertura report, in the merge step's search order.

    Args:
        coverage_dir: The kcov output directory.

    Returns:
        ``cov.xml``, ``kcov-merged/cov.xml`` or ``cobertura.xml`` at the top,
        else the first ``cov.xml`` then ``cobertura.xml`` below it, or
        ``None``.
    """
    for relative in ("cov.xml", "kcov-merged/cov.xml", "cobertura.xml"):
        candidate = coverage_dir / relative
        if candidate.is_file():
            return candidate
    for name in ("cov.xml", "cobertura.xml"):
        found = sorted(path for path in coverage_dir.rglob(name) if path.is_file())
        if found:
            return found[0]
    return None


def cobertura_lines(path: Path) -> tuple[int, int]:
    """Read ``lines-covered`` and ``lines-valid`` from a Cobertura root tag.

    Args:
        path: Cobertura XML file.

    Returns:
        ``(covered, valid)``.

    Raises:
        IncompleteShardError: When the root tag or either count is missing,
            as in a report kcov did not finish writing.
    """
    text = path.read_text(encoding="utf-8", errors="replace")
    tag = _COVERAGE_TAG.search(text)
    attrs = dict(_ATTR.findall(tag.group(1))) if tag else {}
    covered = attrs.get("lines-covered", "")
    valid = attrs.get("lines-valid", "")
    if not (covered.isdigit() and valid.isdigit()):
        raise IncompleteShardError(f"{path} has no lines-covered/lines-valid counts")
    return int(covered), int(valid)


def build_manifest(
    *,
    coverage_dir: Path,
    shard: ShardRef,
    exit_code: int,
    run: RunIdentity,
) -> dict[str, object]:
    """Return the manifest for a finished shard.

    Args:
        coverage_dir: The shard's kcov output directory.
        shard: The shard's index and the shard count.
        exit_code: kcov/bats exit code the coverage step reported.
        run: The workflow run writing the manifest.

    Returns:
        The manifest document.

    Raises:
        IncompleteShardError: When the shard did not finish (see module doc).
    """
    if exit_code >= FIRST_ABNORMAL_EXIT:
        raise IncompleteShardError(
            f"kcov/bats exited {exit_code} (timed out or killed)",
        )
    report = find_cobertura(coverage_dir)
    empty = report is None and (coverage_dir / EMPTY_MARKER).is_file()
    if report is None and not empty:
        raise IncompleteShardError(f"no Cobertura report under {coverage_dir}")
    covered, valid = (0, 0) if report is None else cobertura_lines(report)
    return {
        "schema": MANIFEST_SCHEMA,
        "shard_index": shard.index,
        "shard_total": shard.total,
        "lines_covered": covered,
        "lines_valid": valid,
        "empty": empty,
        "exit_code": exit_code,
        "run_id": run.run_id,
        "run_attempt": run.run_attempt,
        "sha": run.sha,
    }


def write_manifest(
    *,
    coverage_dir: Path,
    shard: ShardRef,
    exit_code: int,
    run: RunIdentity,
) -> Path:
    """Write ``shard-complete.json`` into ``coverage_dir`` for a finished shard.

    Args:
        coverage_dir: The shard's kcov output directory (uploaded as its
            coverage artifact).
        shard: The shard's index and the shard count.
        exit_code: kcov/bats exit code the coverage step reported.
        run: The workflow run writing the manifest.

    Returns:
        The manifest path.

    Raises:
        IncompleteShardError: When the shard did not finish; nothing is
            written and any stale manifest is removed.
    """
    target = coverage_dir / MANIFEST_NAME
    target.unlink(missing_ok=True)
    manifest = build_manifest(
        coverage_dir=coverage_dir,
        shard=shard,
        exit_code=exit_code,
        run=run,
    )
    target.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return target


def _manifest_index(path: Path, expected: int, run: RunIdentity) -> int | None:
    """Return the shard index a manifest vouches for, or ``None`` if invalid.

    Args:
        path: A ``shard-complete.json`` file.
        expected: Number of shards the aggregate expects.
        run: The aggregate's run; a non-empty ``run_id`` / ``sha`` must match.
            ``run_attempt`` is not compared (see module doc).

    Returns:
        The index when the manifest parses, carries this schema, comes from
        this run and commit, and names an index in ``range(expected)`` of a
        run with ``expected`` shards.
    """
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("schema") != MANIFEST_SCHEMA:
        return None
    if run.run_id and data.get("run_id") != run.run_id:
        return None
    if run.sha and data.get("sha") != run.sha:
        return None
    index = data.get("shard_index")
    total = data.get("shard_total")
    if not (_is_int(index) and _is_int(total)) or total != expected:
        return None
    return index if 0 <= index < expected else None


def _is_int(value: object) -> TypeGuard[int]:
    """Return whether ``value`` is a JSON integer (``bool`` excluded)."""
    return isinstance(value, int) and not isinstance(value, bool)


def missing_shards(
    root: Path,
    expected: int,
    run: RunIdentity | None = None,
) -> list[int]:
    """List expected shard indexes with no valid manifest under ``root``.

    Args:
        root: Directory holding the downloaded shard coverage artifacts.
        expected: Number of shards in the run.
        run: The aggregate's run; manifests from another run ID or commit
            count as missing. ``None`` accepts any run.

    Returns:
        Sorted missing indexes; empty when every shard finished.
    """
    found: set[int] = set()
    if root.is_dir():
        for path in sorted(root.rglob(MANIFEST_NAME)):
            index = _manifest_index(path, expected, run or RunIdentity())
            if index is not None:
                found.add(index)
    return [index for index in range(expected) if index not in found]


def incomplete_reason(missing: list[int]) -> str:
    """Return the one-line reason published for an incomplete run.

    Args:
        missing: Shard indexes with no completion manifest.

    Returns:
        For example ``incomplete coverage: shard(s) 3, 4 did not finish
        (cancelled or timed out; no completion manifest)``.
    """
    shards = ", ".join(str(index) for index in missing)
    tail = "did not finish (cancelled or timed out; no completion manifest)"
    return f"incomplete coverage: shard(s) {shards} {tail}"


def download_failed(outcome: str) -> bool:
    """Return whether a download step's final outcome means it failed.

    Args:
        outcome: ``steps.<id>.outcome`` of the download, after its retries;
            empty when the caller passes none.

    Returns:
        ``True`` for any outcome other than ``success`` or empty
        (``failure``, ``cancelled``, ``skipped``).
    """
    return outcome not in ("", "success")


def download_failure_reason(pattern: str, outcome: str, missing: list[int]) -> str:
    """Return the one-line reason published when the download failed.

    Args:
        pattern: The artifact name pattern the download fetched.
        outcome: The download's final outcome.
        missing: Shard indexes with no manifest in what was downloaded.

    Returns:
        For example ``incomplete coverage: artifact download failed for
        p-coverage-* (download outcome 'failure' after retries; the error
        is in the download step logs); shard(s) 2 unverified``.
    """
    target = pattern or "the shard coverage artifacts"
    where = "the error is in the download step logs"
    detail = f"download outcome '{outcome}' after retries; {where}"
    reason = f"incomplete coverage: artifact download failed for {target} ({detail})"
    if missing:
        shards = ", ".join(str(index) for index in missing)
        reason += f"; shard(s) {shards} unverified"
    return reason


def _write_command(args: argparse.Namespace) -> int:
    """Run ``write``; 0 when the manifest was written, 1 when not."""
    label = f"shard {args.shard_index}/{args.shard_total}"
    try:
        path = write_manifest(
            coverage_dir=Path(args.coverage_dir),
            shard=ShardRef(index=args.shard_index, total=args.shard_total),
            exit_code=args.exit_code,
            run=_run_identity(args),
        )
    except IncompleteShardError as exc:
        print(f"::warning::{label} did not finish; no completion manifest: {exc}")
        return 1
    except OSError as exc:
        print(f"::warning::{label}: cannot write completion manifest: {exc}")
        return 1
    print(f"shard-complete {label} manifest={path}")
    return 0


def _check_command(args: argparse.Namespace) -> int:
    """Run ``check``; 0 when every shard finished, 1 with the reason if not."""
    missing = missing_shards(Path(args.dir), args.expected, _run_identity(args))
    if download_failed(args.download_outcome):
        print(
            download_failure_reason(
                args.artifact_pattern,
                args.download_outcome,
                missing,
            ),
        )
        return 1
    if missing:
        print(incomplete_reason(missing))
        return 1
    print(f"shard-complete all {args.expected} shard(s) finished", file=sys.stderr)
    return 0


def _run_identity(args: argparse.Namespace) -> RunIdentity:
    """Build the run identity from the ``--run-*`` / ``--sha`` arguments."""
    return RunIdentity(
        run_id=args.run_id,
        run_attempt=getattr(args, "run_attempt", ""),
        sha=args.sha,
    )


def _non_negative(raw: str) -> int:
    """Parse a non-negative integer argument."""
    if not raw.isdigit():
        raise argparse.ArgumentTypeError(f"expected a non-negative integer: {raw}")
    return int(raw)


def _positive(raw: str) -> int:
    """Parse a positive integer argument."""
    value = _non_negative(raw)
    if value == 0:
        raise argparse.ArgumentTypeError("expected a positive integer: 0")
    return value


def main(argv: list[str] | None = None) -> int:
    """Dispatch the ``write`` / ``check`` subcommands.

    Args:
        argv: Optional argument vector (defaults to ``sys.argv[1:]``).

    Returns:
        Process exit code: 0 complete, 1 incomplete, 2 usage error.
    """
    parser = argparse.ArgumentParser(
        description="Write or check sharded kcov completion manifests.",
        epilog="See lgtm-ci#1531.",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    write = commands.add_parser("write", help="Write this shard's manifest.")
    write.add_argument("--coverage-dir", required=True)
    write.add_argument("--shard-index", required=True, type=_non_negative)
    write.add_argument("--shard-total", required=True, type=_positive)
    write.add_argument("--exit-code", required=True, type=_non_negative)
    write.add_argument("--run-attempt", default="")
    check = commands.add_parser("check", help="List shards with no manifest.")
    check.add_argument("--dir", required=True)
    check.add_argument("--expected", required=True, type=_positive)
    check.add_argument(
        "--download-outcome",
        default="",
        help="Final steps.<id>.outcome of the coverage download (#1562).",
    )
    check.add_argument(
        "--artifact-pattern",
        default="",
        help="Artifact name pattern the coverage download fetched.",
    )
    for command in (write, check):
        command.add_argument("--run-id", default="")
        command.add_argument("--sha", default="")
    args = parser.parse_args(argv)
    if args.command == "check" and not (args.run_id and args.sha):
        # Fail closed: without this run's identity every manifest from any
        # run or commit would be accepted (exit 2, a usage error).
        check.error(
            "--run-id and --sha are required and must be non-empty "
            "(GITHUB_RUN_ID / GITHUB_SHA); refusing to accept manifests "
            "from any run or commit",
        )
    if args.command == "write":
        return _write_command(args)
    return _check_command(args)


if __name__ == "__main__":
    sys.exit(main())
