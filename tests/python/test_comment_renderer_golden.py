# SPDX-License-Identifier: MIT
"""Golden tests: the sanitised comment renderers are unchanged for normal input (#1676).

Each case runs one renderer on ordinary values (suite names, paths, URLs,
tool output) and compares the comment with a fixture under
``tests/fixtures/comment-golden/`` (``.txt``: comment bodies, not docs). The
fixtures were rendered by the renderers as they were before the shared
sanitiser (``HEAD`` before #1676); ``validate.txt`` alone has since dropped
its ``<!-- lgtm-ci:validation -->`` line, which the poster writes (#1680).
A passing case shows the migration kept the default output byte for byte.
The ``coverage-*`` format cases and ``playwright-suites`` were rendered by
the renderers as they were before #1692 tightened the report parsers.
Only the date line (``- **Generated:** YYYY-MM-DD``) is normalised.

The renderers need bash 4 or newer and ``jq`` on ``PATH``, as in CI.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

import pytest
from assertpy import assert_that

PROJECT_ROOT = Path(__file__).resolve().parents[2]
GOLDEN_DIR = PROJECT_ROOT / "tests" / "fixtures" / "comment-golden"
DATE_LINE = re.compile(r"^(- \*\*Generated:\*\*) \d{4}-\d{2}-\d{2}$", re.MULTILINE)
#: The variables a rendering keeps from the caller's environment (#1692).
KEPT_ENV = ("PATH", "HOME", "TMPDIR", "SYSTEMROOT")

BASE_ENV = {
    "GITHUB_REPOSITORY": "o/r",
    "GITHUB_RUN_ID": "42",
    "GITHUB_SERVER_URL": "https://github.com",
    "GITHUB_SHA": "0123456789abcdef0123456789abcdef01234567",
}
REPORT_URL = "https://o.github.io/r/report/"
PLAYWRIGHT_RESULTS = (
    '{"stats":{"expected":1,"unexpected":2,"flaky":0,"skipped":0,"duration":1000},'
    '"suites":[{"file":"a.spec.ts","title":"a","specs":[],"tests":['
    '{"title":"login works","status":"unexpected","projectName":"chromium"},'
    '{"title":"checkout › pays","status":"unexpected"}]}]}'
)
COVERAGE = (
    '{"total":{"lines":{"pct":85.5},"branches":{"pct":75},'
    '"functions":{"pct":90},"statements":{"pct":85}}}'
)
LIGHTHOUSE = (
    '{"categories":{"performance":{"score":0.9},"accessibility":{"score":0.95},'
    '"best-practices":{"score":0.9},"seo":{"score":0.9}}}'
)
FILES = (
    '[{"filename":"src/app_main.py","status":"modified","additions":3,"deletions":1},'
    '{"filename":"tests/test_app.py","status":"added","additions":5,"deletions":0},'
    '{"filename":"docs/guide (draft).md","status":"renamed",'
    '"additions":2,"deletions":2}]'
)
SEMANTIC_ERROR = 'No release type found in pull request title "Add thing".'
SECURITY = (
    '{"results":[{"tool":"osv_scanner","issues_count":1,"success":false,'
    '"issues":[{"message":"GHSA-xxxx-yyyy-zzzz in example-crate",'
    '"file":"Cargo.lock"}]}]}'
)
CLEAN_OSV = '{"tool":"osv_scanner","issues_count":0,"success":true,"issues":[]}'
SECURITY_CLEAN = f'{{"results":[{CLEAN_OSV}]}}'
FIXTURES = PROJECT_ROOT / "tests" / "fixtures"
PLAYWRIGHT_REPORTS = FIXTURES / "playwright" / "reports"
#: A native Playwright 1.63 report without its stats object, so the renderer
#: counts the tests in suites by their status (#1692).
_PLAYWRIGHT_MIXED = json.loads(
    (PLAYWRIGHT_REPORTS / "json-mixed.json").read_text(encoding="utf-8"),
)
PLAYWRIGHT_SUITES = json.dumps(
    {key: value for key, value in _PLAYWRIGHT_MIXED.items() if key != "stats"},
)
#: coverage.py 7.x JSON totals, with and without branch measurement. Neither
#: writes percent_covered_branches: the branch row shows percent_covered.
COVERAGE_PY_TOTALS = (
    '"covered_lines":90,"num_statements":100,"percent_covered":86.66666666666667,'
    '"percent_covered_display":"87","missing_lines":10,"excluded_lines":0'
)
COVERAGE_PY_BRANCHES = (
    '{"meta":{"format":3,"version":"7.6.1","branch_coverage":true},"totals":{'
    + COVERAGE_PY_TOTALS
    + ',"num_branches":20,"num_partial_branches":2,"covered_branches":14,'
    '"missing_branches":6,"percent_branches_covered":70.0}}'
)
COVERAGE_PY_LINES = (
    '{"meta":{"format":3,"version":"7.6.1","branch_coverage":false},"totals":{'
    + COVERAGE_PY_TOTALS
    + "}}"
)
#: coverage.py's Cobertura XML without branch measurement.
COBERTURA_LINES = (
    '<?xml version="1.0" ?>\n'
    '<coverage version="7.6.1" timestamp="1700000000000" lines-valid="4" '
    'lines-covered="3" line-rate="0.75" branches-covered="0" branches-valid="0" '
    'branch-rate="0" complexity="0">\n'
    "\t<packages/>\n</coverage>\n"
)


def _fixture(*parts: str) -> str:
    """Return the text of a file under ``tests/fixtures``."""
    return FIXTURES.joinpath(*parts).read_text(encoding="utf-8")


@dataclass(frozen=True)
class Case:
    """One renderer run on normal input.

    Attributes:
        name: Fixture stem under ``tests/fixtures/comment-golden``.
        command: Command relative to the root under test.
        env: Extra environment.
        files: Files to write into the working directory first.
        output: ``stdout``, ``github-output`` (the ``body`` output) or a file
            name in the working directory.
    """

    name: str
    command: tuple[str, ...]
    env: dict[str, str] = field(default_factory=dict)
    files: dict[str, str] = field(default_factory=dict)
    output: str = "stdout"


def _bash(script: str) -> tuple[str, ...]:
    """Return the command that runs an action script with bash."""
    return ("bash", f"scripts/ci/actions/{script}")


TEST_COUNTS = {
    "TESTS_PASSED": "5",
    "TESTS_FAILED": "0",
    "TESTS_TOTAL": "5",
    "COVERAGE_ENABLED": "true",
    "COVERAGE_THRESHOLD": "80",
    "JOB_RESULT": "success",
    "TEST_SUITE_NAME": "Unit Tests (py3.12)",
}
CASES = [
    Case(
        "test-summary",
        _bash("generate-test-summary.sh"),
        {**TEST_COUNTS, "COVERAGE_PERCENT": "91.2"},
    ),
    Case(
        "test-summary-incomplete",
        _bash("generate-test-summary.sh"),
        {**TEST_COUNTS, "RESULTS_INCOMPLETE": "shard 3 timed out"},
    ),
    Case(
        "coverage",
        _bash("generate-coverage-comment.sh"),
        {
            "COVERAGE_FILE": "cov.json",
            "REPORT_URL": REPORT_URL,
            "TEST_SUITE_NAME": "Unit Tests (py3.12)",
        },
        {"cov.json": COVERAGE},
        "github-output",
    ),
    *(
        Case(
            name,
            _bash("generate-coverage-comment.sh"),
            {"COVERAGE_FILE": file},
            {file: content},
            "github-output",
        )
        for name, file, content in (
            ("coverage-py-branches", "coverage.json", COVERAGE_PY_BRANCHES),
            ("coverage-py-lines", "coverage.json", COVERAGE_PY_LINES),
            ("coverage-lcov", "lcov.info", _fixture("coverage", "lcov-full.info")),
            (
                "coverage-lcov-lines",
                "lcov.info",
                _fixture("coverage", "lcov-line-only.info"),
            ),
            (
                "coverage-cobertura",
                "coverage.xml",
                _fixture("coverage", "sample_cobertura.xml"),
            ),
            ("coverage-cobertura-lines", "coverage.xml", COBERTURA_LINES),
        )
    ),
    Case(
        "playwright",
        _bash("generate-playwright-comment.sh"),
        {"RESULTS_PATH": "pw.json", "REPORT_URL": REPORT_URL},
        {"pw.json": PLAYWRIGHT_RESULTS},
        "github-output",
    ),
    Case(
        "playwright-suites",
        _bash("generate-playwright-comment.sh"),
        {"RESULTS_PATH": "pw.json"},
        {"pw.json": PLAYWRIGHT_SUITES},
        "github-output",
    ),
    Case(
        "lighthouse",
        _bash("generate-lighthouse-comment.sh"),
        {"RESULTS_PATH": "lh.json", "REPORT_URL": REPORT_URL},
        {"lh.json": LIGHTHOUSE},
        "github-output",
    ),
    Case(
        "lintro",
        _bash("generate-lintro-comment.sh"),
        {"LINTRO_OUTPUT": "lint.txt", "LINTRO_EXIT_CODE": "1"},
        {
            "lint.txt": "noise\n📊 EXECUTION SUMMARY\n| Tool | Status |\n"
            "| ruff | ⚠️ 2 |\nTotal Issues: 2\n"
        },
    ),
    Case(
        "file-breakdown",
        _bash("generate-file-breakdown.sh"),
        {
            "STEP": "generate",
            "PR_FILES_JSON": "files.json",
            "FILE_BREAKDOWN_CONFIG": "absent.yml",
        },
        {"files.json": FILES},
    ),
    Case(
        "artifact-report",
        _bash("compose-artifact-report-comment.sh"),
        {
            "REPORT_FILE": "rep.md",
            "TITLE": "Bundle Size",
            "UPSTREAM_RESULT": "success",
            "WORKFLOW_NAME": "size_check",
        },
        {"rep.md": "## Size\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"},
    ),
    Case(
        "artifact-preview",
        _bash("compose-artifact-preview-comment.sh"),
        {
            "ARTIFACT_NAME": "my_build-artifact",
            "ARTIFACT_URL": "https://github.com/o/r/actions/runs/42/artifacts/7",
            "SUMMARY": "Built **3** files",
            "UPSTREAM_RESULT": "failure",
        },
    ),
    Case(
        "semantic-title",
        _bash("format-semantic-pr-title-failure-comment.sh"),
        {
            "SEMANTIC_ERROR": SEMANTIC_ERROR,
            "ALLOWED_TYPES": "feat\nfix\nchore\n",
            "COMMENT_FILE": "sem.md",
        },
        output="sem.md",
    ),
    Case(
        "link-check",
        _bash("wrap-lychee-report.sh"),
        {
            "LYCHEE_REPORT": "ly.md",
            "LYCHEE_OUTCOME": "success",
            "PATHS": "docs,README.md",
            "FILE_EXTENSIONS": "md,mdx",
            "EXCLUDE_PATTERNS": "node_modules,dist",
            "TIMEOUT": "20",
        },
        {
            "ly.md": "# Summary\n\n| Status | Count |\n|---|---|\n"
            "| 🔍 Total | 10 |\n| 🚫 Errors | 0 |\n"
        },
    ),
    Case(
        "validate",
        _bash("run-validate-script.sh"),
        {
            "SCRIPT_PATH": "check.sh",
            "VALIDATION_NAME": "Schema Check",
            "COMMENT_OUTPUT": "val.md",
            "OUTPUT_FILE": "val.txt",
        },
        {"check.sh": '#!/bin/sh\necho "check failed: 2 problems"\nexit 3\n'},
        "val.md",
    ),
    Case(
        "security",
        ("python3", "-I", "scripts/ci/security/format-security-comment.py", "osv.json"),
        files={"osv.json": SECURITY},
    ),
    Case(
        "security-clean",
        ("python3", "-I", "scripts/ci/security/format-security-comment.py", "osv.json"),
        files={"osv.json": SECURITY_CLEAN},
    ),
]


def _from_root(root: Path, part: str) -> str:
    """Resolve a ``scripts/`` path of a command against the root under test."""
    return str(root / part) if part.startswith("scripts/") else part


def _body(github_output: str) -> str:
    """Extract the multiline ``body`` output from a GITHUB_OUTPUT file."""
    match = re.search(
        r"^body<<(\S+)\n(.*?)\n\1$",
        github_output,
        re.MULTILINE | re.DOTALL,
    )
    return match.group(2) + "\n" if match else ""


def render(case: Case, root: Path, work: Path) -> str:
    """Run one case against the renderers under ``root``.

    Args:
        case: The case.
        root: Repository root whose ``scripts/ci`` is under test.
        work: Empty working directory.

    Returns:
        The comment body with the date line normalised.
    """
    for name, content in case.files.items():
        path = work / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)
    outputs = work / "github-output"
    outputs.touch()
    # Only what the renderers need to run; never the runner's GITHUB_*,
    # RUNNER_* or CI variables, its locale or its time zone (#1692).
    env = {key: os.environ[key] for key in KEPT_ENV if key in os.environ}
    env.update({"LC_ALL": "C", "LANG": "C", "TZ": "UTC"})
    env.update(BASE_ENV)
    env.update(case.env)
    env["GITHUB_OUTPUT"] = str(outputs)
    command = [_from_root(root, part) for part in case.command]
    result = subprocess.run(
        command,
        cwd=work,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    if case.output == "stdout":
        body = result.stdout
    elif case.output == "github-output":
        body = _body(outputs.read_text(encoding="utf-8"))
    else:
        body = (work / case.output).read_text(encoding="utf-8")
    return DATE_LINE.sub(r"\1 <date>", body)


@pytest.mark.skipif(shutil.which("jq") is None, reason="the renderers need jq")
@pytest.mark.parametrize("case", CASES, ids=[case.name for case in CASES])
def test_renderer_output_unchanged_for_normal_input(case: Case, tmp_path: Path) -> None:
    """The renderer writes the same comment as before the sanitiser, byte for byte."""
    expected = (GOLDEN_DIR / f"{case.name}.txt").read_text(encoding="utf-8")
    assert_that(render(case, PROJECT_ROOT, tmp_path)).is_equal_to(expected)


def test_every_golden_fixture_has_a_case() -> None:
    """No fixture is left without the case that checks it."""
    names = sorted(path.stem for path in GOLDEN_DIR.glob("*"))
    assert_that(names).is_equal_to(sorted(case.name for case in CASES))
