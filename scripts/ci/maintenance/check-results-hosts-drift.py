#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Compare GitHub's results storage hosts in ``/meta`` with the egress presets.

The egress presets ``github-results``, ``npm-publish`` and ``release-recover``
allow GitHub's Actions results storage accounts by exact host
(``productionresultssa<N>.blob.core.windows.net``), never by wildcard (#1495).
The list lives in ``egress_github_results_storage_endpoints`` in
``scripts/ci/lib/egress/presets.sh``. When GitHub adds a shard, a job routed to
it is blocked by harden-runner until someone adds the host; this script
notices the difference first (#1498).

Inputs:

- the ``GET https://api.github.com/meta`` document, from a file or stdin;
- the expected hosts, read by sourcing ``presets.sh`` and calling
  ``egress_github_results_storage_endpoints`` (never a second copy here).

Only ``productionresultssa<N>.blob.core.windows.net`` entries of
``.domains.actions`` are compared. Other entries, including other
``blob.core.windows.net`` hosts such as the package registry accounts, are
ignored.

Fails closed: a document whose shape is not recognised (no ``domains`` object,
no ``actions`` list, a non-string entry, or no results storage host at all) is
an error, never a match.

Usage:
    gh api meta > /tmp/meta.json
    python3 scripts/ci/maintenance/check-results-hosts-drift.py \
        --meta /tmp/meta.json [--issue-body /tmp/body.md]

    gh api meta | python3 scripts/ci/maintenance/check-results-hosts-drift.py \
        --meta -

Exit codes:
    0 - the hosts in ``/meta`` match the preset list
    1 - they differ; the added and removed hosts are printed (and written as
        a tracking-issue body to ``--issue-body`` when given)
    2 - usage error, unrecognised or undecodable ``/meta``, a preset list that
        could not be read, or any other unexpected error (never 1)
"""

# pylint: disable=invalid-name  # CLI script; hyphenated filename is the invocation contract

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
PRESETS = ROOT / "scripts/ci/lib/egress/presets.sh"
PRESET_FUNCTION = "egress_github_results_storage_endpoints"
ISSUE_MARKER = "<!-- lgtm-ci:results-hosts-drift -->"
RESULTS_HOST = re.compile(r"^productionresultssa(\d+)\.blob\.core\.windows\.net$")
PRESET_ENTRY = re.compile(r"^(productionresultssa\d+\.blob\.core\.windows\.net):443$")

EXIT_MATCH = 0
EXIT_DRIFT = 1
EXIT_ERROR = 2


class DriftCheckError(Exception):
    """Raised when an input cannot be trusted; the check fails closed."""


@dataclass(frozen=True)
class Drift:
    """The difference between ``/meta`` and the preset list.

    Attributes:
        added: Hosts ``/meta`` lists that the preset does not, in shard order.
        removed: Hosts the preset lists that ``/meta`` does not, in shard order.
    """

    added: tuple[str, ...]
    removed: tuple[str, ...]

    @property
    def matches(self) -> bool:
        """Return True when the two lists are equal."""
        return not self.added and not self.removed


def _shard_order(host: str) -> int:
    """Return the shard number of a results storage host, for sorting.

    Args:
        host: A ``productionresultssa<N>.blob.core.windows.net`` host.

    Returns:
        The shard number ``N``.
    """
    match = RESULTS_HOST.match(host)
    return int(match.group(1)) if match else -1


def meta_results_hosts(meta: Any) -> set[str]:
    """Extract the results storage hosts from a ``/meta`` document.

    Args:
        meta: The parsed ``GET /meta`` JSON document.

    Returns:
        The ``productionresultssa<N>.blob.core.windows.net`` hosts listed in
        ``.domains.actions``.

    Raises:
        DriftCheckError: When the document's shape is not recognised.
    """
    if not isinstance(meta, dict):
        raise DriftCheckError("/meta is not a JSON object")
    domains = meta.get("domains")
    if not isinstance(domains, dict):
        raise DriftCheckError("/meta has no `domains` object")
    actions = domains.get("actions")
    if not isinstance(actions, list):
        raise DriftCheckError("/meta `domains.actions` is missing or not a list")
    hosts: set[str] = set()
    for entry in actions:
        if not isinstance(entry, str):
            raise DriftCheckError(
                f"/meta `domains.actions` has a non-string entry: {entry!r}",
            )
        if RESULTS_HOST.match(entry):
            hosts.add(entry)
    if not hosts:
        raise DriftCheckError(
            "/meta `domains.actions` lists no productionresultssa<N> host; "
            "GitHub may have changed how it publishes results storage",
        )
    return hosts


def expected_results_hosts(presets: Path = PRESETS) -> set[str]:
    """Read the preset's results storage hosts from ``presets.sh``.

    Args:
        presets: Path to ``scripts/ci/lib/egress/presets.sh``.

    Returns:
        The hosts, without the ``:443`` port suffix.

    Raises:
        DriftCheckError: When the function fails or prints an unexpected line.
    """
    try:
        completed = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1" && ' + PRESET_FUNCTION,
                "check-results-hosts-drift",
                str(presets),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        raise DriftCheckError(f"could not run bash: {error}") from error
    if completed.returncode != 0:
        stderr = completed.stderr.strip()
        raise DriftCheckError(
            f"{PRESET_FUNCTION} failed ({completed.returncode}): {stderr}",
        )
    hosts: set[str] = set()
    for line in completed.stdout.splitlines():
        match = PRESET_ENTRY.match(line)
        if match is None:
            raise DriftCheckError(f"{PRESET_FUNCTION} printed {line!r}")
        hosts.add(match.group(1))
    if not hosts:
        raise DriftCheckError(f"{PRESET_FUNCTION} printed no host")
    return hosts


def compare(meta_hosts: set[str], expected: set[str]) -> Drift:
    """Compare the two host sets.

    Args:
        meta_hosts: Hosts published by ``/meta``.
        expected: Hosts in the egress preset.

    Returns:
        The added and removed hosts, each in shard order.
    """
    return Drift(
        added=tuple(sorted(meta_hosts - expected, key=_shard_order)),
        removed=tuple(sorted(expected - meta_hosts, key=_shard_order)),
    )


def _host_lines(hosts: tuple[str, ...]) -> str:
    """Render hosts as a Markdown list, or a placeholder when empty.

    Args:
        hosts: Hosts to render.

    Returns:
        One ``- `host``` line per host, or ``- none``.
    """
    if not hosts:
        return "- none"
    return "\n".join(f"- `{host}`" for host in hosts)


def render_report(drift: Drift) -> str:
    """Render the plain-text difference for the job log.

    Args:
        drift: The comparison result.

    Returns:
        A ``+``/``-`` prefixed host list.
    """
    lines = [f"+ {host}" for host in drift.added]
    lines += [f"- {host}" for host in drift.removed]
    return "\n".join(lines)


def render_issue_body(drift: Drift) -> str:
    """Render the tracking-issue body for a difference.

    The body is deterministic (no run URL or timestamp) so an unchanged
    difference leaves the issue untouched.

    Args:
        drift: The comparison result.

    Returns:
        Markdown issue body, starting with the stable marker.
    """
    return f"""{ISSUE_MARKER}

## Summary

`GET https://api.github.com/meta` (`.domains.actions`) no longer lists the
same GitHub Actions results storage hosts as
`egress_github_results_storage_endpoints` in
`scripts/ci/lib/egress/presets.sh`. The `github-results`, `npm-publish` and
`release-recover` egress presets allow only the listed hosts, so a job routed
to an added shard is blocked by harden-runner (#1495).

## Added in /meta (not allowed yet)

{_host_lines(drift.added)}

## Removed from /meta (still allowed)

{_host_lines(drift.removed)}

## What to change

1. `egress_github_results_storage_endpoints` in
   `scripts/ci/lib/egress/presets.sh`: update the ranges and the
   "Source, checked" date in its comment.
2. `expected_results_storage_hosts` in
   `tests/bats/unit/lib/egress/test_presets.bats` (the deliberate second copy).
3. The host list in `examples/publish-python-release.yml`.
4. The host list in `docs/workflow-contract.md`.
5. Run `bash scripts/ci/egress/sync-workflow-presets.sh` and commit the
   regenerated workflows.

`test_presets.bats` keeps the example and the contract list equal to the
function. This issue is updated by the scheduled
`.github/workflows/results-hosts-drift.yml` run and closed by it once the
lists match again.
"""


def _read_meta(source: str) -> Any:
    """Read and parse the ``/meta`` document.

    Args:
        source: A file path, or ``-`` for stdin.

    Returns:
        The parsed JSON document.

    Raises:
        DriftCheckError: When the input cannot be read or is not JSON.
    """
    try:
        text = sys.stdin.read() if source == "-" else Path(source).read_text("utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise DriftCheckError(f"could not read /meta from {source}: {error}") from error
    try:
        return json.loads(text)
    except ValueError as error:
        raise DriftCheckError(f"/meta is not valid JSON: {error}") from error


def _run(argv: list[str] | None) -> int:
    """Run the drift check.

    Args:
        argv: Optional argument vector (defaults to ``sys.argv[1:]``).

    Returns:
        0 when the lists match, 1 on a difference, 2 on an error.
    """
    parser = argparse.ArgumentParser(
        description="Compare GitHub's /meta results storage hosts with the presets.",
        epilog="See lgtm-ci#1498. Fails closed on an unrecognised /meta shape.",
    )
    parser.add_argument(
        "--meta",
        required=True,
        help="Path to the GET /meta JSON document, or '-' to read stdin.",
    )
    parser.add_argument(
        "--issue-body",
        type=Path,
        help="On a difference, write the tracking-issue body to this path.",
    )
    args = parser.parse_args(argv)

    try:
        meta_hosts = meta_results_hosts(_read_meta(args.meta))
        drift = compare(meta_hosts, expected_results_hosts())
    except DriftCheckError as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        return EXIT_ERROR

    if drift.matches:
        print(
            "[INFO] /meta results storage hosts match the egress presets",
            file=sys.stderr,
        )
        return EXIT_MATCH

    print(
        f"[ERROR] /meta results storage hosts differ from {PRESET_FUNCTION}: "
        f"{len(drift.added)} added, {len(drift.removed)} removed",
        file=sys.stderr,
    )
    if args.issue_body is not None:
        args.issue_body.write_text(render_issue_body(drift), encoding="utf-8")
    print(render_report(drift))
    return EXIT_DRIFT


def main(argv: list[str] | None = None) -> int:
    """Run the drift check, failing closed on any unexpected error.

    Exit 1 means "the lists differ" and makes the caller update the tracking
    issue, so an unexpected exception must never surface as Python's default
    exit status 1.

    Args:
        argv: Optional argument vector (defaults to ``sys.argv[1:]``).

    Returns:
        0 when the lists match, 1 on a difference, 2 on any error.
    """
    try:
        return _run(argv)
    except Exception as error:  # pylint: disable=broad-exception-caught
        print(f"[ERROR] drift check failed: {error!r}", file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
