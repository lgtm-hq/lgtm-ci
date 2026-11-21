#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Build the test report's ``comment.v1`` model and lay it out (#1678).

``generate-test-summary.sh`` still decides every fact of the test report:
the status, the counts it could read, the pass rate, the coverage verdict.
For ``comment-format: compact`` or ``table`` it hands those decisions to this
module as ``REPORT_*`` environment variables, with the caller's raw values
(``TEST_SUITE_NAME``, ``RESULTS_INCOMPLETE``, the
``RESULTS_EXPECTED_FAILURES_FILE`` list and ``GITHUB_*``) beside them. This
module only arranges those facts into the model (``schemas/comment.v1.json``)
and ``comment_format.py`` sanitises and lays it out, so the classic renderer
is neither ported nor duplicated. Every value is read again as untrusted: a
count that is not a plain whole number makes the counts unreadable (never 0)
and a malformed flag is false.

Command line::

    python3 -I -S comment_test_report.py --format FORMAT [--out FILE] [--model FILE]

writes the comment to ``--out`` (stdout when absent) and, with ``--model``,
the model as JSON. Exit status 2 is a usage error (an unknown format among
them), 1 an internal error; neither writes a comment.

Standard library only and Python 3.10 compatible.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from typing import Any

_LIB_DIR = str(Path(__file__).resolve().parent)
if _LIB_DIR not in sys.path:  # python3 -I leaves scripts/ci/lib off sys.path
    sys.path.insert(0, _LIB_DIR)

# pylint: disable=wrong-import-position
import comment_format  # noqa: E402
import comment_model as model  # noqa: E402

# pylint: enable=wrong-import-position

#: Most expected failures listed, as in results.v1 and the classic comment.
MAX_LISTED = 50
#: Raw characters kept of any one value; the sanitiser caps lower.
MAX_RAW_CHARS = 2000
_COUNT = re.compile(r"[0-9]{1,9}")
_SHA = re.compile(r"[0-9a-f]{7,64}")
_DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
_COUNT_LABELS = ("passed", "failed", "total", "skipped", "xfailed", "xpassed")
_MAX = 999999999
_DEDUPLICATED = " ".join(
    (
        "The same test failing as expected on several matrix legs",
        "is listed once.",
    ),
)
_LEVELS = {"✅": "passed", "❌": "failed", "⏭️": "neutral"}
_USAGE = "usage: comment_test_report.py --format FORMAT [--out FILE] [--model FILE]\n"


class Unreadable(ValueError):
    """A count in the environment is not a plain whole number."""


def _env(name: str) -> str:
    """Return environment variable ``name``, at most ``MAX_RAW_CHARS`` long."""
    return os.environ.get(name, "")[:MAX_RAW_CHARS]


def _flag(name: str) -> bool:
    """Return whether flag ``name`` is exactly ``true``."""
    return os.environ.get(name, "") == "true"


def _number(name: str) -> int:
    """Return count ``name``; raise ``Unreadable`` unless it is plain digits."""
    value = os.environ.get(name, "")
    if not _COUNT.fullmatch(value):
        raise Unreadable(name)
    return int(value)


def _plural(count: int, one: str, many: str) -> str:
    """Return ``"<count> <one|many>"``."""
    return f"{count} {one if count == 1 else many}"


def _counts() -> dict[str, int] | None:
    """Return the counts, or ``None`` when one of them is unreadable."""
    keys: tuple[str, ...] = ("total", "passed", "failed", "skipped")
    keys += ("xfailed", "xpassed", "other", "ran")
    try:
        return {key: _number(f"REPORT_{key.upper()}") for key in keys}
    except Unreadable:
        return None


def _count_spans(counts: dict[str, int] | None, unreadable: list[str]) -> list[Any]:
    """Return the headline's counts group; never a count that was not read."""
    if _env("RESULTS_INCOMPLETE"):
        return [model.span("results incomplete")]
    if counts is None or any(label in _COUNT_LABELS for label in unreadable):
        return [model.span("test counts unreadable")]
    if not _flag("REPORT_COUNTS_AVAILABLE"):
        return [model.span("no test counts")]
    if _flag("REPORT_NO_TESTS"):
        return [model.span("0 tests")]
    texts = [f"{counts['passed']} passed", "", f"{counts['skipped']} skipped"]
    if counts["xfailed"]:
        xfailed = counts["xfailed"]
        texts.append(_plural(xfailed, "expected failure", "expected failures"))
    if counts["xpassed"]:
        texts.append(_plural(counts["xpassed"], "unexpected pass", "unexpected passes"))
    if counts["other"]:
        texts.append(f"{counts['other']} other")
    spans = [model.span(text) for text in texts]
    spans[1] = model.span(f"{counts['failed']} failed", strong=counts["failed"] > 0)
    return spans


def _shows_rate(counts: dict[str, int] | None) -> bool:
    """Tell whether the pass rate is shown (as the classic table shows it)."""
    if counts is None or not _flag("REPORT_COUNTS_AVAILABLE"):
        return False
    return counts["ran"] > 0 and not _flag("REPORT_NO_TESTS")


def _coverage_threshold() -> int:
    """Return the coverage threshold, 0 when unreadable."""
    try:
        return _number("REPORT_COVERAGE_THRESHOLD")
    except Unreadable:
        return 0


def _coverage_span() -> dict[str, Any]:
    """Return the headline's coverage group."""
    text = f"coverage {_env('REPORT_COVERAGE_EMOJI')} {_env('REPORT_COVERAGE_DISPLAY')}"
    threshold = _coverage_threshold()
    if _flag("REPORT_COVERAGE_PROVIDED") and threshold > 0:
        text += f" (target {threshold}%)"
    made: dict[str, Any] = model.span(text)
    return made


def _coverage_status() -> str:
    """Return the coverage verdict; the threshold has a column of its own."""
    reason = _env("RESULTS_INCOMPLETE")
    if reason:
        return f"No percentage published: {reason}"
    if _flag("REPORT_COVERAGE_PROVIDED") and _coverage_threshold() > 0:
        return "Below target" if _flag("REPORT_COVERAGE_BELOW") else "Target met"
    return _env("REPORT_COVERAGE_STATUS")


def _tests_table(counts: dict[str, int], suite: str) -> dict[str, Any]:
    """Return the tests table: one row, the classic table's rows as columns."""
    labels = ("Total", "Passed", "Failed", "Skipped")
    columns = [model.column(label, right=True) for label in labels]
    failed: dict[str, Any] = {"count": counts["failed"]}
    if counts["failed"]:
        failed.update(mark="❌", strong=True)
    passed: dict[str, Any] = {"count": counts["passed"]}
    if not counts["failed"]:
        passed.update(mark="✅", mark_in="table")
    cells = [{"count": counts["total"]}, passed, failed, {"count": counts["skipped"]}]
    extra: tuple[tuple[str, str, dict[str, str]], ...] = (
        ("xfailed", "Expected failures", {}),
        ("xpassed", "Unexpected passes", {"mark": "⚠️"}),
        ("other", "Other", {}),
    )
    for key, label, mark in extra:
        if counts[key]:
            columns.append(model.column(label, right=True))
            cells.append({"count": counts[key], **mark})
    if _shows_rate(counts):
        columns.append(model.column("Pass rate"))
        cells.append({"text": _env("REPORT_PASS_RATE")})
    rows = [{"label": suite, "cells": cells}]
    made: dict[str, Any] = model.table("tests", "Tests", columns, rows)
    return made


def _expected_failures(xfailed: int) -> dict[str, Any] | None:
    """Return the expected failures list block, or ``None`` when there is none."""
    path = _env("RESULTS_EXPECTED_FAILURES_FILE")
    if not path or not Path(path).is_file():
        return None
    try:
        doc = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError):
        return None
    doc = doc if isinstance(doc, dict) else {}
    listed = doc.get("tests")
    tests: list[Any] = listed if isinstance(listed, list) else []
    omitted = doc.get("omitted", 0)
    if isinstance(omitted, bool) or not isinstance(omitted, int) or omitted < 0:
        omitted = 0  # The generator lists it as unreadable (REPORT_UNREADABLE).
    items = []
    for test in tests[:MAX_LISTED]:
        test = test if isinstance(test, dict) else {}
        raw_id, reason = test.get("id"), test.get("reason")
        item = {"code": raw_id[:MAX_RAW_CHARS] if isinstance(raw_id, str) else ""}
        if isinstance(reason, str) and reason:
            item["text"] = reason[:MAX_RAW_CHARS]
        items.append(item)
    more = omitted + max(len(tests) - MAX_LISTED, 0)
    if not items and not more:
        return None
    summary = "Expected failures and their reasons"
    more = min(more, _MAX)
    block = {"type": "list", "summary": summary, "items": items, "more": more}
    if len(items) + more < xfailed:
        block["note"] = _DEDUPLICATED
    return block


def _results_blocks(counts: dict[str, int] | None, suite: str) -> list[dict[str, Any]]:
    """Return the test results: the table and its notes, or why there is none."""
    reason = _env("RESULTS_INCOMPLETE")
    if reason:
        text = f"No totals shown: {reason} (see the job log)"
        return [model.notice(model.span(text))]
    if counts is None or not _flag("REPORT_COUNTS_AVAILABLE"):
        text = "No test counts were parsed for this run (see the job log)"
        return [model.notice(model.span(text))]
    blocks = [_tests_table(counts, suite)]
    xpassed = counts["xpassed"]
    if xpassed:
        text = (
            "1 test marked as an expected failure passed: remove the marker from it."
            if xpassed == 1
            else f"{xpassed} tests marked as expected failures passed:"
            " remove the marker from them."
        )
        blocks.append(model.notice(model.span(text), emoji="⚠️"))
    listed = _expected_failures(counts["xfailed"])
    if listed is not None:
        blocks.append(listed)
    return blocks


def _coverage_table(suite: str) -> dict[str, Any]:
    """Return the coverage table: line coverage, threshold and verdict."""
    unreadable = _env("REPORT_COVERAGE_DISPLAY") == "unreadable"
    bad = _flag("REPORT_COVERAGE_BELOW") or unreadable
    lines: dict[str, Any] = {"text": _env("REPORT_COVERAGE_DISPLAY")}
    mark = _env("REPORT_COVERAGE_EMOJI")
    if mark:
        lines.update(mark=mark, mark_in="all" if bad else "table")
    if bad:
        lines["strong"] = True
    columns = [
        model.column("Lines", right=True, long_label="Line coverage"),
        model.column("Threshold", right=True),
        model.column("Status"),
    ]
    threshold = {"text": _env("REPORT_COVERAGE_THRESHOLD_DISPLAY")}
    cells = [lines, threshold, {"text": _coverage_status()}]
    rows = [{"label": suite, "cells": cells}]
    made: dict[str, Any] = model.table("coverage", "Coverage", columns, rows)
    return made


def _commit() -> dict[str, Any]:
    """Return the commit fact's value, as the classic commit line has it."""
    sha = _env("GITHUB_SHA")
    repo = _env("GITHUB_REPOSITORY")
    if not sha:
        return {"text": "unknown"}
    if not repo:
        return {"text": sha}
    server = _env("GITHUB_SERVER_URL") or "https://github.com"
    label = sha[:8] if _SHA.fullmatch(sha) else sha
    return {"link": {"label": label, "url": f"{server}/{repo}/commit/{sha}"}}


def _facts(blocks: list[dict[str, Any]], coverage: bool) -> list[dict[str, Any]]:
    """Return the run facts: build verdict, date and commit.

    In the table format the build joins the tests table and the rest the
    coverage table; without those tables they share a table of their own.
    """
    run = "coverage" if coverage else "run"
    tests = "tests" if any(block.get("id") == "tests" for block in blocks) else run
    generated = _env("REPORT_GENERATED")
    date = generated if _DATE.fullmatch(generated) else "unknown"
    build_text = {"text": _env("REPORT_BUILD_TEXT")}
    return [
        model.fact("Build", build_text, attach=tests, colon=True),
        model.fact("Generated", {"text": date}, attach=run),
        model.fact("Commit", _commit(), attach=run),
    ]


def build() -> dict[str, Any]:
    """Return the test report model from the environment (see the module docstring)."""
    suite = _env("TEST_SUITE_NAME") or "Shell Tests"
    counts = _counts()
    unreadable = _env("REPORT_UNREADABLE").split()
    coverage = _flag("REPORT_COVERAGE_ENABLED")
    summary = [_count_spans(counts, unreadable)]
    if _shows_rate(counts) and not _env("RESULTS_INCOMPLETE"):
        summary.append([model.span(_env("REPORT_PASS_RATE"))])
    if coverage:
        summary.append([_coverage_span()])
    blocks = _results_blocks(counts, suite)
    for label in unreadable:
        spans = (
            model.span("The report's"),
            model.span(label, code=True),
            model.span("value is not a number; see the job log."),
        )
        blocks.append(model.notice(*spans, emoji="⚠️"))
    if coverage:
        blocks.append(_coverage_table(suite))
    links = []
    build_url = _env("REPORT_BUILD_URL")
    if build_url:
        long_label = "View full build details"
        links.append(model.link("Build details", build_url, long_label=long_label))
    emoji = _env("REPORT_STATUS_EMOJI")
    label = _env("REPORT_STATUS_TEXT")
    level = _LEVELS.get(emoji, "warning")
    if level == "passed" and (label != "PASSED" or counts is None or unreadable):
        level = "warning"
    made: dict[str, Any] = model.document(
        "test-report",
        title={"icon": "🧪", "text": suite},
        status={"level": level, "emoji": emoji, "label": label},
        summary=summary,
        blocks=blocks,
        facts=_facts(blocks, coverage),
        links=links,
        footer=f"Generated by {suite} workflow",
    )
    return made


def _parse_args(argv: list[str]) -> dict[str, str] | None:
    """Parse the command line; ``None`` on a usage error."""
    options: dict[str, str] = {}
    rest = list(argv)
    while rest:
        flag = rest.pop(0)
        if flag not in {"--format", "--out", "--model"} or flag in options or not rest:
            return None
        options[flag] = rest.pop(0)
    if options.get("--format") not in comment_format.FORMATS:
        return None
    return options


def _write(options: dict[str, str]) -> int:
    """Build the model and write the comment (and the model) as ``options`` say."""
    try:
        document = build()
        if "--model" in options:
            text = json.dumps(document, indent=2) + "\n"
            Path(options["--model"]).write_text(text, encoding="utf-8")
        comment_format.write(document, options["--format"], options.get("--out", ""))
    except Exception as error:  # pylint: disable=broad-exception-caught
        message = f"the test report could not be laid out ({type(error).__name__})"
        sys.stderr.write(f"::error title=comment-format::{message}\n")
        return 1
    return 0


def main(argv: list[str]) -> int:
    """Run the command line; see the module docstring.

    Args:
        argv: Arguments after the program name.

    Returns:
        0 when the comment was written, 2 on a usage error, 1 on an internal error.
    """
    options = _parse_args(argv)
    if options is not None:
        return _write(options)
    sys.stderr.write(_USAGE)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
