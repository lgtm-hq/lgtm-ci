# SPDX-License-Identifier: MIT
"""The test report comment in each comment-format (#1678).

The classic goldens under ``tests/fixtures/comment-formats/classic/`` were
rendered by ``generate-test-summary.sh`` and ``post-pr-comment.sh`` as they
were before #1678 (``main`` at a275d8cf), so a passing classic case proves
that a caller who sets nothing, or ``classic``, gets the same bytes. The
``compact`` and ``table`` goldens follow the mock-ups approved on #1678; the
cases are in ``tests/helpers/report_format_cases.py``.

The scripts need bash 4 or newer and ``jq`` on ``PATH``, as in CI.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

import pytest
from assertpy import assert_that
from json_schema_subset import errors, unsupported
from report_format_cases import (
    CASES,
    FIELD_CASES,
    GOLDEN_DIR,
    PROJECT_ROOT,
    post,
    render,
)

NEW_FORMATS = ("compact", "table")
SCHEMA_FILE = PROJECT_ROOT / "schemas" / "comment.v1.json"
SCHEMA = json.loads(SCHEMA_FILE.read_text(encoding="utf-8"))
#: Cases whose counts could not be read: no count may reach the headline.
NO_COUNTS = ("unreadable-counts", "parse-error", "incomplete")
#: Cases whose tests passed but whose coverage could not be read: classic
#: says PASSED, and compact opens its details because of the notice.
COVERAGE_UNREADABLE = ("coverage-unreadable", "coverage-above-100")


def _golden(fmt: str, name: str) -> str:
    """Return a golden file's text."""
    text: str = (GOLDEN_DIR / fmt / name).read_text(encoding="utf-8")
    return text


@pytest.mark.parametrize("value", [None, "", "classic"])
@pytest.mark.parametrize("name", sorted(CASES))
def test_classic_is_byte_identical_to_before(
    tmp_path: Path,
    name: str,
    value: str | None,
) -> None:
    """Unset, empty and classic render exactly what was rendered before #1678."""
    rendered = render(tmp_path, name, value)

    assert_that(rendered.returncode).is_equal_to(0)
    assert_that(rendered.body).is_equal_to(_golden("classic", f"{name}.txt"))
    assert_that(rendered.outputs).is_equal_to(_golden("classic", f"{name}.output"))


@pytest.mark.parametrize("fmt", NEW_FORMATS)
@pytest.mark.parametrize("name", sorted(CASES))
def test_new_format_matches_its_golden(tmp_path: Path, name: str, fmt: str) -> None:
    """compact and table render each case as its golden, with classic's history."""
    rendered = render(tmp_path, name, fmt)

    assert_that(rendered.returncode).is_equal_to(0)
    assert_that(rendered.body).is_equal_to(_golden(fmt, f"{name}.txt"))
    assert_that(rendered.outputs).is_equal_to(_golden("classic", f"{name}.output"))


@pytest.mark.parametrize("fmt", ["classic", *NEW_FORMATS])
@pytest.mark.parametrize("name", sorted(FIELD_CASES))
def test_posted_comment_with_fields_matches_its_golden(
    tmp_path: Path,
    name: str,
    fmt: str,
) -> None:
    """The poster places comment-fields in each format's style; classic as before."""
    case, fields = FIELD_CASES[name]
    body = _golden(fmt, f"{case}.txt")

    posted, code, _ = post(tmp_path, body, fields, None if fmt == "classic" else fmt)

    assert_that(code).is_equal_to(0)
    assert_that(posted).is_equal_to(_golden(fmt, f"{name}.posted.txt"))


@pytest.mark.parametrize("fmt", NEW_FORMATS)
@pytest.mark.parametrize("name", sorted(CASES))
def test_new_format_is_no_larger_than_classic(name: str, fmt: str) -> None:
    """A new format never makes the comment larger than classic for the same data."""
    size = len(_golden(fmt, f"{name}.txt").encode("utf-8"))

    assert_that(size).is_less_than_or_equal_to(
        len(_golden("classic", f"{name}.txt").encode("utf-8"))
    )


def test_mockup_cases_render_as_approved() -> None:
    """The passed and failed mock-ups: headline, open details and wide rows."""
    passed = _golden("compact", "passed.txt")
    failed = _golden("compact", "failed.txt")
    table = _golden("table", "failed.txt")

    assert_that(passed).starts_with(
        "**🧪 Playwright E2E** · ✅ **PASSED** · 229 passed, 0 failed, 13 skipped,"
        " 13 other · 100% (of 229 run) · coverage 🟢 87.4% (target 80%)"
        "\n\n<details>\n",
    )
    assert_that(failed).contains(
        "226 passed, **3 failed**, 13 skipped",
        "\n<details open>\n",
    )
    assert_that(table).contains(
        "### 🧪 Playwright E2E · ❌ FAILED\n",
        "| 255 | 226 | **3 ❌** | 13 | 13 | 98% (of 229 run) | ❌ Tests failed |",
        "| 87.4% 🟢 | 80% | Target met | 2026-11-20 |",
    )


@pytest.mark.parametrize("name", sorted(CASES))
def test_compact_details_are_open_unless_passed(name: str) -> None:
    """compact folds its details only when the status is a verified pass."""
    body = _golden("compact", f"{name}.txt")
    headline = body.splitlines()[0]

    opened = "\n<details open>\n<summary>Details</summary>" in body
    passed = " · ✅ **PASSED**" in headline and name not in COVERAGE_UNREADABLE
    assert_that(opened).is_equal_to(not passed)


@pytest.mark.parametrize("fmt", NEW_FORMATS)
@pytest.mark.parametrize("name", NO_COUNTS)
def test_unread_counts_never_reach_the_headline_or_pass(name: str, fmt: str) -> None:
    """Counts not read show a notice, no number and no passing status (#1692)."""
    body = _golden(fmt, f"{name}.txt")
    headline = body.splitlines()[0]

    counts = re.sub(r"coverage .*", "", headline.replace("Playwright E2E", ""))
    assert_that(counts).does_not_match(r"\d")
    assert_that(headline).does_not_contain("PASSED")
    assert_that(body).does_not_contain("| Total |")
    assert_that(body).contains("(see the job log)")


@pytest.mark.parametrize("fmt", NEW_FORMATS)
def test_hostile_values_are_inert(fmt: str) -> None:
    """Suite names, reasons and field values are sanitised in every format."""
    for name in ("hostile.txt", "fields-hostile.posted.txt"):
        body = _golden(fmt, name)
        assert_that(body).does_not_contain(
            "<img",
            "](javascript",
            "<!-- lgtm-ci:history",
            "@org",
        )
        assert_that(body.count("<!-- lgtm-ci:")).is_less_than_or_equal_to(1)


@pytest.mark.parametrize("name", sorted(CASES))
def test_model_matches_the_schema_and_every_format_shows_every_block(
    tmp_path: Path, name: str
) -> None:
    """The model validates against comment.v1 and no format drops one of its values."""
    model_file = tmp_path / "model.json"
    rendered = render(tmp_path, name, "compact", COMMENT_MODEL_OUTPUT=str(model_file))
    assert_that(rendered.returncode).is_equal_to(0)
    model = json.loads(model_file.read_text(encoding="utf-8"))

    assert_that(errors(model, SCHEMA, SCHEMA)).is_empty()
    for fmt in NEW_FORMATS:
        body = _golden(fmt, f"{name}.txt")
        for value in _plain_values(model):
            assert_that(body).contains(value)


def test_schema_uses_only_checked_keywords() -> None:
    """Every keyword of comment.v1 is one the test checker understands."""
    assert_that(unsupported(SCHEMA)).is_empty()


def test_schema_rejects_a_cell_with_two_values() -> None:
    """A cell holds exactly one of text, count or link."""
    cell = {"$ref": "#/$defs/cell"}

    assert_that(errors({"text": "a", "count": 1}, cell, SCHEMA)).is_not_empty()
    assert_that(errors({"count": 1, "mark": "✅"}, cell, SCHEMA)).is_empty()


@pytest.mark.parametrize(
    "change",
    [
        {"schema": "comment.v2"},
        {"status": {"level": "ok", "emoji": "✅", "label": "PASSED"}},
        {"blocks": [{"type": "table", "id": "Bad Id", "title": "", "columns": []}]},
        {"extra": True},
        {"summary": [[{"text": "x", "bold": True}]]},
    ],
)
def test_schema_rejects_a_malformed_model(
    tmp_path: Path,
    change: dict[str, Any],
) -> None:
    """A wrong version, level, block, property or span is a schema error."""
    model_file = tmp_path / "model.json"
    render(tmp_path, "passed", "table", COMMENT_MODEL_OUTPUT=str(model_file))
    model = {**json.loads(model_file.read_text(encoding="utf-8")), **change}

    assert_that(errors(model, SCHEMA, SCHEMA)).is_not_empty()


def _plain_values(model: dict[str, Any]) -> list[str]:
    """Model values every format must show, and that sanitise to themselves."""
    found: list[str] = []
    for block in model["blocks"]:
        if block["type"] == "table":
            found += [
                str(cell["count"])
                for row in block["rows"]
                for cell in row["cells"]
                if "count" in cell
            ]
        elif block["type"] == "notice":
            found += [
                span["text"]
                for span in block["spans"]
                if re.fullmatch(r"[\w ,.;:()%'-]+", span["text"])
            ]
        else:
            found.append(block["summary"])
    for fact in model["facts"]:
        value = fact["value"]
        if "link" in value:
            found.append(value["link"]["label"])
        else:
            found.append(value["text"].split(" ")[-1])
    found += [link["url"] for link in model["links"]]
    return [value for value in found if value]
