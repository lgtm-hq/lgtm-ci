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

``write`` (run on the shard after kcov returns) writes the manifest only
when:

- kcov/bats exited normally: not a timeout (124), a ``timeout(1)`` failure
  (125-127) or a signal (128 and above). A test failure (exit 1) still
  counts, since every test ran;
- the outer TAP plan finished (the same rule as ``scripts/ci/lib/testing/
  parse/tap.sh``, checked against Bats 1.14 output):

  - hook lines (``not ok K setup_file failed``, ``not ok K teardown_file
    failed``) are failures but never count toward the ``N`` planned tests;
  - any ``# Received SIG...`` line (bats prints ``# Received SIGINT,
    aborting ...``) makes the run incomplete, whatever else it says;
  - otherwise exactly ``N`` test results finish the plan, and any
    shortfall is incomplete. This fails closed on purpose: a real
    ``setup_file`` failure (bats skips the rest of that file) leaves the same
    stream as a ``bats-exec-file`` killed by SIGTERM (no marker, the same
    ``Executed X instead of expected N tests`` warning, bats exit 1), so it
    writes no manifest and the aggregate reports the run incomplete (status
    error, no coverage) instead of failed. The job fails either way;
- a Cobertura report exists in the coverage directory, or the shard is empty
  (``EMPTY_SHARD`` marker and a ``1..0`` plan).

The manifest records the run that wrote it: ``GITHUB_RUN_ID``,
``GITHUB_RUN_ATTEMPT`` and ``GITHUB_SHA``.

``check`` (run on the aggregate) lists the expected shard indexes that have
no valid manifest under the downloaded coverage artifacts. It prints the
incomplete reason on stdout and exits 1 when any is missing. A manifest from
another run ID or commit counts as missing. An earlier attempt of the same
run is accepted on purpose: "Re-run failed jobs" keeps the passing shards'
artifacts from the earlier attempt, and a shard that finished at the same
commit is true coverage for that commit.

Usage:
    python3 scripts/ci/actions/shard-completion.py write \\
        --coverage-dir coverage-report --tap bats-output.tap \\
        --shard-index 3 --shard-total 8 --exit-code 0 \\
        --run-id "$GITHUB_RUN_ID" --run-attempt "$GITHUB_RUN_ATTEMPT" \\
        --sha "$GITHUB_SHA"
    python3 scripts/ci/actions/shard-completion.py check \\
        --dir "$RUNNER_TEMP/shard-coverage" --expected 8 \\
        --run-id "$GITHUB_RUN_ID" --sha "$GITHUB_SHA"
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

_PLAN = re.compile(r"^1\.\.(\d+)\s*$")
_OK = re.compile(r"^ok \d+")
_NOT_OK = re.compile(r"^not ok \d+")
_HOOK_FAILED = re.compile(r"^not ok \d+ ([A-Za-z_]+_file) failed")
_INTERRUPTED = re.compile(r"^# Received SIG")
_SKIP = re.compile(r"#\s*skip", flags=re.IGNORECASE)
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
class TapSummary:
    """Counts from one TAP stream and its outer plan.

    Attributes:
        planned: ``N`` of the first ``1..N`` line, or ``None`` without one.
        passed: ``ok`` results without a skip directive.
        failed: ``not ok`` results, hook failures included.
        skipped: ``ok`` results with a ``# skip`` directive.
        hooks: Names from ``not ok K <hook>_file failed`` lines (not tests).
        interrupted: A ``# Received SIG...`` line was seen.
    """

    planned: int | None
    passed: int
    failed: int
    skipped: int
    hooks: tuple[str, ...] = ()
    interrupted: bool = False

    @property
    def results(self) -> int:
        """Return the number of result lines seen, hook lines included."""
        return self.passed + self.failed + self.skipped

    @property
    def tests(self) -> int:
        """Return the number of test results (hook lines excluded)."""
        return self.results - len(self.hooks)

    @property
    def complete(self) -> bool:
        """Return whether exactly the planned tests reported, uninterrupted."""
        uninterrupted = self.planned is not None and not self.interrupted
        return uninterrupted and self.tests == self.planned

    def shortfall(self) -> str:
        """Describe why the plan is not complete (worded like ``tap.sh``)."""
        if self.planned is None:
            return "no 1..N plan"
        planned = f"{self.tests} of {self.planned} planned tests"
        if self.interrupted:
            return f"{planned} have a result (interrupted)"
        if self.tests < self.planned:
            return (
                f"{self.planned - self.tests} of {self.planned} planned tests "
                "have no result (a setup_file/hook failure or an interruption)"
            )
        return f"{self.tests} test results for {self.planned} planned tests"


def parse_tap(text: str) -> TapSummary:
    """Count results in a TAP stream and read its outer plan.

    Args:
        text: TAP output (``bats --tap``).

    Returns:
        The summary. Only the first ``1..N`` line is the plan; indented or
        commented ``ok`` lines (test output) are not results.
    """
    planned: int | None = None
    passed = failed = skipped = 0
    hooks: list[str] = []
    interrupted = False
    for line in text.splitlines():
        plan = _PLAN.match(line)
        if planned is None and plan:
            planned = int(plan.group(1))
        elif _OK.match(line):
            if _SKIP.search(line):
                skipped += 1
            else:
                passed += 1
        elif _NOT_OK.match(line):
            failed += 1
            hook = _HOOK_FAILED.match(line)
            if hook:
                hooks.append(hook.group(1))
        elif _INTERRUPTED.match(line):
            interrupted = True
    return TapSummary(
        planned=planned,
        passed=passed,
        failed=failed,
        skipped=skipped,
        hooks=tuple(hooks),
        interrupted=interrupted,
    )


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


def build_manifest(  # pylint: disable=too-many-arguments  # keyword-only
    *,
    coverage_dir: Path,
    tap_path: Path,
    shard_index: int,
    shard_total: int,
    exit_code: int,
    run: RunIdentity,
) -> dict[str, object]:
    """Return the manifest for a finished shard.

    Args:
        coverage_dir: The shard's kcov output directory.
        tap_path: The shard's ``bats-output.tap``.
        shard_index: Zero-based shard index.
        shard_total: Number of shards.
        exit_code: kcov/bats exit code of the run.
        run: The workflow run writing the manifest.

    Returns:
        The manifest document.

    Raises:
        IncompleteShardError: When the shard did not finish (see module doc).
    """
    if exit_code >= FIRST_ABNORMAL_EXIT:
        raise IncompleteShardError(
            f"kcov/bats exited {exit_code} (timed out, killed or cancelled)",
        )
    if not tap_path.is_file():
        raise IncompleteShardError(f"no TAP output at {tap_path}")
    tap = parse_tap(tap_path.read_text(encoding="utf-8", errors="replace"))
    if not tap.complete:
        raise IncompleteShardError(f"TAP did not finish: {tap.shortfall()}")
    report = find_cobertura(coverage_dir)
    empty = report is None and (coverage_dir / EMPTY_MARKER).is_file()
    if report is None and not (empty and tap.planned == 0):
        raise IncompleteShardError(f"no Cobertura report under {coverage_dir}")
    covered, valid = (0, 0) if report is None else cobertura_lines(report)
    return {
        "schema": MANIFEST_SCHEMA,
        "shard_index": shard_index,
        "shard_total": shard_total,
        "plan": tap.planned,
        "counts": {
            "passed": tap.passed,
            "failed": tap.failed,
            "skipped": tap.skipped,
            "total": tap.results,
        },
        "lines_covered": covered,
        "lines_valid": valid,
        "empty": empty,
        "exit_code": exit_code,
        "run_id": run.run_id,
        "run_attempt": run.run_attempt,
        "sha": run.sha,
    }


def write_manifest(  # pylint: disable=too-many-arguments  # keyword-only
    *,
    coverage_dir: Path,
    tap_path: Path,
    shard_index: int,
    shard_total: int,
    exit_code: int,
    run: RunIdentity,
) -> Path:
    """Write ``shard-complete.json`` into ``coverage_dir`` for a finished shard.

    Args:
        coverage_dir: The shard's kcov output directory (uploaded as its
            coverage artifact).
        tap_path: The shard's ``bats-output.tap``.
        shard_index: Zero-based shard index.
        shard_total: Number of shards.
        exit_code: kcov/bats exit code of the run.
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
        tap_path=tap_path,
        shard_index=shard_index,
        shard_total=shard_total,
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


def _shard_tap(tap_dir: Path, index: int) -> Path | None:
    """Return shard ``index``'s downloaded ``bats-output.tap``, if any.

    Args:
        tap_dir: Directory of ``<prefix>-test-results-<marker>-shard-N``
            artifact folders.
        index: Shard index.

    Returns:
        The TAP path, or ``None`` when that shard uploaded none.
    """
    for folder in sorted(tap_dir.glob(f"*-shard-{index}")):
        tap = folder / "bats-output.tap"
        if tap.is_file():
            return tap
    return None


def _shard_detail(tap_dir: Path, index: int) -> str:
    """Return what shard ``index``'s TAP says about its shortfall."""
    tap_path = _shard_tap(tap_dir, index)
    if tap_path is None:
        return f"shard {index}: no TAP output"
    tap = parse_tap(tap_path.read_text(encoding="utf-8", errors="replace"))
    if tap.complete:
        return (
            f"shard {index}: all {tap.planned} planned tests have a result, but "
            "no completion manifest (killed, timed out or no coverage report)"
        )
    return f"shard {index}: {tap.shortfall()}"


def incomplete_reason(missing: list[int], tap_dir: Path | None = None) -> str:
    """Return the one-line reason published for an incomplete run.

    Args:
        missing: Shard indexes with no completion manifest.
        tap_dir: Downloaded shard TAP artifacts; when given, each missing
            shard's counts are named.

    Returns:
        For example ``incomplete coverage: shard(s) 3 did not finish: shard
        3: 2 of 4 planned tests have no result (a setup_file/hook failure or
        an interruption)``. It never claims a cause the aggregate cannot see:
        a hook failure, a cancel, a kill and a lost upload can look alike.
    """
    shards = ", ".join(str(index) for index in missing)
    head = f"incomplete coverage: shard(s) {shards} did not finish"
    if tap_dir is None:
        return (
            f"{head} (no completion manifest: a setup_file/hook failure, "
            "an interruption or a lost upload)"
        )
    details = "; ".join(_shard_detail(tap_dir, index) for index in missing)
    return f"{head}: {details}"


def _write_command(args: argparse.Namespace) -> int:
    """Run ``write``; 0 when the manifest was written, 1 when not."""
    label = f"shard {args.shard_index}/{args.shard_total}"
    try:
        path = write_manifest(
            coverage_dir=Path(args.coverage_dir),
            tap_path=Path(args.tap),
            shard_index=args.shard_index,
            shard_total=args.shard_total,
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
    if missing:
        tap_dir = Path(args.tap_dir) if args.tap_dir else None
        print(incomplete_reason(missing, tap_dir))
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
    write.add_argument("--tap", required=True)
    write.add_argument("--shard-index", required=True, type=_non_negative)
    write.add_argument("--shard-total", required=True, type=_positive)
    write.add_argument("--exit-code", required=True, type=_non_negative)
    write.add_argument("--run-attempt", default="")
    check = commands.add_parser("check", help="List shards with no manifest.")
    check.add_argument("--dir", required=True)
    check.add_argument("--expected", required=True, type=_positive)
    check.add_argument("--tap-dir", default="", help="Shard TAP artifacts.")
    for command in (write, check):
        command.add_argument("--run-id", default="")
        command.add_argument("--sha", default="")
    args = parser.parse_args(argv)
    if args.command == "write":
        return _write_command(args)
    return _check_command(args)


if __name__ == "__main__":
    sys.exit(main())
