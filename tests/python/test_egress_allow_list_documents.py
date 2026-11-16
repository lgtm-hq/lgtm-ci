# SPDX-License-Identifier: MIT
"""Tests for the allow-list document reader of the egress DNS check (#1548).

``scripts/ci/maintenance/egress_allow_list_documents.py``, reached through
``check-egress-dns.py``, which re-exports it. Fully offline.
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/maintenance/check-egress-dns.py"


@pytest.fixture(name="dns")
def fixture_dns(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the DNS check without running it."""
    return load_script(SCRIPT_PATH)


def test_allow_list_entries_read_only_allow_list_values(dns: ModuleType) -> None:
    """Values of *allowed-endpoints* keys in fenced blocks; never prose or modes."""
    document = """Prose naming prose.example.org:443 is not an allow-list.

```yaml
egress-policy: block
allowed-endpoints: >
  github.com:443
  api.github.com:443  # a trailing comment
other: not.listed.example.org:443
- allowed-endpoints-mode: append
  publish-allowed-endpoints: 'pypi.org:443 ${{ inputs.extra }}'
allowed-endpoints-build: >-
  ${{ format('{0} {1}', env.PRESET, 'ignored') }}
  crates.io:443
```

allowed-endpoints: outside.example.org:443
"""
    entries = list(dns.allow_list_entries(document.splitlines(), markdown=True))

    assert_that(entries).is_equal_to(
        [
            (6, "github.com:443"),
            (7, "api.github.com:443"),
            (10, "pypi.org:443"),
            (13, "crates.io:443"),
        ],
    )


def test_allow_list_entries_read_whole_yaml_files(dns: ModuleType) -> None:
    """A YAML file has no fences: every allow-list key counts."""
    document = """jobs:
  build:
    with:
      allowed-endpoints: >
        github.com:443
        *.example.org:443
      egress-policy: block
"""
    entries = list(dns.allow_list_entries(document.splitlines(), markdown=False))

    assert_that(entries).is_equal_to([(5, "github.com:443"), (6, "*.example.org:443")])


@pytest.mark.parametrize(
    "line",
    [
        '"allowed-endpoints": missing.invalid:443',
        "'allowed-endpoints': missing.invalid:443",
        "with: {allowed-endpoints: missing.invalid:443}",
        'with: {"allowed-endpoints": "missing.invalid:443"}',
        "- allowed-endpoints: [missing.invalid:443]",
    ],
)
def test_allow_list_entries_read_quoted_keys_and_flow_mappings(
    dns: ModuleType,
    line: str,
) -> None:
    """Every valid YAML spelling of the key yields its host."""
    entries = list(dns.allow_list_entries([line], markdown=False))

    assert_that(entries).is_equal_to([(1, "missing.invalid:443")])


@pytest.mark.parametrize(
    ("line", "expected"),
    [
        (
            "with: {allowed-endpoints-mode: append, allowed-endpoints: a.invalid:443}",
            ["a.invalid:443"],
        ),
        (
            "with: {allowed-endpoints: github.com:443, unrelated: b.invalid:443}",
            ["github.com:443"],
        ),
        (
            "- uses: x\n".strip() + " # allowed-endpoints: c.invalid:443",
            [],
        ),
        (
            "jobs: {a: {with: {allowed-endpoints: [d.invalid:443, e.invalid:80]}}}",
            ["d.invalid:443", "e.invalid:80"],
        ),
        ("with: {egress-policy: block, other: f.invalid:443}", []),
    ],
)
def test_allow_list_entries_read_each_flow_entry_by_its_own_key(
    dns: ModuleType,
    line: str,
    expected: list[str],
) -> None:
    """A mode key hides no sibling and an unrelated key's value is not read."""
    entries = [token for _, token in dns.allow_list_entries([line], markdown=False)]

    assert_that(entries).is_equal_to(expected)


@pytest.mark.parametrize(
    "lines",
    [
        ["allowed-endpoints: missing_host.invalid:443"],
        ["allowed-endpoints: >-", "  github.com:443", "  github.com"],
        ["with: {allowed-endpoints: bad_host.invalid:443}"],
        ["with: {allowed-endpoints: [github.com:443,", "  x.invalid:443]}"],
    ],
)
def test_allow_list_entries_fail_closed_on_an_unreadable_value(
    dns: ModuleType,
    lines: list[str],
) -> None:
    """A typo in an allow-list is an error, never a silently dropped host."""
    with pytest.raises(dns.DnsCheckError, match="line [123]: "):
        list(dns.allow_list_entries(lines, markdown=False))


def test_allow_list_entries_skip_expressions_and_scalar_marks(dns: ModuleType) -> None:
    """Expressions (even over two lines), comments and ``>-`` are not entries."""
    lines = [
        "allowed-endpoints: >-",
        "  ${{ fromJSON(env.PRESETS)['a'] }}",
        "  ${{ inputs.extra ||",
        "      '' }}",
        "  # a comment",
        "  github.com:443 # trailing",
        "next: value",
    ]

    entries = list(dns.allow_list_entries(lines, markdown=False))

    assert_that(entries).is_equal_to([(6, "github.com:443")])


def test_document_endpoints_name_the_file_of_a_bad_entry(
    dns: ModuleType,
    tmp_path: Path,
) -> None:
    """The error says which document and line to fix."""
    (tmp_path / "docs").mkdir()
    (tmp_path / "examples").mkdir()
    (tmp_path / "examples/bad.yml").write_text(
        "with:\n  allowed-endpoints: my_host.invalid:443\n",
        encoding="utf-8",
    )

    with pytest.raises(dns.DnsCheckError, match=r"examples/bad\.yml: line 2: "):
        dns.document_endpoints(tmp_path)


def test_allow_list_entries_track_the_fence_that_opened(dns: ModuleType) -> None:
    """A shorter or different fence inside a block does not close it."""
    lines = [
        "````yaml",
        "```",
        "allowed-endpoints: inner.invalid:443",
        "~~~",
        "allowed-endpoints: tilde.invalid:443",
        "````",
        "allowed-endpoints: prose.invalid:443",
        "~~~yaml",
        "allowed-endpoints: >-",
        "  last.invalid:443",
        "~~~",
    ]

    entries = list(dns.allow_list_entries(lines, markdown=True))

    assert_that(entries).is_equal_to(
        [
            (3, "inner.invalid:443"),
            (5, "tilde.invalid:443"),
            (10, "last.invalid:443"),
        ],
    )
