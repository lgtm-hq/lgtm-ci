#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Classify a lintro JSON report as a tool-execution-timeout infra flake.

A tool that exceeds its execution timeout (``mypy execution timed out
(120.0s limit exceeded)``) makes lintro exit ``1`` with ``status=failed`` —
structurally identical to a real lint verdict. A caller of
``reusable-quality-lint.yml`` therefore cannot tell a perf flake from genuine
findings using ``exit-code`` / ``status`` alone (lgtm-ci#746, py-lintro#1653).

This script answers that question for **one** report: it reads the structured
document lintro writes to ``.lintro/artifacts/json/results.json`` and reports
whether *that run* failed only because a tool timed out, with zero lint
findings anywhere.

Scope warning. The verdict describes only the run whose report is passed in. It
is NOT evidence about a different lint run: a tool that times out contributes
zero findings precisely because it did not finish, so a clean verdict here
cannot clear a failure reported elsewhere — a different file scope or ordinary
timing variance is enough for the two to disagree. Absorbing another job's
failure with this verdict can turn a required check green over a genuine
finding, which is exactly the unsound wiring py-lintro#1733 removed. Consume
this output only from the job that produced the report.

Credit: ported from py-lintro's ``scripts/ci/classify-lint-timeout.py``, which
established the fail-closed structure reused here. The timeout detection has
been re-derived against lintro >= 0.93.0 rather than ported verbatim: that
release serializes a machine-readable per-tool ``timed_out`` flag and keeps
timeout pseudo-issues out of ``summary.total_issues``, so the prose-matching
heuristics the reference needed are no longer sound *or* necessary.

Classification is deliberately conservative and fails closed. It reports
``timeout-flake=true`` only when **all** of the following hold:

- the report parses as an object carrying a ``results`` array and a ``summary``
  object whose ``total_issues`` is exactly ``0``;
- at least one non-skipped tool recorded ``timed_out: true``;
- every timed-out tool contributed zero issues, so a timeout can never mask a
  finding it did report;
- every other non-skipped tool succeeded with zero issues — a tool that failed
  for a non-timeout reason is never excused;
- ``summary.timed_out_tools``, when present, names exactly the tools the
  ``results`` array flags, so an internally inconsistent report is rejected
  rather than trusted.

Anything else — a missing or unreadable report, a malformed document, a second
tool that failed for a non-timeout reason, or any issue at all — reports
``timeout-flake=false``. Absence of evidence is never evidence of a flake.

Usage:
    python3 scripts/ci/actions/classify-lint-timeout.py \
        --report .lintro/artifacts/json/results.json

    # or read the report from stdin
    lintro chk --output-format json . | \
        python3 scripts/ci/actions/classify-lint-timeout.py --report -

Outputs (stdout, and appended to ``GITHUB_OUTPUT`` when set):
    timeout-flake=true|false
    timed-out-tools=<comma-separated tool names>

Exit codes:
    0 — classification completed (read the ``timeout-flake`` output)
    2 — usage error (bad arguments)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# Tool names are echoed into GITHUB_OUTPUT, a line-oriented key=value file.
# Restrict them to a conservative charset so a crafted report cannot forge an
# extra record by smuggling a newline into a tool name.
_SAFE_TOOL_NAME = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")


@dataclass(frozen=True)
class Classification:
    """The verdict for one lintro JSON report.

    Attributes:
        timeout_flake: True when the run failed only because one or more tools
            timed out and no tool reported any issue.
        timed_out_tools: Names of the tools that recorded a timeout.
        reason: Human-readable explanation of the verdict, for CI logs.
    """

    timeout_flake: bool
    timed_out_tools: tuple[str, ...] = field(default=())
    reason: str = ""


def _result_issue_count(result: dict[str, Any]) -> int:
    """Return the issue count a tool result reports.

    Uses the larger of ``issues_count`` and the length of the ``issues`` array
    so a report that carries only one of the two, or whose two disagree, still
    fails closed on the higher number.

    Args:
        result: One per-tool object from the lintro report.

    Returns:
        The number of issues attributed to the tool.
    """
    raw_count = result.get("issues_count", 0)
    count = raw_count if isinstance(raw_count, int) and raw_count > 0 else 0
    issues = result.get("issues")
    if isinstance(issues, list):
        count = max(count, len(issues))
    return count


def _timed_out(result: dict[str, Any]) -> bool:
    """Report whether a tool result recorded an execution timeout.

    lintro >= 0.93.0 serializes ``timed_out`` for every tool in both the stdout
    payload and the file artifact, so the flag is read strictly: only a literal
    ``true`` counts. Under-detecting a timeout is safe (the tool then has to
    pass the ordinary "succeeded with zero issues" test, and a failed one
    yields ``false``), whereas over-detecting would excuse a genuine failure.

    Args:
        result: One per-tool object from the lintro report.

    Returns:
        True when the tool's subprocess exceeded its deadline.
    """
    return result.get("timed_out") is True


def _summary_timed_out_tools(summary: dict[str, Any]) -> tuple[set[str] | None, bool]:
    """Read ``summary.timed_out_tools`` as a cross-check on the results array.

    The list is a convenience lintro derives from the same per-tool ``timed_out``
    flags this script reads, so it is corroborating evidence rather than an
    independent source. Treating it as authoritative would mean trusting a
    summary that the results array does not back.

    An absent key and a present-but-empty list are deliberately distinguished.
    Absent means "this lintro predates the field", so there is nothing to
    cross-check. An explicit ``[]`` alongside a timed-out tool in ``results`` is
    a report contradicting itself, which must be rejected rather than silently
    skipped.

    Args:
        summary: The ``summary`` object from the lintro report.

    Returns:
        A ``(names, usable)`` pair. ``names`` is ``None`` when the key is
        absent, otherwise the set it holds — including an empty set. ``usable``
        is False when the key is present but not a list of strings, which makes
        the report untrustworthy.
    """
    raw = summary.get("timed_out_tools")
    if raw is None:
        return None, True
    if not isinstance(raw, list) or not all(isinstance(name, str) for name in raw):
        return None, False
    return set(raw), True


def classify(payload: Any) -> Classification:
    """Classify a parsed lintro JSON report.

    Args:
        payload: The parsed lintro JSON report document.

    Returns:
        The :class:`Classification` verdict. Every failure to prove the flake —
        malformed payload, missing summary, any issue, any non-timeout tool
        failure, an inconsistent summary — yields ``timeout_flake=False``.
    """
    if not isinstance(payload, dict):
        return Classification(False, reason="report is not a JSON object")

    results = payload.get("results")
    if not isinstance(results, list):
        return Classification(False, reason="report has no 'results' array")

    summary = payload.get("summary")
    if not isinstance(summary, dict):
        return Classification(False, reason="report has no 'summary' object")

    total_issues = summary.get("total_issues")
    # bool is a subclass of int; reject it so `true` cannot pass as a count.
    if isinstance(total_issues, bool) or not isinstance(total_issues, int):
        return Classification(
            False,
            reason=f"summary.total_issues is not an integer ({total_issues!r})",
        )
    if total_issues != 0:
        return Classification(
            False,
            reason=f"report has findings (total_issues={total_issues})",
        )

    timed_out: list[str] = []
    for entry in results:
        if not isinstance(entry, dict):
            return Classification(False, reason="results contains a non-object entry")
        if entry.get("skipped") is True:
            continue

        name = str(entry.get("tool") or "").strip()
        if not _SAFE_TOOL_NAME.match(name):
            return Classification(
                False,
                reason=f"results contains an unsafe tool name ({name!r})",
            )

        issue_count = _result_issue_count(entry)
        if _timed_out(entry):
            if issue_count:
                return Classification(
                    False,
                    reason=f"{name} timed out but reported {issue_count} issue(s)",
                )
            timed_out.append(name)
            continue

        if entry.get("success") is not True:
            return Classification(
                False,
                reason=f"{name} failed for a non-timeout reason",
            )
        if issue_count:
            return Classification(
                False,
                reason=f"{name} reported {issue_count} issue(s)",
            )

    if not timed_out:
        return Classification(False, reason="no tool recorded an execution timeout")

    summary_names, usable = _summary_timed_out_tools(summary)
    if not usable:
        return Classification(
            False,
            reason="summary.timed_out_tools is present but malformed",
        )
    if summary_names is not None and summary_names != set(timed_out):
        return Classification(
            False,
            reason=(
                "summary.timed_out_tools disagrees with the results array "
                f"({sorted(summary_names)} vs {sorted(timed_out)})"
            ),
        )

    return Classification(
        True,
        timed_out_tools=tuple(timed_out),
        reason=f"only execution timeouts, zero findings: {', '.join(timed_out)}",
    )


def _read_payload(report: str) -> Any:
    """Read and parse the report from a path or stdin.

    Args:
        report: Path to the JSON report, or ``-`` for stdin.

    Returns:
        The parsed document, or ``None`` when the report is missing,
        unreadable, or not valid JSON. Each of those is a fail-closed verdict
        rather than an error, so a run that never produced a report is
        classified ``timeout-flake=false`` instead of failing the step.
    """
    try:
        text = sys.stdin.read() if report == "-" else Path(report).read_text("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        print(f"[WARN] cannot read report {report}: {exc}", file=sys.stderr)
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        print(f"[WARN] report {report} is not valid JSON: {exc}", file=sys.stderr)
        return None


def _emit(classification: Classification) -> None:
    """Write the classification to stdout and ``GITHUB_OUTPUT``.

    Args:
        classification: The verdict to publish.
    """
    lines = (
        f"timeout-flake={'true' if classification.timeout_flake else 'false'}",
        f"timed-out-tools={','.join(classification.timed_out_tools)}",
    )
    for line in lines:
        print(line)
    print(f"[INFO] {classification.reason}", file=sys.stderr)

    github_output = os.environ.get("GITHUB_OUTPUT", "")
    if github_output:
        with Path(github_output).open("a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")


def main(argv: list[str] | None = None) -> int:
    """Run the classifier.

    Args:
        argv: Optional argument vector (defaults to ``sys.argv[1:]``).

    Returns:
        Process exit code: 0 when classification completed, 2 on usage error.
    """
    parser = argparse.ArgumentParser(
        description="Classify a lintro JSON report as a tool-timeout flake.",
        epilog="See lgtm-ci#746. Fails closed: when in doubt, reports false.",
    )
    parser.add_argument(
        "--report",
        required=True,
        help="Path to the lintro JSON report, or '-' to read stdin.",
    )
    args = parser.parse_args(argv)

    _emit(classify(_read_payload(args.report)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
