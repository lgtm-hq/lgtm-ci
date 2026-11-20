# SPDX-License-Identifier: MIT
"""``junit-artifact`` on ``reusable-publish-test-summary.yml`` end to end (#1686).

The renderer turns downloaded JUnit artifacts into results.v1 legs and a
comment: shards are summed, hostile reasons are sanitised, a missing or empty
artifact fails, an unreadable report never renders as a pass, and setting both
sources fails. The pytest parser takes marker reasons from a JUnit report of
the same run. The workflow declares the inputs, downloads with the pinned
action and adds no permission.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

import pytest
import yaml
from assertpy import assert_that

PROJECT_ROOT = Path(__file__).resolve().parents[2]
RENDER = PROJECT_ROOT / "scripts/ci/actions/render-test-summary.sh"
WORKFLOW = PROJECT_ROOT / ".github/workflows/reusable-publish-test-summary.yml"
JUNIT = PROJECT_ROOT / "tests/fixtures/junit"
PYTEST_PAIR = PROJECT_ROOT / "tests/fixtures/pytest/junit-pair.json"
#: The reason of the hostile pytest fixture, as pytest wrote it.
HOSTILE_REASON = " ".join(
    [
        "TICKET-12 @org/team #1 <img src=x> [x](javascript:y)",
        "<!-- lgtm-ci:history:start -->",
    ],
)
REJECT = "Reject conflicting test summary sources"
JUNIT_DOWNLOAD = "Download JUnit reports"
RESULTS_DOWNLOAD = "Download results documents"


def _render(tmp_path: Path, **env: str) -> tuple[subprocess.CompletedProcess[str], str]:
    """Run render-test-summary.sh with ``env``; return the result and comment."""
    comment = tmp_path / "comment.md"
    base = {
        "PATH": os.environ["PATH"],
        "HOME": str(tmp_path),
        "TEST_SUITE_NAME": "Python Tests",
        "COMMENT_OUTPUT": str(comment),
        "GITHUB_OUTPUT": str(tmp_path / "github-output"),
    }
    completed = subprocess.run(
        ["bash", str(RENDER)],
        env={**base, **env},
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
    )
    text = comment.read_text(encoding="utf-8") if comment.exists() else ""
    return completed, text


def _artifacts(tmp_path: Path, legs: dict[str, list[str]]) -> Path:
    """Lay out a download directory: one sub-directory per artifact name."""
    download = tmp_path / "junit-download"
    for name, files in legs.items():
        target = download / name / "reports"
        target.mkdir(parents=True)
        for source in files:
            shutil.copy(JUNIT / source, target / Path(source).name)
    return download


def test_shard_matrix_is_summed_and_reasons_are_sanitised(tmp_path: Path) -> None:
    """Two shard artifacts render one table with every count, reasons made safe."""
    download = _artifacts(
        tmp_path,
        {"reports-1": ["pytest-mixed.xml"], "reports-2": ["pytest-xfail.xml"]},
    )
    completed, comment = _render(tmp_path, JUNIT_DIR=str(download), EXPECTED_COUNT="2")
    assert_that(completed.returncode).described_as(completed.stderr).is_equal_to(0)
    assert_that(comment).contains(
        "| **Total Tests** | 16 |",
        "| **Passed** | 4 ✅ |",
        "| **Failed** | 4 ❌ |",
        "| **Skipped** | 1 |",
        "| **Expected failures** | 7 |",
        "Status: ❌ FAILED",
        "`pkg.test_x::test_xfail_raises`: TICKET-12",
    )
    assert_that(comment).does_not_contain(
        "<img",
        "<!-- lgtm-ci:history:start -->",
        "[x](javascript",
    )


def test_expected_count_applies_to_artifacts(tmp_path: Path) -> None:
    """results-expected-count fails the job when an artifact (leg) is missing."""
    download = _artifacts(tmp_path, {"reports-1": ["pytest-mixed.xml"]})
    completed, _comment = _render(
        tmp_path,
        JUNIT_DIR=str(download),
        EXPECTED_COUNT="2",
    )
    assert_that(completed.returncode).is_equal_to(1)
    assert_that(completed.stderr).contains("expected 2 results.json legs")


def test_caller_coverage_still_applies(tmp_path: Path) -> None:
    """coverage-percent is shown with junit-artifact; JUnit carries no coverage."""
    download = _artifacts(tmp_path, {"reports": ["pytest-xfail.xml"]})
    completed, comment = _render(
        tmp_path,
        JUNIT_DIR=str(download),
        COVERAGE_ENABLED="true",
        COVERAGE_PERCENT="87.5",
    )
    assert_that(completed.returncode).is_equal_to(0)
    assert_that(comment).contains("87.5%")


def test_unreadable_report_never_renders_a_pass(tmp_path: Path) -> None:
    """A hostile report gives the counts-unreadable comment and a warning."""
    download = _artifacts(tmp_path, {"reports": ["reader/entity-bomb.xml"]})
    completed, comment = _render(tmp_path, JUNIT_DIR=str(download))
    assert_that(completed.returncode).is_equal_to(0)
    assert_that(completed.stderr).contains(
        "::warning title=JUnit report unreadable::reports:",
    )
    assert_that(comment).contains("No test counts were parsed")
    assert_that(comment).does_not_contain("PASSED")


@pytest.mark.parametrize("layout", ["no-download", "no-artifact", "empty-artifact"])
def test_missing_or_empty_artifact_fails(tmp_path: Path, layout: str) -> None:
    """No artifact, or one without a matching file, fails the job by name."""
    download = tmp_path / "junit-download"
    if layout != "no-download":
        download.mkdir()
    if layout == "empty-artifact":
        (download / "reports").mkdir()
        (download / "reports" / "out.json").write_text("{}", encoding="utf-8")
    completed, comment = _render(tmp_path, JUNIT_DIR=str(download))
    assert_that(completed.returncode).is_equal_to(1)
    assert_that(completed.stderr).contains("::error title=JUnit")
    assert_that(comment).is_empty()


def test_junit_path_selects_files(tmp_path: Path) -> None:
    """junit-path limits which files of the artifact are read."""
    download = _artifacts(
        tmp_path,
        {"reports": ["pytest-mixed.xml", "pytest-xfail.xml"]},
    )
    completed, comment = _render(
        tmp_path,
        JUNIT_DIR=str(download),
        JUNIT_PATH="reports/pytest-xfail.xml",
    )
    assert_that(completed.returncode).is_equal_to(0)
    assert_that(comment).contains("| **Total Tests** | 7 |")


def test_both_sources_fail(tmp_path: Path) -> None:
    """JUNIT_DIR with RESULTS_DIR is refused before anything is read."""
    completed, comment = _render(
        tmp_path,
        JUNIT_DIR=str(tmp_path),
        RESULTS_DIR=str(tmp_path),
    )
    assert_that(completed.returncode).is_equal_to(1)
    assert_that(completed.stderr).contains(
        "junit-artifact and results-artifact-pattern cannot both be set",
    )
    assert_that(comment).is_empty()


def _xfail_report(name: str) -> str:
    """Return a one-test JUnit report whose test is an expected failure."""
    skipped = f'<skipped type="pytest.xfail" message="{name}"/>'
    case = f'<testcase classname="m" name="{name}">{skipped}</testcase>'
    return f'<testsuite name="s" tests="1" skipped="1">{case}</testsuite>\n'


def test_expected_failures_follow_artifact_order_past_nine(tmp_path: Path) -> None:
    """Twelve artifacts list their expected failures in artifact order (10 after 9)."""
    download = tmp_path / "junit-download"
    names = [f"shard-{index:02d}" for index in range(1, 13)]
    for name in names:
        (download / name).mkdir(parents=True)
        (download / name / "r.xml").write_text(_xfail_report(f"t{name}"))
    completed, comment = _render(tmp_path, JUNIT_DIR=str(download))
    assert_that(completed.returncode).described_as(completed.stderr).is_equal_to(0)
    listed = [line for line in comment.splitlines() if line.startswith("- `m::")]
    assert_that(listed).is_length(12)
    order = [line.split("`")[1].removeprefix("m::t") for line in listed]
    assert_that(order).is_equal_to(names)


def test_capped_list_keeps_its_omitted_count(tmp_path: Path) -> None:
    """Expected failures the reader only counted reach the document as omitted."""
    count = 130
    cases = "".join(
        f'<testcase classname="m" name="t{i}">'
        '<skipped type="pytest.xfail" message="r"/></testcase>'
        for i in range(count)
    )
    download = tmp_path / "junit-download"
    (download / "reports").mkdir(parents=True)
    (download / "reports" / "r.xml").write_text(
        f'<testsuite name="s" tests="{count}" skipped="{count}">{cases}</testsuite>',
    )
    scratch = tmp_path / "s.json"
    script = (
        "source scripts/ci/lib/testing/parse.sh"
        ' && RESULTS_SOURCE_VERSION=t junit_artifact_results_v1 "$1" "**/*.xml" "$2"'
    )
    completed = subprocess.run(
        ["bash", "-c", script, "bash", str(download / "reports"), str(scratch)],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    document = json.loads(completed.stdout)
    assert_that(document["counts"]["xfailed"]).is_equal_to(count)
    assert_that(document["expected_failures"]["tests"]).is_length(50)
    assert_that(document["expected_failures"]["omitted"]).is_equal_to(count - 50)


@pytest.mark.parametrize("junit_path", [".", "../x.xml", "/etc/*.xml"])
def test_bad_junit_path_is_a_clear_input_error(tmp_path: Path, junit_path: str) -> None:
    """A junit-path that cannot name files in the artifact fails with its reason."""
    download = _artifacts(tmp_path, {"reports": ["pytest-xfail.xml"]})
    completed, comment = _render(
        tmp_path,
        JUNIT_DIR=str(download),
        JUNIT_PATH=junit_path,
    )
    assert_that(completed.returncode).is_equal_to(1)
    assert_that(completed.stderr).contains(
        "::error title=invalid junit-path::junit-path must be a relative glob",
    )
    assert_that(comment).is_empty()


def test_artifact_name_in_the_warning_is_escaped(tmp_path: Path) -> None:
    """The artifact name in the unreadable warning keeps to a safe character set."""
    download = tmp_path / "junit-download"
    (download / "a%0A::b").mkdir(parents=True)
    (download / "a%0A::b" / "r.xml").write_text("<testsuite><bad")
    completed, _comment = _render(tmp_path, JUNIT_DIR=str(download))
    assert_that(completed.stderr).contains(
        "::warning title=JUnit report unreadable::a?0A??b:",
    )


def _pytest_document(*args: str) -> dict[str, Any]:
    """Return pytest_results_v1's document for the pair fixture and ``args``."""
    script = (
        "source scripts/ci/lib/testing/parse.sh"
        ' && RESULTS_SOURCE_VERSION=t pytest_results_v1 "$@"'
    )
    completed = subprocess.run(
        ["bash", "-c", script, "bash", str(PYTEST_PAIR), *args],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    document: dict[str, Any] = json.loads(completed.stdout)
    return document


def test_pytest_takes_marker_reasons_from_junit() -> None:
    """With the run's JUnit report the marker reasons replace the exceptions."""
    document = _pytest_document("", str(JUNIT / "pytest-mixed.xml"))
    assert_that(document["expected_failures"]["tests"]).is_equal_to(
        [
            {"id": "pkg/test_x.py::test_xfail_raises", "reason": HOSTILE_REASON},
            {"id": "pkg/test_x.py::TestC::test_p[1]", "reason": "param reason"},
            {"id": "pkg/test_x.py::TestC::test_p[2]", "reason": "param reason"},
        ],
    )
    assert_that(document["counts"]).is_equal_to(_pytest_document()["counts"])


@pytest.mark.parametrize("junit", ["", "missing.xml", "reader/entity-bomb.xml"])
def test_pytest_without_usable_junit_keeps_json_reasons(junit: str) -> None:
    """No JUnit report, or an unreadable one, leaves the JSON report's reasons."""
    args = ("", str(JUNIT / junit)) if junit else ()
    tests = _pytest_document(*args)["expected_failures"]["tests"]
    assert_that([entry["reason"] for entry in tests]).is_equal_to(
        ["ValueError: boom", "assert 1 == 0", "assert 2 == 0"],
    )


@pytest.fixture(name="workflow", scope="module")
def fixture_workflow() -> dict[Any, Any]:
    """Return the parsed summary workflow."""
    document: dict[Any, Any] = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    return document


def _steps(workflow: dict[Any, Any]) -> list[dict[str, Any]]:
    """Return the steps of the workflow's one job."""
    steps: list[dict[str, Any]] = workflow["jobs"]["publish-test-summary"]["steps"]
    return steps


def _step(workflow: dict[Any, Any], name: str) -> dict[str, Any]:
    """Return the step called ``name``."""
    return next(step for step in _steps(workflow) if step.get("name") == name)


def test_inputs_are_declared(workflow: dict[Any, Any]) -> None:
    """junit-artifact and junit-path are optional strings defaulting to empty."""
    # PyYAML reads the bare key "on" as True.
    inputs = workflow[True]["workflow_call"]["inputs"]
    for name in ("junit-artifact", "junit-path"):
        assert_that(inputs[name]).contains_entry(
            {"type": "string"},
            {"required": False},
            {"default": ""},
        )
    assert_that(inputs["junit-artifact"]["description"]).contains(
        "results-artifact-pattern fails the job",
    )


def test_download_uses_the_pinned_action(workflow: dict[Any, Any]) -> None:
    """The JUnit download uses the results download's pinned download-artifact."""
    junit = _step(workflow, JUNIT_DOWNLOAD)
    results = _step(workflow, RESULTS_DOWNLOAD)
    assert_that(junit["uses"]).is_equal_to(results["uses"]).matches(
        r"^actions/download-artifact@[0-9a-f]{40}$",
    )
    assert_that(junit["with"]).is_equal_to(
        {
            "pattern": "${{ inputs.junit-artifact }}",
            "path": "junit-download",
            "merge-multiple": False,
        },
    )
    assert_that(junit["if"]).contains(
        "inputs.junit-artifact != ''",
        "inputs.results-artifact-pattern == ''",
    )


def test_conflict_is_rejected_before_any_download(workflow: dict[Any, Any]) -> None:
    """Both sources set runs the reject script, ahead of both downloads."""
    names = [step.get("name") for step in _steps(workflow)]
    reject = _step(workflow, REJECT)
    assert_that(reject["if"]).is_equal_to(
        "inputs.junit-artifact != '' && inputs.results-artifact-pattern != ''",
    )
    assert_that(reject["run"]).contains(
        "scripts/ci/actions/reject-test-summary-sources.sh",
    )
    downloads = [
        index
        for index, step in enumerate(_steps(workflow))
        if "download-artifact" in str(step.get("uses", ""))
    ]
    assert_that(downloads).is_length(3)
    assert_that(names.index(REJECT)).is_less_than(min(downloads))


def test_renderer_receives_the_junit_directory(workflow: dict[Any, Any]) -> None:
    """The render step gets the download directory and the glob."""
    env = _step(workflow, "Generate test run summary")["env"]
    assert_that(env).contains_entry(
        {"JUNIT_DIR": "${{ inputs.junit-artifact != '' && 'junit-download' || '' }}"},
        {"JUNIT_PATH": "${{ inputs.junit-path }}"},
    )


def test_no_permission_is_added(workflow: dict[Any, Any]) -> None:
    """The job keeps exactly contents: read and pull-requests: write."""
    permissions = workflow["jobs"]["publish-test-summary"]["permissions"]
    assert_that(permissions).is_equal_to({"contents": "read", "pull-requests": "write"})
    assert_that(workflow).does_not_contain_key("permissions")
