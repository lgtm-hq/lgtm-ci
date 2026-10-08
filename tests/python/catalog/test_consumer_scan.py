# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/catalog/consumer_scan.py`` (#1082): what a scan of a
consumer's workflow and action files records, and how registry rows are
rebuilt and written.
"""

# pytest injects fixtures by parameter name; the shadowing is the mechanism.
# pylint: disable=redefined-outer-name
from __future__ import annotations

import textwrap
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that
from governance_helpers import (  # pylint: disable=import-error
    TODAY,
    consumer_check,
)


def test_scan_records_secrets_case_and_whole_output_reads(
    consumer_scan: ModuleType,
) -> None:
    """Secrets passed or inherited, any owner casing, and `toJSON(outputs)`."""
    text = textwrap.dedent(
        """\
        jobs:
          a:
            uses: LGTM-HQ/lgtm-ci/.github/workflows/reusable-demo.yml@abc
            secrets:
              TOKEN: ${{ secrets.X }}
          b:
            uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-legacy.yml@abc
            secrets: inherit
          c:
            needs: [a]
            runs-on: ubuntu-24.04
            steps:
              - run: echo '${{ toJSON(needs.a.outputs) }}'
        """,
    )
    usage = consumer_scan.Usage()
    consumer_scan.scan_file(usage=usage, path=".github/workflows/ci.yml", text=text)
    assert_that(usage.keys).contains(
        "reusable-demo:secret:TOKEN",
        "reusable-demo:output:*",
        "reusable-legacy:secret:*",
    )
    row = consumer_scan.refreshed_row(
        row={"repository": "o/a"},
        usage=usage,
        deprecated={"reusable-demo:output:out", "reusable-legacy:secret:OLD"},
        live={
            "reusable-demo:entry",
            "reusable-demo:output:out",
            "reusable-demo:secret:TOKEN",
            "reusable-legacy:entry",
            "reusable-legacy:secret:OLD",
        },
        today=TODAY,
    )
    assert_that(row["deprecated-in-use"]).is_equal_to(
        ["reusable-demo:output:out", "reusable-legacy:secret:OLD"],
    )


def test_scan_file_records_inputs_outputs_and_pins(
    consumer_scan: ModuleType,
) -> None:
    """Workflow calls, step calls and the outputs read from both are found."""
    text = textwrap.dedent(
        """\
        jobs:
          cov:
            uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-coverage.yml@abc # v1
            with:
              publish-pages: true
          after:
            needs: cov
            runs-on: ubuntu-24.04
            steps:
              - id: setup
                uses: lgtm-hq/lgtm-ci/.github/actions/setup-env@v0
                with:
                  python-version: "3.13"
              - run: >-
                  echo ${{ needs.cov.outputs.pages-url }}
                  ${{ steps.setup.outputs.x }}
              - uses: actions/checkout@v6
        """,
    )
    usage = consumer_scan.Usage()
    consumer_scan.scan_file(usage=usage, path=".github/workflows/ci.yml", text=text)
    assert_that(sorted(usage.pins)).is_equal_to(["abc", "v0"])
    assert_that(sorted(usage.entries)).is_equal_to(["reusable-coverage", "setup-env"])
    assert_that(usage.keys).contains(
        "reusable-coverage:input:publish-pages",
        "reusable-coverage:output:pages-url",
        "setup-env:input:python-version",
        "setup-env:output:x",
        "setup-env:entry",
    )


def test_scan_file_reads_composite_actions(
    consumer_scan: ModuleType,
) -> None:
    """A consumer's own composite action counts as usage too."""
    sha = "0123456789abcdef0123456789abcdef01234567"
    text = textwrap.dedent(
        f"""\
        runs:
          using: composite
          steps:
            - uses: lgtm-hq/lgtm-ci/.github/actions/run-pytest@{sha}
        """,
    )
    usage = consumer_scan.Usage()
    consumer_scan.scan_file(usage=usage, path=".github/actions/x/action.yml", text=text)
    assert_that(usage.entries).is_equal_to({"run-pytest"})


def test_refreshed_row_keeps_only_deprecated_keys(
    consumer_scan: ModuleType,
) -> None:
    """The registry stores deprecated keys, not every input a consumer passes."""
    usage = consumer_scan.Usage(
        pins={"b", "a"},
        entries={"reusable-demo"},
        keys={
            "reusable-demo:entry",
            "reusable-demo:input:old",
            "reusable-demo:input:keep",
        },
    )
    row = consumer_scan.refreshed_row(
        row={"repository": "o/a", "tracking-issues": [7]},
        usage=usage,
        deprecated={"reusable-demo:input:old"},
        live={"reusable-demo:entry", "reusable-demo:input:keep"},
        today=TODAY,
    )
    assert_that(row).is_equal_to(
        {
            "repository": "o/a",
            "tracking-issues": [7],
            "last-verified": "2026-10-08",
            "pins": ["a", "b"],
            "uses": ["reusable-demo"],
            "deprecated-in-use": ["reusable-demo:input:old"],
        },
    )


def test_refreshed_row_keeps_usage_of_items_already_removed(
    consumer_scan: ModuleType,
) -> None:
    """A removal PR drops the record before refreshing; the usage must stay."""
    usage = consumer_scan.Usage(
        entries={"reusable-demo", "reusable-legacy"},
        keys={
            "reusable-demo:entry",
            "reusable-demo:input:gone",
            "reusable-legacy:entry",
            "reusable-legacy:input:dir",
        },
    )
    row = consumer_scan.refreshed_row(
        row={"repository": "o/a"},
        usage=usage,
        deprecated={"reusable-legacy:entry"},
        live={
            "reusable-demo:entry",
            "reusable-legacy:entry",
            "reusable-legacy:input:dir",
        },
        today=TODAY,
    )
    assert_that(row["deprecated-in-use"]).is_equal_to(
        [
            "reusable-demo:input:gone",
            "reusable-legacy:entry",
            "reusable-legacy:input:dir",
        ],
    )


@pytest.mark.parametrize(
    "expression",
    [
        "needs.cov.outputs.pages-url",
        "needs.cov.outputs['pages-url']",
        'needs["cov"].outputs.pages-url',
        "needs['cov']['outputs']['pages-url']",
    ],
)
def test_outputs_read_understands_bracket_access(
    expression: str,
    consumer_scan: ModuleType,
) -> None:
    """Dotted, bracketed and mixed property access all count as a read."""
    text = f"run: echo ${{{{ {expression} }}}}"
    found = consumer_scan.outputs_read(text=text, context="needs", ident="cov")
    assert_that(found).is_equal_to(["pages-url"])


def test_write_registry_round_trips_through_the_validator(
    repo: Path,
    consumer_scan: ModuleType,
    governance: ModuleType,
) -> None:
    """Rows written by ``scan --write`` satisfy the registry schema."""
    consumer_scan.write_registry(
        repo_root=repo,
        rows=[
            {
                "repository": "o/a",
                "tracking-issues": [7],
                "last-verified": "2026-10-08",
                "pins": ["0123456789abcdef0123456789abcdef01234567"],
                "uses": ["reusable-demo"],
                "deprecated-in-use": ["reusable-demo:input:old"],
            },
        ],
    )
    report = consumer_check(
        governance, repo, ids={"reusable-demo"}, covered={"reusable-demo:input:old"}
    )
    assert_that(report.errors).is_empty()
    assert_that(report.notices).is_empty()
