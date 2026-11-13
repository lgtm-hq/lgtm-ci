#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Write generated inline ``run:`` blocks into workflows, or check them (#1450).

Some workflow steps must stay inline because they are workflow-owned: on GHES
the tooling tree is caller-selected, so a step that pins checksums cannot run a
script from it. Each such block has one tested source script, usually under
``scripts/ci/bootstrap/``; this script copies it into every workflow.

In the source script and in each workflow, the generated body sits between two
comment markers::

    # lgtm-ci-inline:begin <id>
    ...
    # lgtm-ci-inline:end <id>

Only the source lines strictly between its markers are copied, so the shebang
and license header stay out of the YAML. In a workflow, the lines between the
markers are replaced by that body, each non-empty line prefixed with the begin
marker's indentation. Everything else in the file is left byte for byte.

Each block declares how many copies the workflows must carry, so a removed
marker pair fails the check like a drifted body does. A begin marker without
its end marker, a stray end marker, a nested marker or an unknown id is an
error.

Usage:
    uv run python scripts/ci/bootstrap/sync_inline_blocks.py          # rewrite
    uv run python scripts/ci/bootstrap/sync_inline_blocks.py --check  # exit 1 on drift

``WORKFLOWS_DIR`` overrides the scanned directory (tests use a scratch copy).
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DEFAULT_WORKFLOWS_DIR = ROOT / ".github" / "workflows"
MARKER = re.compile(
    r"^(?P<indent>[ ]*)# lgtm-ci-inline:(?P<kind>begin|end) (?P<id>\S+)\s*$",
)


@dataclass(frozen=True)
class Block:
    """One generated inline block.

    Attributes:
        script: Source script path relative to the repository root.
        copies: Number of marker pairs the workflows must carry in total.
    """

    script: str
    copies: int


BLOCKS: dict[str, Block] = {
    "install-verified-trivy": Block(
        script="scripts/ci/bootstrap/install-verified-trivy.sh",
        copies=4,
    ),
    "refuse-diverging-tooling-ref": Block(
        script=".github/actions/checkout-and-harden/check-tooling-ref-divergence.sh",
        copies=15,
    ),
    "select-app-credential": Block(
        script="scripts/ci/bootstrap/select-app-credential.sh",
        copies=5,
    ),
    "verify-extract-hook-tooling": Block(
        script="scripts/ci/bootstrap/verify-extract-hook-tooling.sh",
        copies=2,
    ),
}


class MarkerError(ValueError):
    """A marker is unpaired, nested, unknown or otherwise malformed."""


def source_body(block_id: str, root: Path = ROOT) -> list[str]:
    """Return the source lines between one block's markers.

    Args:
        block_id: Key in :data:`BLOCKS`.
        root: Repository root the script path is relative to.

    Returns:
        The body lines without their line endings.

    Raises:
        MarkerError: When the source lacks exactly one marker pair for the id.
    """
    path = root / BLOCKS[block_id].script
    lines = path.read_text(encoding="utf-8").splitlines()
    begins = [i for i, line in enumerate(lines) if _marker(line) == ("begin", block_id)]
    ends = [i for i, line in enumerate(lines) if _marker(line) == ("end", block_id)]
    if len(begins) != 1 or len(ends) != 1 or begins[0] > ends[0]:
        raise MarkerError(
            f"{path}: needs exactly one begin/end marker pair for {block_id}",
        )
    return lines[begins[0] + 1 : ends[0]]


def _marker(line: str) -> tuple[str, str] | None:
    """Return ``(kind, id)`` when the line is a marker comment."""
    match = MARKER.match(line)
    return (match["kind"], match["id"]) if match else None


def render(text: str, bodies: dict[str, list[str]]) -> tuple[str, dict[str, int]]:
    """Replace every marked block in one workflow with its generated body.

    Args:
        text: Workflow file contents.
        bodies: Generated body lines keyed by block id.

    Returns:
        The rewritten text and the number of marker pairs per block id.

    Raises:
        MarkerError: On an unknown id or an unpaired or nested marker.
    """
    out: list[str] = []
    counts: dict[str, int] = {}
    open_id: str | None = None
    for number, line in enumerate(text.splitlines(keepends=True), start=1):
        match = MARKER.match(line.rstrip("\r\n"))
        if match is None:
            if open_id is None:
                out.append(line)
            continue
        kind, block_id, indent = match["kind"], match["id"], match["indent"]
        if block_id not in bodies:
            raise MarkerError(f"line {number}: unknown inline block id {block_id!r}")
        if kind == "begin":
            if open_id is not None:
                raise MarkerError(
                    f"line {number}: begin {block_id} inside open {open_id}",
                )
            open_id = block_id
            out.append(line)
            newline = line[len(line.rstrip("\r\n")) :] or "\n"
            for body in bodies[block_id]:
                out.append(f"{indent}{body}{newline}" if body else newline)
            continue
        if open_id != block_id:
            raise MarkerError(f"line {number}: end {block_id} without a matching begin")
        open_id = None
        counts[block_id] = counts.get(block_id, 0) + 1
        out.append(line)
    if open_id is not None:
        raise MarkerError(f"begin {open_id} has no end marker")
    return "".join(out), counts


def _report(
    workflows_dir: Path,
    totals: dict[str, int],
    drifted: list[str],
    broken: list[str],
) -> int:
    """Print every problem found by :func:`sync` and return the exit code.

    Args:
        workflows_dir: Scanned directory, named in the copy-count message.
        totals: Marker pairs found per block id.
        drifted: Workflows whose generated copy differs from its source.
        broken: Per-workflow marker errors.

    Returns:
        0 when there is nothing to report, 1 otherwise.
    """
    problems = [f"sync-inline-blocks: {message}" for message in broken]
    if not broken:
        problems.extend(
            f"sync-inline-blocks: expected {block.copies} copies of {block_id}, "
            f"found {totals[block_id]} marker pairs in {workflows_dir}"
            for block_id, block in BLOCKS.items()
            if totals[block_id] != block.copies
        )
    if drifted:
        names = " ".join(drifted)
        problems.append(
            f"sync-inline-blocks: generated block differs from its source in: {names}",
        )
        problems.append("run: uv run python scripts/ci/bootstrap/sync_inline_blocks.py")
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


def sync(workflows_dir: Path, check: bool, root: Path = ROOT) -> int:
    """Rewrite or check every workflow in a directory.

    Args:
        workflows_dir: Directory holding the ``*.yml`` and ``*.yaml`` workflows.
        check: Report drift instead of rewriting files.
        root: Repository root the source scripts are relative to.

    Returns:
        Process exit code: 0 when in sync (or rewritten), 1 otherwise.
    """
    bodies = {block_id: source_body(block_id, root) for block_id in BLOCKS}
    totals = dict.fromkeys(BLOCKS, 0)
    drifted: list[str] = []
    broken: list[str] = []
    workflows = [*workflows_dir.glob("*.yml"), *workflows_dir.glob("*.yaml")]
    for workflow in sorted(workflows):
        # Bytes, not read_text(): newline translation would hide a CRLF in a
        # copy and rewrite every line outside the markers on sync.
        text = workflow.read_bytes().decode("utf-8")
        try:
            updated, counts = render(text, bodies)
        except MarkerError as error:
            broken.append(f"{workflow.name}: {error}")
            continue
        for block_id, count in counts.items():
            totals[block_id] += count
        if updated == text:
            continue
        if check:
            drifted.append(workflow.name)
        else:
            workflow.write_bytes(updated.encode("utf-8"))
            print(f"updated {workflow.name}")
    return _report(workflows_dir, totals, drifted, broken)


def main(argv: Sequence[str] | None = None) -> int:
    """Parse arguments and run the sync.

    Args:
        argv: Command-line arguments, defaulting to ``sys.argv[1:]``.

    Returns:
        Process exit code.
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="exit 1 on drift")
    args = parser.parse_args(argv)
    workflows_dir = Path(os.environ.get("WORKFLOWS_DIR") or DEFAULT_WORKFLOWS_DIR)
    return sync(workflows_dir, check=args.check)


if __name__ == "__main__":
    sys.exit(main())
