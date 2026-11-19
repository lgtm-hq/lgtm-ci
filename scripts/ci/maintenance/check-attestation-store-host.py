#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Check that GitHub still serves attestation bundles from the allowed host.

The ``release-recover`` egress preset allows GitHub's artifact attestation
store by exact host (``egress_github_attestation_store_endpoints`` in
``scripts/ci/lib/egress/presets.sh``). The host sits on
``blob.core.windows.net``, where anyone can create a storage account, and it
is not in ``GET /meta``, so its owner is shown by GitHub's own API instead:
``GET /repos/{owner}/{repo}/attestations/{digest}`` answers each attestation
with a ``bundle_url``, which ``gh attestation verify`` downloads (#1644).

This script reads those answers and fails when a ``bundle_url`` points at any
other host, or when no attestation carries one any more (the host would then
be unneeded and should be removed).

Inputs:

- ``--release``: a ``GET /repos/{owner}/{repo}/releases/latest`` document,
  used only to name the subjects that were checked;
- ``--attestations``: one or more ``GET .../attestations/{digest}``
  documents;
- the expected host, read by sourcing ``presets.sh`` and calling
  ``egress_github_attestation_store_endpoints`` (never a second copy here).

Fails closed: an unreadable or unrecognised document, an expected host that
cannot be read, or no attestation at all is an error, never a match.

Usage:
    python3 scripts/ci/maintenance/check-attestation-store-host.py \
        --release release.json --attestations a1.json a2.json \
        [--issue-body body.md]

Exit codes:
    0 - every attestation's bundle_url is on the allowed host
    1 - a different host, or no bundle_url at all (and the tracking-issue
        body is written to ``--issue-body`` when given)
    2 - usage error, unreadable input, unrecognised shape, or any other
        unexpected error (never 1)
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
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[3]
PRESETS = ROOT / "scripts/ci/lib/egress/presets.sh"
PRESET_FUNCTION = "egress_github_attestation_store_endpoints"
ISSUE_MARKER = "<!-- lgtm-ci:attestation-store-host -->"
PRESET_ENTRY = re.compile(r"^([a-z0-9][a-z0-9.-]*[a-z0-9]):443$")
# Stands in for a host when an attestation has no bundle_url: gh then reads
# the inline bundle and reaches no storage host.
INLINE_BUNDLE = "(no bundle_url: inline bundle only)"

EXIT_MATCH = 0
EXIT_DRIFT = 1
EXIT_ERROR = 2


class StoreCheckError(Exception):
    """Raised when an input cannot be trusted; the check fails closed."""


@dataclass(frozen=True)
class Observation:
    """What the attestations API answered.

    Attributes:
        expected: The host the preset allows.
        hosts: Every bundle_url host seen (or INLINE_BUNDLE), sorted.
        attestations: How many attestations were read.
    """

    expected: str
    hosts: tuple[str, ...]
    attestations: int

    @property
    def matches(self) -> bool:
        """Return True when every bundle_url is on the expected host."""
        return self.hosts == (self.expected,)


def expected_host(presets: Path = PRESETS) -> str:
    """Read the allowed attestation store host from ``presets.sh``.

    Args:
        presets: Path to ``scripts/ci/lib/egress/presets.sh``.

    Returns:
        The host, without the ``:443`` port suffix.

    Raises:
        StoreCheckError: When the function fails or does not print exactly
            one ``host:443`` line.
    """
    try:
        completed = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1" && ' + PRESET_FUNCTION,
                "check-attestation-store-host",
                str(presets),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        raise StoreCheckError(f"could not run bash: {error}") from error
    if completed.returncode != 0:
        stderr = completed.stderr.strip()
        raise StoreCheckError(
            f"{PRESET_FUNCTION} failed ({completed.returncode}): {stderr}",
        )
    lines = completed.stdout.splitlines()
    if len(lines) != 1:
        raise StoreCheckError(f"{PRESET_FUNCTION} printed {len(lines)} lines, not 1")
    match = PRESET_ENTRY.match(lines[0])
    if match is None:
        raise StoreCheckError(f"{PRESET_FUNCTION} printed {lines[0]!r}")
    return match.group(1)


def bundle_hosts(document: Any) -> tuple[set[str], int]:
    """Extract the bundle_url hosts from one attestations API answer.

    Args:
        document: A parsed ``GET .../attestations/{digest}`` document.

    Returns:
        The hosts (INLINE_BUNDLE for an attestation without bundle_url) and
        the number of attestations read.

    Raises:
        StoreCheckError: When the document's shape is not recognised, or a
            bundle_url is not an https URL with a host.
    """
    if not isinstance(document, dict):
        raise StoreCheckError("an attestations answer is not a JSON object")
    attestations = document.get("attestations")
    if not isinstance(attestations, list):
        raise StoreCheckError("an attestations answer has no `attestations` list")
    hosts: set[str] = set()
    for entry in attestations:
        if not isinstance(entry, dict):
            raise StoreCheckError(f"an attestation is not an object: {entry!r}")
        url = entry.get("bundle_url")
        if url in (None, ""):
            hosts.add(INLINE_BUNDLE)
            continue
        if not isinstance(url, str):
            raise StoreCheckError(f"bundle_url is not a string: {url!r}")
        parts = urlsplit(url)
        if parts.scheme != "https" or not parts.hostname:
            # Never echo the URL: its query string is a signed access token.
            raise StoreCheckError(
                f"bundle_url is not an https URL with a host ({parts.scheme!r})",
            )
        hosts.add(parts.hostname)
    return hosts, len(attestations)


def subjects(release: Any) -> tuple[str, int]:
    """Return the release tag and the asset count, to name what was checked.

    Args:
        release: A parsed ``GET .../releases/latest`` document.

    Returns:
        The tag name and the number of assets carrying a sha256 digest.

    Raises:
        StoreCheckError: When the document's shape is not recognised.
    """
    if not isinstance(release, dict) or not isinstance(release.get("tag_name"), str):
        raise StoreCheckError("the release document has no `tag_name`")
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise StoreCheckError("the release document has no `assets` list")
    digests = [
        asset
        for asset in assets
        if isinstance(asset, dict)
        and isinstance(asset.get("digest"), str)
        and asset["digest"].startswith("sha256:")
    ]
    return release["tag_name"], len(digests)


def observe(expected: str, documents: list[Any]) -> Observation:
    """Collect the hosts across every attestations answer.

    Args:
        expected: The host the preset allows.
        documents: Parsed attestations answers.

    Returns:
        The observation.

    Raises:
        StoreCheckError: When no attestation was read at all.
    """
    hosts: set[str] = set()
    total = 0
    for document in documents:
        found, count = bundle_hosts(document)
        hosts |= found
        total += count
    if total == 0:
        raise StoreCheckError("no attestation found; the host cannot be checked")
    return Observation(
        expected=expected,
        hosts=tuple(sorted(hosts)),
        attestations=total,
    )


def render_issue_body(observation: Observation, subject_repo: str) -> str:
    """Render the tracking-issue body for a mismatch.

    The body is deterministic (no tag, run URL or timestamp) so an unchanged
    mismatch leaves the issue untouched.

    Args:
        observation: The check result.
        subject_repo: The repository whose release attestations were read.

    Returns:
        Markdown issue body, starting with the stable marker.
    """
    seen = "\n".join(f"- `{host}`" for host in observation.hosts)
    return f"""{ISSUE_MARKER}

## Summary

`gh attestation verify` downloads each attestation bundle from the
`bundle_url` that `GET /repos/{{owner}}/{{repo}}/attestations/{{digest}}`
returns. For the latest release of `{subject_repo}` those URLs no longer
point only at `{observation.expected}`, the one host the `release-recover`
egress preset allows for them (`egress_github_attestation_store_endpoints` in
`scripts/ci/lib/egress/presets.sh`, #1644).

## Hosts in bundle_url

{seen}

## What to change

- A new host: confirm from GitHub's documentation or API that GitHub owns
  it, then replace the exact host in
  `egress_github_attestation_store_endpoints` with its evidence (this is an
  egress change and needs the owner's approval). Never allow a wildcard on
  `blob.core.windows.net`.
- No bundle_url any more: `gh` reads the inline bundle, so remove the host.

Then run `bash scripts/ci/egress/sync-workflow-presets.sh` and update the
host lists in `docs/workflow-contract.md`, `docs/python-release-publish.md`,
`docs/reusable-workflows.md` and `examples/publish-python-release.yml`.
This issue is updated by the scheduled
`.github/workflows/results-hosts-drift.yml` run and closed by it once the
host matches again.
"""


def _read_json(path: Path) -> Any:
    """Read and parse one JSON document.

    Args:
        path: The file to read.

    Returns:
        The parsed document.

    Raises:
        StoreCheckError: When the file cannot be read or is not JSON.
    """
    try:
        return json.loads(path.read_text("utf-8"))
    except (OSError, UnicodeDecodeError) as error:
        raise StoreCheckError(f"could not read {path}: {error}") from error
    except ValueError as error:
        raise StoreCheckError(f"{path} is not valid JSON: {error}") from error


def _run(argv: list[str] | None) -> int:
    """Run the check.

    Args:
        argv: Optional argument vector (defaults to ``sys.argv[1:]``).

    Returns:
        0 on a match, 1 on a mismatch, 2 on an error.
    """
    parser = argparse.ArgumentParser(
        description="Check the attestation bundle_url host against the egress preset.",
        epilog="See lgtm-ci#1644. Fails closed on any unrecognised input.",
    )
    parser.add_argument("--release", type=Path, required=True)
    parser.add_argument("--attestations", type=Path, nargs="+", required=True)
    parser.add_argument("--subject-repo", default="cli/cli")
    parser.add_argument(
        "--issue-body",
        type=Path,
        help="On a mismatch, write the tracking-issue body to this path.",
    )
    args = parser.parse_args(argv)

    try:
        tag, assets = subjects(_read_json(args.release))
        documents = [_read_json(path) for path in args.attestations]
        observation = observe(expected_host(), documents)
    except StoreCheckError as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        return EXIT_ERROR

    checked = (
        f"{observation.attestations} attestation(s) of {len(documents)} of "
        f"{assets} asset(s) in {args.subject_repo} {tag}"
    )
    if observation.matches:
        print(
            f"[INFO] every bundle_url is on {observation.expected} ({checked})",
            file=sys.stderr,
        )
        return EXIT_MATCH

    print(
        f"[ERROR] bundle_url hosts differ from {PRESET_FUNCTION} "
        f"({observation.expected}): {', '.join(observation.hosts)} ({checked})",
        file=sys.stderr,
    )
    if args.issue_body is not None:
        args.issue_body.write_text(
            render_issue_body(observation, args.subject_repo),
            encoding="utf-8",
        )
    return EXIT_DRIFT


def main(argv: list[str] | None = None) -> int:
    """Run the check, failing closed on any unexpected error.

    Exit 1 means "the host differs" and makes the caller update the tracking
    issue, so an unexpected exception must never surface as Python's default
    exit status 1.

    Args:
        argv: Optional argument vector (defaults to ``sys.argv[1:]``).

    Returns:
        0 on a match, 1 on a mismatch, 2 on any error.
    """
    try:
        return _run(argv)
    except SystemExit as exit_:
        # argparse exits 2 on a usage error; keep any non-zero status as 2.
        return EXIT_MATCH if exit_.code in (0, None) else EXIT_ERROR
    except Exception as error:  # pylint: disable=broad-exception-caught
        print(f"[ERROR] attestation store check failed: {error!r}", file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
