# SPDX-License-Identifier: MIT
"""Cases and harness for the test report comment in each format (#1678).

``CASES`` holds the environment of each case as the reusable test summary
workflow hands it to ``generate-test-summary.sh``; ``FIELD_CASES`` adds a
``comment-fields`` input that the shared poster inserts. ``render`` runs the
generator with a fixed date and ``post`` runs the poster with a ``gh`` stub
that records the body it would send. The classic goldens under
``tests/fixtures/comment-formats/classic/`` were rendered by the scripts as
they were before #1678, so a passing classic case proves the default output
is unchanged byte for byte.

The scripts need bash 4 or newer and ``jq`` on ``PATH``, as in CI.
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
GOLDEN_DIR = PROJECT_ROOT / "tests" / "fixtures" / "comment-formats"
ACTIONS = PROJECT_ROOT / "scripts" / "ci" / "actions"
FORMATS = ("classic", "compact", "table")
#: The variables a rendering keeps from the caller's environment.
KEPT_ENV = ("PATH", "HOME", "TMPDIR", "SYSTEMROOT")
DATE = "2026-11-20"

BASE = {
    "TEST_SUITE_NAME": "Playwright E2E",
    "GITHUB_SERVER_URL": "https://github.com",
    "GITHUB_REPOSITORY": "lgtm-hq/lgtm-ci",
    "GITHUB_RUN_ID": "19876543210",
    "GITHUB_SHA": "8f3c1d2e0c0ffee00112233445566778899aaccd",
}
COVERAGE = {
    "COVERAGE_ENABLED": "true",
    "COVERAGE_PERCENT": "87.4",
    "COVERAGE_THRESHOLD": "80",
}
MOCKUP_PASSED = {
    "TESTS_PASSED": "229",
    "TESTS_FAILED": "0",
    "TESTS_TOTAL": "255",
    "TESTS_SKIPPED": "13",
    "JOB_RESULT": "success",
}
MOCKUP_FAILED = {
    **MOCKUP_PASSED,
    "TESTS_PASSED": "226",
    "TESTS_FAILED": "3",
    "JOB_RESULT": "failure",
}
PASSED_COVERAGE = {**BASE, **MOCKUP_PASSED, **COVERAGE}
HOSTILE = (
    "@org/team #1 <img src=x> [x](javascript:alert(1)) | pipe `tick` "
    "<!-- lgtm-ci:history:start --> https://evil.example/x **bold**"
)


def _xfail_doc(count: int, reason: str, *, omitted: int = 0, id_pad: str = "") -> str:
    """Return an expected_failures object with ``count`` entries."""
    tests = [
        {"id": f"tests/test_api.py::test_known_bug_{index}{id_pad}", "reason": reason}
        for index in range(count)
    ]
    doc: dict[str, object] = {"tests": tests}
    if omitted:
        doc["omitted"] = omitted
    return json.dumps(doc)


@dataclass(frozen=True)
class Case:
    """One rendering: its environment and, optionally, an expected_failures file."""

    env: dict[str, str]
    xfail: str = ""


CASES: dict[str, Case] = {
    "passed": Case({**BASE, **MOCKUP_PASSED, **COVERAGE}),
    "failed": Case({**BASE, **MOCKUP_FAILED, **COVERAGE}),
    "passed-no-coverage": Case({**BASE, **MOCKUP_PASSED}),
    "failed-no-coverage": Case(
        {
            **BASE,
            "TESTS_PASSED": "9",
            "TESTS_FAILED": "1",
            "TESTS_TOTAL": "10",
            "JOB_RESULT": "failure",
        },
    ),
    "zero-tests": Case(
        {
            **BASE,
            "TESTS_PASSED": "0",
            "TESTS_FAILED": "0",
            "TESTS_TOTAL": "0",
            "JOB_RESULT": "success",
        },
    ),
    "only-skipped": Case(
        {
            **BASE,
            "TESTS_PASSED": "0",
            "TESTS_FAILED": "0",
            "TESTS_TOTAL": "5",
            "TESTS_SKIPPED": "5",
            "JOB_RESULT": "success",
        },
    ),
    "xfail-xpass": Case(
        {
            **BASE,
            "TESTS_PASSED": "10",
            "TESTS_FAILED": "0",
            "TESTS_TOTAL": "16",
            "TESTS_SKIPPED": "1",
            "TESTS_XFAILED": "3",
            "TESTS_XPASSED": "2",
            "JOB_RESULT": "success",
            **COVERAGE,
        },
        xfail=_xfail_doc(3, "known bug: upstream fix pending"),
    ),
    "xfail-caps": Case(
        {
            **BASE,
            "TESTS_PASSED": "100",
            "TESTS_FAILED": "0",
            "TESTS_TOTAL": "175",
            "TESTS_XFAILED": "75",
            "JOB_RESULT": "success",
        },
        xfail=_xfail_doc(60, "<" * 250, omitted=15, id_pad="_" + "x" * 250),
    ),
    "hostile": Case(
        {
            **BASE,
            "TEST_SUITE_NAME": HOSTILE,
            "TESTS_PASSED": "4",
            "TESTS_FAILED": "1",
            "TESTS_TOTAL": "6",
            "TESTS_XFAILED": "1",
            "JOB_RESULT": "failure",
            **COVERAGE,
        },
        xfail=json.dumps({"tests": [{"id": HOSTILE, "reason": HOSTILE}]}),
    ),
    "unreadable-counts": Case(
        {
            **BASE,
            "TESTS_PASSED": "12abc",
            "TESTS_FAILED": "0",
            "TESTS_TOTAL": "12",
            "JOB_RESULT": "success",
        },
    ),
    "parse-error": Case(
        {
            **BASE,
            "TESTS_PASSED": "0",
            "TESTS_FAILED": "0",
            "TESTS_TOTAL": "0",
            "RESULTS_PARSE_STATUS": "error",
            "JOB_RESULT": "success",
            **COVERAGE,
        },
    ),
    "incomplete": Case(
        {
            **BASE,
            **MOCKUP_PASSED,
            "RESULTS_INCOMPLETE": "the run timed out after 30 minutes <b>",
            **COVERAGE,
        },
    ),
    "coverage-unreadable": Case({**PASSED_COVERAGE, "COVERAGE_PERCENT": "abc"}),
    "coverage-above-100": Case({**PASSED_COVERAGE, "COVERAGE_PERCENT": "187.4"}),
    "coverage-below": Case(
        {**PASSED_COVERAGE, "COVERAGE_PERCENT": "72.5", "JOB_RESULT": "failure"},
    ),
    "coverage-no-threshold": Case({**PASSED_COVERAGE, "COVERAGE_THRESHOLD": "0"}),
    "coverage-not-applicable": Case(
        {**BASE, **MOCKUP_PASSED, **COVERAGE, "COVERAGE_PERCENT": "n/a"}
    ),
    "coverage-missing": Case(
        {**BASE, **MOCKUP_FAILED, **COVERAGE, "COVERAGE_PERCENT": ""},
    ),
    "cancelled": Case({**BASE, **MOCKUP_PASSED, "JOB_RESULT": "cancelled"}),
    "local-run": Case(
        {
            "TEST_SUITE_NAME": "Shell Tests",
            "TESTS_PASSED": "3",
            "TESTS_FAILED": "0",
            "TESTS_TOTAL": "3",
            "JOB_RESULT": "success",
        },
    ),
}

MOCKUP_FIELDS = (
    "Environment: staging\n"
    + "Environment URL: https://staging.example.com\n"
    + "Region: eu-west-1\n"
)
#: Twenty-one fields: the twentieth is the last one shown (the count cap).
CAP_FIELDS = "".join(f"Field {index:02d}: value {index:02d}\n" for index in range(21))
#: Fourteen long fields, just within the input's 8,192 bytes: the rendered
#: block's size cap holds some of them back.
LARGE_FIELDS = "".join(f"{'L' * 60}{index:02d}: {'v' * 500}\n" for index in range(14))
HOSTILE_FIELDS = (
    f"Owner: {HOSTILE}\nDocs: https://github.com/lgtm-hq/lgtm-ci/issues/1\n"
    "Link: https://user@evil.example/\nbad line without a colon\n"
)
FIELD_CASES: dict[str, tuple[str, str]] = {
    "passed-fields": ("passed", MOCKUP_FIELDS),
    "failed-fields": ("failed", MOCKUP_FIELDS),
    "fields-at-cap": ("passed", CAP_FIELDS),
    "fields-at-size-cap": ("passed", LARGE_FIELDS),
    "fields-hostile": ("failed-no-coverage", HOSTILE_FIELDS),
}


def _env(tmp: Path, values: dict[str, str]) -> dict[str, str]:
    """Return a clean environment with a fixed ``date`` first on ``PATH``."""
    bin_dir = tmp / "bin"
    bin_dir.mkdir(exist_ok=True)
    stub = bin_dir / "date"
    stub.write_text(f"#!/bin/sh\necho {DATE}\n", encoding="utf-8")
    stub.chmod(0o755)
    env = {name: os.environ[name] for name in KEPT_ENV if name in os.environ}
    env["PATH"] = f"{bin_dir}{os.pathsep}{env.get('PATH', '')}"
    env.update(values)
    return env


@dataclass(frozen=True)
class Rendered:
    """What one run of the generator produced."""

    body: str
    outputs: str
    returncode: int
    stderr: str


def render(tmp: Path, name: str, comment_format: str | None, **extra: str) -> Rendered:
    """Render case ``name`` in ``comment_format`` (``None``: input not set).

    ``extra`` adds environment variables, e.g. ``COMMENT_MODEL_OUTPUT``.
    """
    case = CASES[name]
    values = {**case.env, **extra}
    if case.xfail:
        xfail = tmp / f"{name}-xfail.json"
        xfail.write_text(case.xfail, encoding="utf-8")
        values["RESULTS_EXPECTED_FAILURES_FILE"] = str(xfail)
    if comment_format is not None:
        values["COMMENT_FORMAT"] = comment_format
    out = tmp / f"{name}.md"
    outputs = tmp / f"{name}.output"
    outputs.write_text("", encoding="utf-8")
    values["COMMENT_OUTPUT"] = str(out)
    values["GITHUB_OUTPUT"] = str(outputs)
    done = subprocess.run(
        ["bash", str(ACTIONS / "generate-test-summary.sh")],
        env=_env(tmp, values),
        capture_output=True,
        text=True,
        check=False,
        cwd=tmp,
    )
    body = out.read_text(encoding="utf-8") if out.exists() else ""
    written = outputs.read_text(encoding="utf-8")
    return Rendered(body, written, done.returncode, done.stderr)


_GH_STUB = """#!/usr/bin/env bash
if [[ "$1 $2" == "api graphql" ]]; then
	printf '{"data":{"viewer":{"login":"github-actions[bot]",'
	printf '"databaseId":41898282}}}\\n'
	exit 0
fi
args=("$@")
method=GET
for ((i = 0; i < ${#args[@]}; i++)); do
	[[ "${args[i]}" == "-X" ]] && method="${args[i + 1]}"
done
case "$method" in
POST | PATCH)
	for ((i = 0; i < ${#args[@]}; i++)); do
		if [[ "${args[i]}" == "-f" && "${args[i + 1]}" == body=* ]]; then
			printf '%s' "${args[i + 1]#body=}" >"$GH_BODY"
		fi
	done
	printf '{"id": 99, "html_url": "https://github.com/c/99"}\\n'
	exit 0
	;;
esac
printf '[]\\n'
"""


def post(
    tmp: Path,
    body: str,
    fields: str,
    comment_format: str | None,
) -> tuple[str, int, str]:
    """Post ``body`` with ``fields`` through the poster; return what gh got."""
    bin_dir = tmp / "bin"
    bin_dir.mkdir(exist_ok=True)
    stub = bin_dir / "gh"
    stub.write_text(_GH_STUB, encoding="utf-8")
    stub.chmod(0o755)
    sent = tmp / "gh_body"
    sent.unlink(missing_ok=True)
    values = {
        "STEP": "post",
        "GH_TOKEN": "test-token",
        "GITHUB_REPOSITORY": "lgtm-hq/consumer",
        "PR_NUMBER": "42",
        "MARKER": "test-report",
        "MODE": "upsert",
        "DELETE_ON_EMPTY": "false",
        "EVENT_NAME": "pull_request",
        "EVENT_PULL_REQUEST_HEAD_REPO_FULL_NAME": "lgtm-hq/consumer",
        "GITHUB_OUTPUT": str(tmp / "post.output"),
        "GITHUB_RUN_ID": "200",
        "GITHUB_SERVER_URL": "https://github.com",
        "BODY_FROM_INPUT": body,
        "COMMENT_FIELDS": fields,
        "GH_BODY": str(sent),
    }
    if comment_format is not None:
        values["COMMENT_FORMAT"] = comment_format
    done = subprocess.run(
        ["bash", str(ACTIONS / "post-pr-comment.sh")],
        env=_env(tmp, values),
        capture_output=True,
        text=True,
        check=False,
        cwd=tmp,
    )
    posted = sent.read_text(encoding="utf-8") if sent.exists() else ""
    return posted, done.returncode, done.stdout + done.stderr
