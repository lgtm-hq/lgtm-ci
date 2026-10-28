# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/catalog/consumer_scan.py`` (#1082): what a scan of a
consumer's workflow and action files records, and how registry rows are
rebuilt and written.
"""

# pytest injects fixtures by parameter name; the shadowing is the mechanism.
# pylint: disable=redefined-outer-name
from __future__ import annotations

import json
import textwrap
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that
from governance_helpers import (  # pylint: disable=import-error
    TODAY,
    consumer_check,
)


def test_scan_file_fails_closed_on_invalid_yaml(
    consumer_scan: ModuleType,
) -> None:
    """Unparseable YAML must fail the rescan, not record empty usage."""
    with pytest.raises(RuntimeError, match="not valid YAML"):
        consumer_scan.scan_file(
            usage=consumer_scan.Usage(),
            path=".github/workflows/ci.yml",
            text="jobs: [unclosed\n",
        )


def test_refresh_rows_keeps_old_rows_and_drops_failed_new_ones(
    consumer_scan: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A failed read keeps known evidence and never writes a half-built row."""

    def broken(repository: str) -> None:
        raise RuntimeError(f"{repository}: not valid YAML")

    monkeypatch.setattr(consumer_scan, "scan_repository", broken)
    known = {"repository": "o/a", "last-verified": "2026-10-01", "uses": ["x"]}
    rows, failed = consumer_scan.refresh_rows(
        rows=[known, {"repository": "o/new", "tracking-issues": []}],
        repositories=[],
        head=None,
        today=TODAY,
    )
    assert_that(failed).is_equal_to(2)
    assert_that(rows).is_equal_to([known])


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


@pytest.mark.parametrize(
    ("passed", "secrets", "expected"),
    [
        (
            {"provider": "openai", "transport": "cli"},
            {"CODEX_AUTH_JSON": "${{ secrets.CODEX_AUTH_JSON }}"},
            None,
        ),
        (
            {"provider": "openai", "transport": "cli", "auth": "oauth"},
            {"CODEX_AUTH_JSON": "${{ secrets.CODEX_AUTH_JSON }}"},
            None,
        ),
        (
            {"provider": "openai", "transport": "cli", "auth": "oauth"},
            "inherit",
            None,
        ),
        (
            {"provider": None, "transport": "cli"},
            "inherit",
            "unverified: review auth selectors",
        ),
        (
            {"provider": "openai", "transport": "cli"},
            "inherit",
            None,
        ),
        (
            {"provider": "openai", "transport": "api"},
            "inherit",
            "error: api_key reviews require explicit",
        ),
        (
            {"provider": "openai", "transport": "api"},
            {"OPENAI_API_KEY": "${{ secrets.OPENAI_API_KEY }}"},
            "found secrets.OPENAI_API_KEY",
        ),
        (
            {"provider": "anthropic", "transport": "cli", "auth": "api_key"},
            {"ANTHROPIC_API_KEY": "${{ secrets.ANTHROPIC_REVIEW_API_KEY }}"},
            None,
        ),
        (
            {"provider": "openai", "transport": "cli", "auth": "api_key"},
            {"CODEX_API_KEY": "${{ secrets.OPENAI_REVIEW_API_KEY }}"},
            None,
        ),
        (
            {"provider": "${{ vars.LINTRO_AI_PROVIDER }}"},
            "inherit",
            "unverified: review auth selectors",
        ),
    ],
)
def test_review_auth_source_policy(
    consumer_scan: ModuleType,
    passed: dict[str, str | None],
    secrets: dict[str, str] | str,
    expected: str | None,
) -> None:
    """Distinguish unknown auth selectors from verified source expressions."""
    usage = consumer_scan.Usage()
    consumer_scan.record_call(
        usage=usage,
        uses="lgtm-hq/lgtm-ci/.github/workflows/reusable-ai-review.yml@abc",
        passed=passed,
        reads=[],
        secrets=secrets,
        variables={},
    )
    if expected is None:
        assert_that(usage.review_auth_findings).is_empty()
    else:
        assert_that("\n".join(usage.review_auth_findings)).contains(expected)


@pytest.mark.parametrize(
    ("passed", "slot"),
    [
        pytest.param(
            {"provider": "openai", "transport": "cli", "auth": "oauth"},
            "CODEX_AUTH_JSON",
            id="openai-oauth",
        ),
        pytest.param(
            {"provider": "anthropic", "transport": "cli", "auth": "oauth"},
            "CLAUDE_CODE_OAUTH_TOKEN",
            id="anthropic-oauth",
        ),
        pytest.param(
            {"provider": "cursor", "transport": "cli"},
            "CURSOR_API_KEY",
            id="cursor-default",
        ),
        pytest.param(
            {"provider": "openai", "transport": "cli"},
            "CODEX_AUTH_JSON",
            id="openai-default",
        ),
        pytest.param(
            {"provider": "anthropic", "transport": "cli", "auth": ""},
            "CLAUDE_CODE_OAUTH_TOKEN",
            id="anthropic-empty-auth-default",
        ),
    ],
)
@pytest.mark.parametrize("mapping", ["missing", "present", "inherit"])
def test_review_auth_requires_selected_credential(
    consumer_scan: ModuleType,
    passed: dict[str, str],
    slot: str,
    mapping: str,
) -> None:
    """Every selected matrix slot must be forwarded explicitly or inherited."""
    secrets: dict[str, str] | str = {}
    if mapping == "present":
        secrets = {slot: f"${{{{ secrets.{slot} }}}}"}
    elif mapping == "inherit":
        secrets = "inherit"
    usage = consumer_scan.Usage()
    consumer_scan.record_call(
        usage=usage,
        uses="lgtm-hq/lgtm-ci/.github/workflows/reusable-ai-review.yml@abc",
        passed=passed,
        reads=[],
        secrets=secrets,
        variables={},
    )
    expected = set()
    if mapping == "missing":
        expected.add(f"error: selected review slot {slot} is missing")
    assert_that(usage.review_auth_findings).is_equal_to(expected)


@pytest.mark.parametrize(
    ("passed", "variables", "slot"),
    [
        (
            {},
            {"LINTRO_AI_PROVIDER": "openai", "LINTRO_AI_TRANSPORT": "cli"},
            "CODEX_AUTH_JSON",
        ),
        (
            {"provider": "openai", "transport": "cli"},
            {
                "LINTRO_AI_PROVIDER": "anthropic",
                "LINTRO_AI_AUTH": "api_key",
            },
            "CODEX_API_KEY",
        ),
        (
            {"provider": "openai", "transport": "cli", "auth": "oauth"},
            {"LINTRO_AI_AUTH": "api_key"},
            "CODEX_AUTH_JSON",
        ),
        (
            {
                "provider": "${{ vars.review_provider }}",
                "transport": "${{ vars['REVIEW_TRANSPORT'] }}",
            },
            {"REVIEW_PROVIDER": "anthropic", "REVIEW_TRANSPORT": "cli"},
            "CLAUDE_CODE_OAUTH_TOKEN",
        ),
        (
            {"provider": "cursor", "transport": "", "auth": None},
            {"LINTRO_AI_TRANSPORT": "cli", "LINTRO_AI_AUTH": "api_key"},
            "CURSOR_API_KEY",
        ),
        (
            {
                "provider": "openai",
                "transport": "cli",
                "auth": "${{ vars.REVIEW_AUTH }}",
            },
            {"LINTRO_AI_AUTH": "api_key"},
            "CODEX_API_KEY",
        ),
    ],
)
def test_review_auth_resolves_input_then_variable_then_default(
    consumer_scan: ModuleType,
    passed: dict[str, str | None],
    variables: dict[str, str],
    slot: str,
) -> None:
    """Resolve caller inputs, then repo variables, then matrix auth defaults."""
    usage = consumer_scan.Usage()
    consumer_scan.record_call(
        usage=usage,
        uses="lgtm-hq/lgtm-ci/.github/workflows/reusable-ai-review.yml@abc",
        passed=passed,
        reads=[],
        secrets={},
        variables=variables,
    )
    assert_that(usage.review_auth_findings).is_equal_to(
        {f"error: selected review slot {slot} is missing"},
    )


@pytest.mark.parametrize("variables_readable", [True, False])
def test_scan_repository_reads_review_auth_variables(
    consumer_scan: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    variables_readable: bool,
) -> None:
    """Use readable Actions vars and keep scanning when they are unavailable."""
    text = textwrap.dedent(
        """\
        jobs:
          review:
            uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-ai-review.yml@abc
            with:
              provider: openai
              transport: cli
            secrets: {}
        """,
    )
    monkeypatch.setattr(
        consumer_scan,
        "consumer_files",
        lambda repository: {".github/workflows/ci.yml": text},
    )

    def read_variables(*args: str) -> str:
        """Return repository variable pages or simulate missing read permissions."""
        assert_that(args).is_equal_to(
            ("api", "repos/o/a/actions/variables", "--paginate", "--slurp"),
        )
        if not variables_readable:
            raise RuntimeError("variables are not readable")
        return json.dumps(
            [
                {"variables": []},
                {"variables": [{"name": "LINTRO_AI_AUTH", "value": "api_key"}]},
            ],
        )

    monkeypatch.setattr(consumer_scan, "gh", read_variables)
    usage = consumer_scan.scan_repository(repository="o/a")
    if variables_readable:
        assert_that(usage.review_auth_findings).is_equal_to(
            {"error: selected review slot CODEX_API_KEY is missing"},
        )
    else:
        findings = "\n".join(usage.review_auth_findings)
        assert_that(findings).contains("auth selection unverified", "no credential")
        assert_that(findings).does_not_contain("selected review slot")


def test_refresh_rows_flags_review_auth_policy_errors(
    consumer_scan: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Keep adoption evidence while returning a failing scan for known bad mappings."""
    usage = consumer_scan.Usage(review_auth_findings={"error: smoke source mapping"})
    monkeypatch.setattr(consumer_scan, "scan_repository", lambda repository: usage)
    rows, failed = consumer_scan.refresh_rows(
        rows=[{"repository": "o/a", "tracking-issues": []}],
        repositories=[],
        head=None,
        today=TODAY,
    )
    assert_that(failed).is_equal_to(1)
    assert_that(rows[0]["review-auth-findings"]).contains("error: smoke source mapping")


@pytest.mark.parametrize(
    ("passed", "variables", "slot", "expected"),
    [
        pytest.param(
            {"provider": "openai", "transport": "cli"},
            None,
            "CODEX_API_KEY",
            (None, True),
            id="unreadable-api-key",
        ),
        pytest.param(
            {"provider": "openai", "transport": "cli"},
            None,
            None,
            ("no credential", True),
            id="unreadable-no-credential",
        ),
        pytest.param(
            {"provider": "openai", "transport": "cli"},
            None,
            "OPENAI_API_KEY",
            ("no credential", True),
            id="unreadable-wrong-transport-slot",
        ),
        pytest.param(
            {"provider": "openai", "transport": "cli"},
            {"LINTRO_AI_AUTH": "api_key"},
            "CODEX_API_KEY",
            (None, False),
            id="readable-api-key",
        ),
        pytest.param(
            {"provider": "openai", "transport": "cli"},
            {},
            "CODEX_API_KEY",
            ("selected review slot CODEX_AUTH_JSON is missing", False),
            id="readable-absent-default-oauth",
        ),
        pytest.param(
            {"provider": "openai", "transport": "cli", "auth": "oauth"},
            None,
            "CODEX_API_KEY",
            ("selected review slot CODEX_AUTH_JSON is missing", False),
            id="explicit-input-strict",
        ),
        pytest.param(
            {"transport": "cli", "auth": "api_key"},
            None,
            "CODEX_API_KEY",
            (None, True),
            id="unreadable-provider",
        ),
        pytest.param(
            {"provider": "openai", "auth": "api_key"},
            None,
            "OPENAI_API_KEY",
            (None, True),
            id="unreadable-transport",
        ),
        pytest.param(
            {"provider": "${{ vars.REVIEW_PROVIDER }}", "transport": "cli"},
            None,
            "CLAUDE_CODE_OAUTH_TOKEN",
            (None, True),
            id="unreadable-input-variable",
        ),
        pytest.param(
            {"provider": "openai", "transport": "${{ vars.REVIEW_TRANSPORT }}"},
            None,
            "CODEX_API_KEY",
            (None, True),
            id="unreadable-transport-variable",
        ),
        pytest.param(
            {
                "provider": "anthropic",
                "transport": "cli",
                "auth": "${{ vars.REVIEW_AUTH }}",
            },
            None,
            "CLAUDE_CODE_OAUTH_TOKEN",
            (None, True),
            id="unreadable-auth-variable",
        ),
    ],
)
def test_review_auth_uncertain_selection(
    consumer_scan: ModuleType,
    passed: dict[str, str],
    variables: dict[str, str] | None,
    slot: str | None,
    expected: tuple[str | None, bool],
) -> None:
    """Only require an exact slot when all credential selectors are known."""
    error, unverified = expected
    mapping = {}
    if slot:
        source = {
            "CODEX_API_KEY": "OPENAI_REVIEW_API_KEY",
            "OPENAI_API_KEY": "OPENAI_REVIEW_API_KEY",
        }.get(slot, slot)
        mapping[slot] = f"${{{{ secrets.{source} }}}}"
    usage = consumer_scan.Usage()
    consumer_scan.record_call(
        usage=usage,
        uses="lgtm-hq/lgtm-ci/.github/workflows/reusable-ai-review.yml@abc",
        passed=passed,
        reads=[],
        secrets=mapping,
        variables=variables,
    )
    errors = [item for item in usage.review_auth_findings if item.startswith("error:")]
    if error:
        assert_that(errors).is_length(1)
        assert_that(errors[0]).contains(error)
    else:
        assert_that(errors).is_empty()
    notes = sorted(usage.review_auth_findings - set(errors))
    if unverified:
        assert_that(notes).is_length(1)
        assert_that(notes[0]).contains(
            "auth selection unverified: Actions variables unreadable; caller forwards",
            slot or "no slots",
        )
        assert_that("\n".join(errors)).does_not_contain("selected review slot")
    else:
        assert_that(notes).is_empty()
