# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/lib/apt_record.py``, the update record (#1664).

The record lets ``install --no-update`` skip its update only after a
complete update with the same sources and apt index configuration. These
tests cover the parts that decide that: what counts as a complete update,
what the identity covers, and how ``apt-config`` is run.
"""

from __future__ import annotations

import subprocess
import sys
from collections.abc import Callable, Sequence
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

RECORD_PATH = "scripts/ci/lib/apt_record.py"
DUMP = (
    'Dir "/";\n'
    'Dir::State::lists "lists/";\n'
    'Dir::Etc::sourceparts "/tmp/lgtm-ci-apt-sources-abc";\n'
    'Dir::Etc::SourceList "/tmp/lgtm-ci-apt-sources-abc/main/sources.list";\n'
    'APT::Architecture "amd64";\n'
)


@pytest.fixture(name="record")
def fixture_record(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load ``apt_record`` without running anything."""
    return load_script(RECORD_PATH)


def _answer(code: int, out: str) -> Callable[[Sequence[str], float], tuple[int, str]]:
    """Return a fake ``apt-config`` run that answers ``code`` and ``out``."""

    def run(_argv: Sequence[str], _timeout: float) -> tuple[int, str]:
        return code, out

    return run


@pytest.mark.parametrize(
    ("lines", "expected"),
    [
        (["Get:1 http://archive.ubuntu.com/ubuntu noble InRelease [256 kB]"], False),
        (["Hit:2 http://security.ubuntu.com/ubuntu noble-security InRelease"], False),
        (["Ign:3 http://archive.ubuntu.com/ubuntu noble/main Translation-en"], False),
        (["N: Skipping acquire of configured file 'main/binary-i386/Packages'"], False),
        (["Reading package lists...", "W: Some index files failed to download."], True),
        (["  W: indented warning"], True),
        (["E: Release file is not valid yet"], True),
        (["Err:4 http://archive.ubuntu.com/ubuntu noble-updates InRelease"], True),
    ],
)
def test_incomplete_counts_every_warning_error_and_failed_item(
    record: ModuleType,
    lines: list[str],
    expected: bool,
) -> None:
    """W:, E: and Err: lines make an update incomplete; Get, Hit, Ign, N: do not."""
    assert_that(record.incomplete(lines)).is_equal_to(expected)


def test_apt_config_drops_the_per_call_paths(record: ModuleType) -> None:
    """The private SourceParts and SourceList paths never reach the identity."""
    config = record.apt_config(["apt-config"], None, _answer(0, DUMP))

    assert_that(config).is_equal_to(
        'Dir "/";\nDir::State::lists "lists/";\nAPT::Architecture "amd64";',
    )


def test_apt_config_keeps_apt_get_overrides_and_refuses_its_own(
    record: ModuleType,
) -> None:
    """``Binary::apt-get`` lines are hashed; a ``Binary::apt-config`` item is not.

    apt-config leaves ``Binary::apt-get`` as configured, but moves its own
    ``Binary::apt-config`` tree into its root and leaves the empty item.
    """
    override = 'Binary::apt-get::Dir::State::lists "/var/lib/apt/other";\n'
    kept = record.apt_config(["apt-config"], None, _answer(0, DUMP + override))
    own = 'Binary "apt-config";\nBinary::apt-config "";\n'

    assert_that(kept).contains(override.strip())
    refused = record.apt_config(["apt-config"], None, _answer(0, own + DUMP))
    assert_that(refused).is_none()
    assert_that(record.CONFIG_KEYS).contains("Binary")


def test_apt_config_asks_for_the_index_keys_within_the_budget(
    record: ModuleType,
) -> None:
    """The dump covers the index keys; the timeout is cut to the budget left."""
    seen: list[tuple[list[str], float]] = []

    def run(argv: Sequence[str], timeout: float) -> tuple[int, str]:
        seen.append((list(argv), timeout))
        return 0, DUMP

    record.apt_config(["env", "apt-config", "-o", "A=B"], 3.5, run)
    record.apt_config(["apt-config"], None, run)

    assert_that(seen[0][0]).is_equal_to(
        ["env", "apt-config", "-o", "A=B", "dump", *record.CONFIG_KEYS],
    )
    assert_that(seen[0][1]).is_equal_to(3.5)
    assert_that(seen[1][1]).is_equal_to(record.CONFIG_TIMEOUT_SECONDS)
    assert_that(record.CONFIG_KEYS).contains(
        "Dir",
        "APT::Architecture",
        "APT::Architectures",
    )


@pytest.mark.parametrize(
    "run",
    [_answer(100, DUMP), _answer(0, "  \n")],
    ids=["nonzero", "empty"],
)
def test_apt_config_failure_is_unknown(
    record: ModuleType,
    run: Callable[[Sequence[str], float], tuple[int, str]],
) -> None:
    """A failing or silent apt-config leaves the configuration unknown."""
    assert_that(record.apt_config(["apt-config"], None, run)).is_none()


def test_apt_config_without_budget_does_not_run(record: ModuleType) -> None:
    """No time left in the run: apt-config is not started at all."""
    started: list[float] = []

    def run(_argv: Sequence[str], timeout: float) -> tuple[int, str]:
        started.append(timeout)
        return 0, DUMP

    assert_that(record.apt_config(["apt-config"], 0.0, run)).is_none()
    assert_that(started).is_empty()


def test_quiet_run_returns_stdout_and_stops_at_its_deadline(
    record: ModuleType,
) -> None:
    """The real runner captures stdout, and kills a command past its deadline."""
    code, out = record.quiet_run([sys.executable, "-c", "print('ok')"], 30.0)

    assert_that(code).is_equal_to(0)
    assert_that(out).is_equal_to("ok\n")
    slow = [sys.executable, "-c", "import time; time.sleep(30)"]
    with pytest.raises(subprocess.TimeoutExpired):
        record.quiet_run(slow, 0.5)


def test_identity_changes_with_configuration_and_sources(
    record: ModuleType,
    tmp_path: Path,
) -> None:
    """Each input changes the digest; an unknown configuration gives none."""
    parts = tmp_path / "parts"
    parts.mkdir()
    (parts / "ubuntu.sources").write_text("Types: deb\n", encoding="utf-8")
    (parts / "notes.txt").write_text("not a source\n", encoding="utf-8")
    etc = tmp_path / "etc"
    etc.mkdir()

    first = record.source_identity(parts, etc, "A")
    assert_that(record.source_identity(parts, etc, "A")).is_equal_to(first)
    assert_that(record.source_identity(parts, etc, "B")).is_not_equal_to(first)
    (parts / "notes.txt").write_text("changed\n", encoding="utf-8")
    assert_that(record.source_identity(parts, etc, "A")).is_equal_to(first)
    (etc / "sources.list").write_text("deb http://x y z\n", encoding="utf-8")
    assert_that(record.source_identity(parts, etc, "A")).is_not_equal_to(first)
    assert_that(record.source_identity(parts, etc, None)).is_equal_to("")
