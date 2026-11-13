# SPDX-License-Identifier: MIT
"""Verdicts must not report success for a job that ended red (#1203).

The generated "Recheck harden-runner agent" step is the last step of every
job with the startup verify step, so it runs after the steps that set a job's
`passed`/`status`/`exit-code` outputs. When it fails, the job is red but those
outputs still say success. Every exported verdict and every PR test-summary
`job-result` must therefore also require the job's own `result`.
"""

from __future__ import annotations

import re
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
import yaml

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
DOCS = Path(__file__).resolve().parents[2] / "docs"

# Exported outputs that carry a pass/fail verdict, with their failure value.
VERDICT_OUTPUTS = {
    "passed": "false",
    "status": "failed",
    "build-passed": "false",
    "test-passed": "false",
}
# exit-code is a verdict only for the gates and quality-lint (whose callers
# pass it to reusable-publish-quality-summary); elsewhere it is a tool's code.
GATE_WORKFLOWS = (
    "reusable-all-checks-gate.yml",
    "reusable-required-check.yml",
    "reusable-quality-lint.yml",
)
JOB_OUTPUT = re.compile(r"\bjobs\.([A-Za-z0-9_-]+)\.outputs\.")
NEEDS_PASSED = re.compile(r"\bneeds\.([A-Za-z0-9_-]+)\.outputs\.passed\b")
PUBLISHER = "reusable-publish-test-summary.yml"
# A `job-result:` value in docs/examples: its line plus `${{`/`&&` continuations.
DOC_JOB_RESULT = re.compile(r"job-result:(.*\n(?:[ \t]+(?:&&|\$).*\n)*)")
QUALITY_LINT = "reusable-quality-lint.yml"
QUALITY_SUMMARY = "reusable-publish-quality-summary.yml"
NEEDS_EXIT_CODE = re.compile(r"\bneeds\.([A-Za-z0-9_-]+)\.outputs\.exit-code\b")
YAML_FENCE = re.compile(r"^```ya?ml\n(.*?)^```", re.M | re.S)

EXPECTED_EXPORTS = {
    ("reusable-coverage.yml", "passed"),
    ("reusable-quality-lint.yml", "exit-code"),
    ("reusable-quality-lint.yml", "status"),
    ("reusable-rust-build.yml", "passed"),
    ("reusable-rust-test-run.yml", "passed"),
    ("reusable-rust-test.yml", "passed"),
    ("reusable-security-audit.yml", "status"),
    ("reusable-site-quality.yml", "build-passed"),
    ("reusable-site-quality.yml", "passed"),
    ("reusable-site-quality.yml", "test-passed"),
    ("reusable-test-e2e-playwright.yml", "passed"),
    ("reusable-test-e2e.yml", "passed"),
    ("reusable-test-node-custom.yml", "passed"),
    ("reusable-test-node-run.yml", "passed"),
    ("reusable-test-node.yml", "passed"),
    ("reusable-test-python.yml", "passed"),
    ("reusable-test-rust-build.yml", "passed"),
    ("reusable-test-shell-run.yml", "passed"),
    ("reusable-test-shell.yml", "passed"),
    ("reusable-validate.yml", "status"),
    ("reusable-all-checks-gate.yml", "status"),
    ("reusable-all-checks-gate.yml", "exit-code"),
    ("reusable-required-check.yml", "status"),
    ("reusable-required-check.yml", "exit-code"),
}
EXPECTED_PUBLISHERS = {
    "reusable-coverage.yml",
    "reusable-rust-test.yml",
    "reusable-test-e2e-playwright.yml",
    "reusable-test-node-custom.yml",
    "reusable-test-node.yml",
    "reusable-test-python.yml",
}


def _load(path: Path) -> dict[Any, Any]:
    loaded: dict[Any, Any] = yaml.safe_load(path.read_text())
    return loaded


def _call_outputs(workflow: dict[Any, Any]) -> dict[str, Any]:
    triggers = workflow.get("on", workflow.get(True)) or {}
    if not isinstance(triggers, dict):
        return {}
    call = triggers.get("workflow_call") or {}
    return call.get("outputs") or {}


def _verdict_exports() -> dict[tuple[str, str], str]:
    found = {}
    for path in sorted(WORKFLOWS.glob("*.yml")):
        outputs = _call_outputs(_load(path))
        for name, spec in outputs.items():
            is_verdict = name in VERDICT_OUTPUTS or (
                name == "exit-code" and path.name in GATE_WORKFLOWS
            )
            if is_verdict and JOB_OUTPUT.search(str(spec["value"])):
                found[(path.name, name)] = str(spec["value"])
    return found


def _publisher_results() -> dict[str, str]:
    found = {}
    for path in sorted(WORKFLOWS.glob("*.yml")):
        for job in (_load(path).get("jobs") or {}).values():
            if not str(job.get("uses", "")).endswith(PUBLISHER):
                continue
            value = str((job.get("with") or {}).get("job-result", ""))
            if NEEDS_PASSED.search(value):
                found[path.name] = value
    return found


def test_every_exported_verdict_requires_the_job_result() -> None:
    """A red job never exports passed/status/exit-code success."""
    exports = _verdict_exports()
    assert set(exports) == EXPECTED_EXPORTS
    for key, value in exports.items():
        for job in set(JOB_OUTPUT.findall(value)):
            assert f"jobs.{job}.result" in value, (key, job)


def test_every_publisher_job_result_requires_the_job_result() -> None:
    """PR test-summary comments never render a red job as a pass."""
    publishers = _publisher_results()
    assert set(publishers) == EXPECTED_PUBLISHERS
    for name, value in publishers.items():
        for job in set(NEEDS_PASSED.findall(value)):
            assert f"needs.{job}.result == 'success'" in value, (name, job)


def test_docs_and_examples_job_result_requires_the_job_result() -> None:
    """Documented and example callers follow the same rule."""
    root = DOCS.parent
    sources = [*DOCS.rglob("*.md"), *(root / "examples").glob("*.yml")]
    checked = 0
    for path in sources:
        text = path.read_text()
        for match in DOC_JOB_RESULT.finditer(text):
            block = match[1]
            for job in set(NEEDS_PASSED.findall(block)):
                checked += 1
                assert f"needs.{job}.result == 'success'" in block, (path, block)
    assert checked >= 1


def _render(
    evaluator: ModuleType,
    template: str,
    context: dict[str, Any],
) -> str:
    rendered = evaluator.render(template, context)
    if isinstance(rendered, bool):
        return "true" if rendered else "false"
    return "" if rendered is None else str(rendered)


def _single_job_exports() -> list[tuple[str, str, str, str]]:
    """Exports over one job, evaluable without format()/fromJson()."""
    cases = []
    for (name, output), value in sorted(_verdict_exports().items()):
        jobs = set(JOB_OUTPUT.findall(value))
        if len(jobs) == 1 and "format(" not in value:
            cases.append((name, output, jobs.pop(), value))
    return cases


@pytest.mark.parametrize(
    ("name", "output", "job", "value"),
    [pytest.param(*case, id=f"{case[0]}:{case[1]}") for case in _single_job_exports()],
)
def test_export_reports_failure_when_the_job_failed(
    load_script: Callable[[str], ModuleType],
    name: str,
    output: str,
    job: str,
    value: str,
) -> None:
    """The step output says success but the recheck failed the job."""
    evaluator = load_script("tests/helpers/gha_expr.py")
    success = {"passed": "true", "status": "passed", "exit-code": "0"}
    source = output if output in success else "passed"
    key = f"jobs.{job}.outputs.{source}"
    good = success[source]
    failure = VERDICT_OUTPUTS.get(output, "1")
    red = {f"jobs.{job}.result": "failure", key: good}
    assert _render(evaluator, value, red) == failure, name
    green = {f"jobs.{job}.result": "success", key: good}
    assert _render(evaluator, value, green) == good, name


def test_site_quality_combined_passed_requires_both_results(
    load_script: Callable[[str], ModuleType],
) -> None:
    """Either red job turns the combined verdict false."""
    evaluator = load_script("tests/helpers/gha_expr.py")
    value = _verdict_exports()[("reusable-site-quality.yml", "passed")]
    base = {
        "jobs.site-build-link.result": "success",
        "jobs.site-build-link.outputs.passed": "true",
        "jobs.site-test.result": "success",
        "jobs.site-test.outputs.passed": "true",
    }
    assert _render(evaluator, value, base) == "true"
    for job in ("site-build-link", "site-test"):
        red = base | {f"jobs.{job}.result": "failure"}
        assert _render(evaluator, value, red) == "false", job


@pytest.mark.parametrize(
    "name",
    ["reusable-test-shell.yml", "reusable-test-shell-run.yml"],
)
def test_shell_passed_candidates_require_their_job_result(
    load_script: Callable[[str], ModuleType],
    name: str,
) -> None:
    """Both format() candidates (single job and sharded aggregate) are guarded."""
    evaluator = load_script("tests/helpers/gha_expr.py")
    value = _verdict_exports()[(name, "passed")]
    args = re.search(r"format\('\[\"\{0\}\",\"\{1\}\"\]',(.*)\)\)\[", value, re.S)
    assert args is not None, value
    candidates = [part.strip() for part in args[1].split(",")]
    assert len(candidates) == 2
    for candidate, job in zip(candidates, ("test", "aggregate"), strict=True):
        template = f"${{{{ {candidate} }}}}"
        red = {f"jobs.{job}.result": "failure", f"jobs.{job}.outputs.passed": "true"}
        assert _render(evaluator, template, red) == "false", (name, job)
        green = red | {f"jobs.{job}.result": "success"}
        assert _render(evaluator, template, green) == "true", (name, job)


@pytest.mark.parametrize("name", sorted(EXPECTED_PUBLISHERS))
def test_publisher_reports_failure_when_the_job_failed(
    load_script: Callable[[str], ModuleType],
    name: str,
) -> None:
    """Aggregate said passed, but the job went red: the comment says failure."""
    evaluator = load_script("tests/helpers/gha_expr.py")
    value = _publisher_results()[name]
    (job,) = set(NEEDS_PASSED.findall(value))
    passed = {f"needs.{job}.outputs.passed": "true"}
    red = passed | {f"needs.{job}.result": "failure"}
    assert _render(evaluator, value, red) == "failure"
    green = passed | {f"needs.{job}.result": "success"}
    assert _render(evaluator, value, green) == "success"
    failed = {f"needs.{job}.result": "success", f"needs.{job}.outputs.passed": "false"}
    assert _render(evaluator, value, failed) == "failure"


def test_quality_lint_exit_code_only_flips_a_pass(
    load_script: Callable[[str], ModuleType],
) -> None:
    """A red quality job reports 1 instead of 0; lintro's own codes pass through."""
    evaluator = load_script("tests/helpers/gha_expr.py")
    value = _verdict_exports()[(QUALITY_LINT, "exit-code")]
    red = {"jobs.quality.result": "failure", "jobs.quality.outputs.exit-code": "0"}
    assert _render(evaluator, value, red) == "1"
    green = red | {"jobs.quality.result": "success"}
    assert _render(evaluator, value, green) == "0"
    lint = {"jobs.quality.result": "failure", "jobs.quality.outputs.exit-code": "2"}
    assert _render(evaluator, value, lint) == "2"


def _job_maps(path: Path) -> list[dict[Any, Any]]:
    """Job mappings of a workflow file or of each YAML block in a Markdown file."""
    if path.suffix == ".md":
        documents = [
            yaml.safe_load(block)
            for block in YAML_FENCE.findall(path.read_text())
            if QUALITY_SUMMARY in block
        ]
    else:
        documents = [_load(path)]
    maps = []
    for document in documents:
        assert isinstance(document, dict), path
        jobs = document.get("jobs", document)
        assert isinstance(jobs, dict), path
        maps.append(jobs)
    return maps


def _quality_summary_callers() -> list[tuple[Path, str, dict[Any, Any]]]:
    """Every job in workflows, examples and docs that calls the quality summary."""
    root = DOCS.parent
    sources = [
        *sorted(WORKFLOWS.glob("*.yml")),
        *sorted((root / "examples").glob("*.yml")),
        *sorted(DOCS.rglob("*.md")),
        root / "README.md",
    ]
    callers = []
    for path in sources:
        if QUALITY_SUMMARY not in path.read_text():
            continue
        for jobs in _job_maps(path):
            for name, job in jobs.items():
                uses = str(job.get("uses", "")) if isinstance(job, dict) else ""
                if uses.split("@", maxsplit=1)[0].endswith(QUALITY_SUMMARY):
                    callers.append((path, name, jobs))
    return callers


def test_quality_summary_callers_read_a_gated_exit_code() -> None:
    """No caller renders a red quality-lint job as a pass (#1203).

    Each publish-quality-summary caller either passes the gated exit-code
    export of a reusable-quality-lint job or guards with needs.<job>.result.
    """
    callers = _quality_summary_callers()
    # ci.yml, four examples, getting-started, reusable-workflows (twice) and
    # workflow-contract.
    assert len(callers) >= 9, callers
    for path, name, jobs in callers:
        value = str((jobs[name].get("with") or {}).get("exit-code", ""))
        sources = set(NEEDS_EXIT_CODE.findall(value))
        assert sources, (path, name, value)
        for job in sources:
            uses = str((jobs.get(job) or {}).get("uses", "")).split("@", maxsplit=1)[0]
            gated = uses.endswith(QUALITY_LINT)
            assert gated or f"needs.{job}.result" in value, (path, name, value)
