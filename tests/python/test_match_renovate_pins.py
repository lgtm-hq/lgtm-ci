# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/maintenance/match-renovate-pins.py``.

The matcher applies the regex ``customManagers`` of ``renovate.json`` to
files, offline, and prints one tab-separated evidence line per match. It exits
1 when nothing matched, so a pin that no manager sees fails the check.
"""

from __future__ import annotations

import json
import re
import runpy
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
from assertpy import assert_that

SCRIPT = "scripts/ci/maintenance/match-renovate-pins.py"
PROJECT_ROOT = Path(__file__).resolve().parents[2]
HEADER = "file\tdepName\tcurrentValue\textractVersion\tversioning\tmanager"
ENV_MANAGER: dict[str, Any] = {
    "customType": "regex",
    "description": "env pins",
    "managerFilePatterns": ["/(^|/)versions\\.env$/"],
    "matchStrings": [
        '# renovate: depName=(?<depName>\\S+)\\n[A-Z_]+="(?<currentValue>[^"]+)"',
    ],
}


@pytest.fixture(name="matcher", scope="module")
def fixture_matcher(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the matcher once per module."""
    return load_script(SCRIPT)


def first_match(pattern: str, text: str) -> re.Match[str]:
    """Return the first match of a Python ``pattern`` in ``text``."""
    match = re.search(pattern, text)
    assert match is not None
    return match


# --- load_renovate_config


def test_loads_an_object(matcher: ModuleType, tmp_path: Path) -> None:
    """A JSON object is returned as a dict."""
    path = tmp_path / "renovate.json"
    path.write_text('{"customManagers": []}', encoding="utf-8")

    assert_that(matcher.load_renovate_config(path=path)).is_equal_to(
        {"customManagers": []},
    )


@pytest.mark.parametrize(("text", "kind"), [("[]", "list"), ('"x"', "str")])
def test_rejects_a_config_that_is_not_an_object(
    matcher: ModuleType,
    tmp_path: Path,
    text: str,
    kind: str,
) -> None:
    """Any other JSON value is a type error naming what was found."""
    path = tmp_path / "renovate.json"
    path.write_text(text, encoding="utf-8")

    with pytest.raises(TypeError, match=f"must be an object, got {kind}"):
        matcher.load_renovate_config(path=path)


def test_malformed_config_fails(matcher: ModuleType, tmp_path: Path) -> None:
    """Broken JSON is not mistaken for an empty config."""
    path = tmp_path / "renovate.json"
    path.write_text("{", encoding="utf-8")

    with pytest.raises(json.JSONDecodeError):
        matcher.load_renovate_config(path=path)


# --- regex_managers and file_matches_manager


def test_regex_managers_keeps_only_regex_tables(matcher: ModuleType) -> None:
    """Other custom types and non-object entries are dropped, order kept."""
    config = {
        "customManagers": [
            {"customType": "regex", "description": "a"},
            {"customType": "jsonata", "description": "b"},
            "not a manager",
            {"customType": "regex", "description": "c"},
        ],
    }

    managers = matcher.regex_managers(config=config)

    assert_that([m["description"] for m in managers]).is_equal_to(["a", "c"])


@pytest.mark.parametrize("config", [{}, {"customManagers": {"x": 1}}])
def test_regex_managers_without_a_list(
    matcher: ModuleType,
    config: dict[str, Any],
) -> None:
    """A missing or non-list ``customManagers`` has no managers."""
    assert_that(matcher.regex_managers(config=config)).is_empty()


@pytest.mark.parametrize(
    ("patterns", "rel_path", "expected"),
    [
        (["/^scripts/ci/versions\\.env$/"], "scripts/ci/versions.env", True),
        (["/^scripts/ci/versions\\.env$/"], "other/scripts/ci/versions.env", False),
        (["versions\\.env"], "a/versions.env", True),
        (["/\\.yml$/", "/action\\.yml$/"], "x/action.yml", True),
        (["/\\.json$/"], "x/action.yml", False),
        ([], "x/action.yml", False),
    ],
)
def test_file_matches_manager(
    matcher: ModuleType,
    patterns: list[str],
    rel_path: str,
    expected: bool,
) -> None:
    """Slash-delimited patterns are unwrapped; any pattern may match."""
    manager = {"managerFilePatterns": patterns}

    assert_that(
        matcher.file_matches_manager(rel_path=rel_path, manager=manager),
    ).is_equal_to(expected)


# --- to_python_regex and iter_matches


@pytest.mark.parametrize(
    ("js", "python"),
    [
        ("(?<depName>\\S+)", "(?P<depName>\\S+)"),
        ("(?<a_1>x)(?<B>y)", "(?P<a_1>x)(?P<B>y)"),
        ("(?<=v)(?<!x)(?:y)", "(?<=v)(?<!x)(?:y)"),
        ("(?<1bad>x)", "(?<1bad>x)"),
        ("plain", "plain"),
    ],
)
def test_to_python_regex(matcher: ModuleType, js: str, python: str) -> None:
    """Only JS named groups change; lookbehinds and other groups stay."""
    assert_that(matcher.to_python_regex(match_string=js)).is_equal_to(python)


def test_iter_matches_yields_every_match_of_every_string(
    matcher: ModuleType,
) -> None:
    """All matches of each matchString are yielded, string by string."""
    text = "a=1 b=2 c=3"

    matches = matcher.iter_matches(
        text=text,
        match_strings=["(?<k>[ab])=(?<v>\\d)", "c=(?<v>\\d)"],
    )

    assert_that([m.group(0) for m in matches]).is_equal_to(["a=1", "b=2", "c=3"])


# --- format_match


def test_format_match_writes_every_column(matcher: ModuleType) -> None:
    """The six columns follow the header order, tab separated."""
    match = first_match(
        r"(?P<depName>\w+) (?P<currentValue>[\d.]+) (?P<extractVersion>\S+)"
        r" (?P<versioning>\S+)",
        "uv 0.9.1 ^v(?<version>.*)$ semver",
    )

    line = matcher.format_match(rel_path="f.yml", description="d", match=match)

    assert_that(line.split("\t")).is_equal_to(
        ["f.yml", "uv", "0.9.1", "^v(?<version>.*)$", "semver", "d"],
    )


def test_format_match_falls_back_to_the_digest(matcher: ModuleType) -> None:
    """Without ``currentValue`` the digest fills the value column."""
    match = first_match(r"(?P<depName>\w+)@(?P<currentDigest>[a-f0-9]+)", "x@abc123")

    line = matcher.format_match(rel_path="f", description="", match=match)

    assert_that(line).is_equal_to("f\tx\tabc123\t\t\t")


def test_format_match_leaves_absent_groups_empty(matcher: ModuleType) -> None:
    """A match with no named groups still has six columns."""
    match = first_match(r"pin", "pin")

    line = matcher.format_match(rel_path="f", description="ünï", match=match)

    assert_that(line).is_equal_to("f\t\t\t\t\tünï")


# --- scan_files


def write_repo(tmp_path: Path, files: dict[str, str]) -> Path:
    """Write repo-relative files under ``tmp_path`` and return it."""
    for rel_path, text in files.items():
        path = tmp_path / rel_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return tmp_path


def test_scan_files_reports_matches_of_applicable_managers(
    matcher: ModuleType,
    tmp_path: Path,
) -> None:
    """Only managers whose file patterns match a file are applied to it."""
    env_text = (
        '# renovate: depName=uv\nDEFAULT_UV_VERSION="0.9.1"\n'
        '# renovate: depName=bun\nDEFAULT_BUN_VERSION="1.2.3"\n'
    )
    other = {
        "customType": "regex",
        "description": "yaml",
        "managerFilePatterns": ["/\\.yml$/"],
        "matchStrings": ["(?<depName>\\w+)"],
    }
    repo = write_repo(tmp_path, {"ci/versions.env": env_text})
    config = {"customManagers": [ENV_MANAGER, other]}

    lines = matcher.scan_files(
        repo_root=repo,
        config=config,
        rel_paths=["ci/versions.env"],
    )

    assert_that(lines).is_equal_to(
        [
            "ci/versions.env\tuv\t0.9.1\t\t\tenv pins",
            "ci/versions.env\tbun\t1.2.3\t\t\tenv pins",
        ],
    )


def test_scan_files_without_matches_or_paths(
    matcher: ModuleType,
    tmp_path: Path,
) -> None:
    """Unmatched files and an empty path list give no evidence."""
    repo = write_repo(tmp_path, {"versions.env": "NOTHING=1\n", "a.txt": "x"})
    config = {"customManagers": [ENV_MANAGER]}

    for rel_paths in (["versions.env", "a.txt"], []):
        lines = matcher.scan_files(repo_root=repo, config=config, rel_paths=rel_paths)
        assert_that(lines).described_as(str(rel_paths)).is_empty()


def test_scan_files_missing_file_fails(matcher: ModuleType, tmp_path: Path) -> None:
    """A path that does not exist is an error, not an empty result."""
    with pytest.raises(FileNotFoundError):
        matcher.scan_files(repo_root=tmp_path, config={}, rel_paths=["missing.env"])


# --- main against the repository's renovate.json


def test_main_default_files_all_match(
    matcher: ModuleType,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Every default pin file yields evidence, and the run exits 0."""
    assert_that(matcher.main(argv=[])).is_equal_to(0)

    lines = capsys.readouterr().out.splitlines()
    assert_that(lines[0]).is_equal_to(HEADER)
    files = {line.split("\t")[0] for line in lines[1:]}
    assert_that(files).is_equal_to(set(matcher.DEFAULT_PIN_FILES))


def test_main_grype_default_matches_its_manager(
    matcher: ModuleType,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The manager extracts the annotated default, without its ``v``.

    Ported from tests/bats/unit/renovate/test_tool_pins.bats.
    """
    rel_path = ".github/actions/scan-vulnerabilities/action.yml"
    action = (PROJECT_ROOT / rel_path).read_text(encoding="utf-8")
    default = first_match(r"depName=anchore/grype\n\s+default: \"v([^\"]+)\"", action)

    status = matcher.main(argv=[rel_path])

    assert_that(status).is_equal_to(0)
    rows = [line.split("\t") for line in capsys.readouterr().out.splitlines()[1:]]
    assert_that([row[:3] for row in rows]).contains(
        [rel_path, "anchore/grype", default.group(1)],
    )


def test_main_exits_1_when_nothing_matches(
    matcher: ModuleType,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A file no manager sees prints only the header and exits 1."""
    assert_that(matcher.main(argv=["LICENSE"])).is_equal_to(1)
    assert_that(capsys.readouterr().out).is_equal_to(f"{HEADER}\n")


def test_runs_as_a_script(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Run as ``__main__``, the exit status is ``main``'s."""
    monkeypatch.setattr(sys, "argv", ["match-renovate-pins.py", "LICENSE"])

    with pytest.raises(SystemExit) as exc_info:
        runpy.run_path(str(PROJECT_ROOT / SCRIPT), run_name="__main__")

    assert_that(exc_info.value.code).is_equal_to(1)
    assert_that(capsys.readouterr().out).is_equal_to(f"{HEADER}\n")
