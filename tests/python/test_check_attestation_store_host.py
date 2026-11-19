# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/maintenance/check-attestation-store-host.py`` (#1644).

The fixtures are trimmed, synthetic copies of a ``releases/latest`` answer and
an ``attestations/{digest}`` answer for the GitHub CLI; the signed query
strings of the real bundle URLs are replaced with ``sig=REDACTED``.
"""

from __future__ import annotations

import copy
import json
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/maintenance/check-attestation-store-host.py"
FIXTURES = Path("attestation-store")
STORE = "tmaproduction.blob.core.windows.net"


@pytest.fixture(name="check")
def fixture_check(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the check without running it."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="release")
def fixture_release(fixtures_dir: Path) -> dict[str, Any]:
    """Return a fresh copy of the release fixture."""
    result: dict[str, Any] = json.loads(
        (fixtures_dir / FIXTURES / "release.json").read_text("utf-8"),
    )
    return result


@pytest.fixture(name="answer")
def fixture_answer(fixtures_dir: Path) -> dict[str, Any]:
    """Return a fresh copy of the attestations fixture."""
    result: dict[str, Any] = json.loads(
        (fixtures_dir / FIXTURES / "attestations.json").read_text("utf-8"),
    )
    return result


def _run(
    check: ModuleType,
    release: Any,
    answers: list[Any],
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> tuple[int, str, Path]:
    """Run the CLI on documents written to files.

    Returns:
        Exit code, stderr and the issue-body path.
    """
    release_file = tmp_path / "release.json"
    release_file.write_text(json.dumps(release), encoding="utf-8")
    files = []
    for index, document in enumerate(answers):
        path = tmp_path / f"a{index}.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        files.append(str(path))
    body = tmp_path / "body.md"
    code = check.main(
        argv=[
            "--release",
            str(release_file),
            "--issue-body",
            str(body),
            "--attestations",
            *files,
        ],
    )
    return code, capsys.readouterr().err, body


def test_fixture_matches_the_preset(
    check: ModuleType,
    release: dict[str, Any],
    answer: dict[str, Any],
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Every bundle_url on the preset host: exit 0, no issue body."""
    code, err, body = _run(check, release, [answer, answer], tmp_path, capsys)

    assert_that(code).is_equal_to(0)
    assert_that(err).contains(STORE, "4 attestation(s) of 2 of 2 asset(s)")
    assert_that(body.exists()).is_false()


def test_expected_host_comes_from_the_preset_function(check: ModuleType) -> None:
    """The expected host is the function's one line, without the port."""
    assert_that(check.expected_host()).is_equal_to(STORE)


def test_another_host_is_a_mismatch_with_a_deterministic_body(
    check: ModuleType,
    release: dict[str, Any],
    answer: dict[str, Any],
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A bundle_url elsewhere: exit 1, both hosts listed, no signed query."""
    moved = copy.deepcopy(answer)
    moved["attestations"][1]["bundle_url"] = "https://elsewhere.example/a.json?sig=SECRET"

    code, err, body = _run(check, release, [moved], tmp_path, capsys)
    first = body.read_text("utf-8")
    release["tag_name"] = "v9.9.9"
    _run(check, release, [moved], tmp_path, capsys)

    assert_that(code).is_equal_to(1)
    assert_that(err).contains("elsewhere.example").does_not_contain("SECRET")
    assert_that(first).starts_with(check.ISSUE_MARKER)
    assert_that(first).contains(f"- `{STORE}`", "- `elsewhere.example`")
    assert_that(first).does_not_contain("SECRET", "v2.105.0")
    assert_that(body.read_text("utf-8")).is_equal_to(first)


def test_inline_bundles_only_is_a_mismatch(
    check: ModuleType,
    release: dict[str, Any],
    answer: dict[str, Any],
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """No bundle_url at all means the host is unneeded: exit 1."""
    for attestation in answer["attestations"]:
        attestation["bundle_url"] = None
        attestation["bundle"] = {"mediaType": "application/vnd.dev.sigstore.bundle"}

    code, _, body = _run(check, release, [answer], tmp_path, capsys)

    assert_that(code).is_equal_to(1)
    assert_that(body.read_text("utf-8")).contains(check.INLINE_BUNDLE)


@pytest.mark.parametrize(
    ("document", "message"),
    [
        pytest.param([], "not a JSON object", id="not-an-object"),
        pytest.param({}, "no `attestations` list", id="no-list"),
        pytest.param({"attestations": ["x"]}, "not an object", id="bad-entry"),
        pytest.param(
            {"attestations": [{"bundle_url": 5}]},
            "not a string",
            id="non-string-url",
        ),
        pytest.param(
            {"attestations": [{"bundle_url": "http://tmaproduction.blob.core.windows.net/a"}]},
            "not an https URL",
            id="plain-http",
        ),
        pytest.param({"attestations": []}, "no attestation found", id="empty"),
    ],
)
def test_unrecognised_answers_fail_closed(
    check: ModuleType,
    release: dict[str, Any],
    document: Any,
    message: str,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """An answer the check cannot trust is an error (2), never a mismatch."""
    code, err, body = _run(check, release, [document], tmp_path, capsys)

    assert_that(code).is_equal_to(2)
    assert_that(err).contains(message)
    assert_that(body.exists()).is_false()


@pytest.mark.parametrize(
    "release_document",
    [
        pytest.param({}, id="no-tag"),
        pytest.param({"tag_name": "v1", "assets": None}, id="no-assets"),
    ],
)
def test_unrecognised_release_fails_closed(
    check: ModuleType,
    release_document: dict[str, Any],
    answer: dict[str, Any],
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A release document the check cannot read is an error (2)."""
    code, _, _ = _run(check, release_document, [answer], tmp_path, capsys)

    assert_that(code).is_equal_to(2)


def test_a_broken_preset_function_fails_closed(
    check: ModuleType,
    tmp_path: Path,
) -> None:
    """A presets file whose function prints two hosts is an error."""
    presets = tmp_path / "presets.sh"
    presets.write_text(
        "egress_github_attestation_store_endpoints() {\n"
        "  printf 'a.example:443\\nb.example:443\\n'\n"
        "}\n",
        encoding="utf-8",
    )

    assert_that(check.expected_host).raises(check.StoreCheckError).when_called_with(
        presets,
    ).contains("2 lines")


def test_usage_error_is_exit_two(check: ModuleType) -> None:
    """A missing required argument exits 2, never 1."""
    assert_that(check.main(argv=["--release", "x.json"])).is_equal_to(2)
