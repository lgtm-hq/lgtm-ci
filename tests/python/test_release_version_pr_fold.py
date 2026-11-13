# SPDX-License-Identifier: MIT
"""Contract tests for the multi-ecosystem inputs folded into version-pr (#1356).

``reusable-release-version-pr.yml`` took over the inputs of
``reusable-release-multi-ecosystem.yml`` (``manifests``, ``bump``,
``version``, ``prerelease-tag``, ``changelog``; not ``job-name``) as optional
ones. A caller that passes none of them must get the run it got before.

The proof compares an effective projection of the workflow, rendered with the
input defaults, against the same projection of the workflow before the fold
(``fixtures/release_version_pr_fold/*.pre-1356.yml.txt``, verbatim from
``7c9bf5ab``). Per job it holds the rendered job fields and the steps that can
run. Each step ``if:`` becomes the truth table the ``gha_expr`` evaluator
gives over every step/needs output it reads and ``job.status``; a step whose
table is empty can never run under the defaults and is left out. ``with``,
``env`` and ``run`` are rendered with the defaults, and every other context
path renders as a ``<path>`` placeholder.
"""

from __future__ import annotations

import itertools
import re
import shlex
from collections.abc import Callable, Mapping
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "reusable-release-version-pr.yml"
BASELINE = (
    Path(__file__).resolve().parent
    / "fixtures"
    / "release_version_pr_fold"
    / "reusable-release-version-pr.pre-1356.yml.txt"
)
RELEASE = ROOT / "scripts" / "ci" / "release"

NEW_INPUTS = {
    "manifests": ("string", ""),
    "bump": ("string", "auto-from-commits"),
    "version": ("string", ""),
    "prerelease-tag": ("string", ""),
    "changelog": ("boolean", True),
}
# Env the version step gained: the selector (resolved into ``run``) and the
# resolver's inputs, which calculate-version.sh never reads (checked below).
VERSION_STEP = "Calculate next version"
VERSION_STEP_ENV = ("BUMP_MODE", "EXPLICIT_VERSION", "PRERELEASE_TAG", "VERSION_SCRIPT")
MANIFEST_STEP = "Run manifest version updaters"
GROUP = "reusable-release-version-pr-<github.repository>"
TOOLING = ".lgtm-ci-tooling/scripts/ci/release"
RESOLVER = "resolve-multi-ecosystem-version.sh"

_PATH = re.compile(
    r"\b(?:steps\.[\w-]+\.outputs\.[\w-]+|needs\.[\w-]+\.result|runner\.(?:os|environment))\b",
)
_UNSUPPORTED = re.compile(r"\b(?:contains|format|hashFiles|fromJSON|toJSON)\s*\(")
_ENV_REF = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}")
_STATUSES = ("success", "failure", "cancelled")
_RESULTS = ("success", "failure", "skipped", "cancelled")


class _Placeholders(dict[str, Any]):
    """Context that renders every unbound path as ``<path>``."""

    def get(self, key: str, default: Any = None) -> Any:
        """Return the bound value, else ``default`` or a ``<path>`` placeholder."""
        return dict.get(self, key, f"<{key}>" if default is None else default)


def _load(path: Path) -> dict[str, Any]:
    data: dict[Any, Any] = yaml.safe_load(path.read_text(encoding="utf-8"))
    if True in data:
        data["on"] = data.pop(True)
    return data


def _inputs(workflow: Mapping[str, Any]) -> dict[str, Any]:
    inputs: dict[str, Any] = workflow["on"]["workflow_call"]["inputs"]
    return inputs


def _context(workflow: Mapping[str, Any], **overrides: Any) -> dict[str, Any]:
    """Bind every input to its default, then apply ``overrides``."""
    inputs = _inputs(workflow)
    context = {f"inputs.{name}": spec.get("default") for name, spec in inputs.items()}
    context |= {f"inputs.{name}": value for name, value in overrides.items()}
    return context


def _domain(path: str) -> tuple[str, ...]:
    if path == "runner.os":
        return ("Linux", "macOS")
    if path == "runner.environment":
        return ("github-hosted", "self-hosted")
    if path.endswith(".result"):
        return _RESULTS
    if path.endswith("number"):
        return ("", "7")
    return ("true", "false", "")


def _truth_table(
    evaluator: ModuleType,
    condition: Any,
    context: dict[str, Any],
) -> Any:
    """Return the rows where ``condition`` holds, or its text if unsupported."""
    text = " ".join(str(condition).split())
    if _UNSUPPORTED.search(text):
        return f"raw: {text}"
    paths = sorted(set(_PATH.findall(text))) + ["job.status"]
    domains = [_STATUSES if p == "job.status" else _domain(p) for p in paths]
    rows = []
    for values in itertools.product(*domains):
        bound = dict(zip(paths, values, strict=True))
        if evaluator.evaluate(text, context | bound):
            rows.append(",".join(f"{p}={v}" for p, v in bound.items()))
    return rows


def _render(evaluator: ModuleType, value: Any, context: dict[str, Any]) -> Any:
    if not isinstance(value, str) or "${{" not in value:
        return value
    try:
        return evaluator.render(value, _Placeholders(context))
    except evaluator.ExpressionError:
        return f"raw: {' '.join(value.split())}"


def _render_all(
    evaluator: ModuleType,
    values: Mapping[str, Any] | None,
    context: dict[str, Any],
) -> dict[str, Any]:
    return {k: _render(evaluator, v, context) for k, v in (values or {}).items()}


def _resolve_run(run: str, env: Mapping[str, Any]) -> str:
    """Substitute rendered env values into ``run``; normalise one-liners."""
    resolved = _ENV_REF.sub(lambda m: str(env.get(m[1], m[0])), run)
    if "\n" not in resolved.strip():
        resolved = " ".join(shlex.split(resolved))
    return resolved


def _project_step(
    evaluator: ModuleType,
    step: Mapping[str, Any],
    context: dict[str, Any],
) -> dict[str, Any] | None:
    table = _truth_table(evaluator, step.get("if", "success()"), context)
    if table == []:
        return None
    env = _render_all(evaluator, step.get("env"), context)
    projected = {
        "name": step.get("name") or step.get("id"),
        "id": step.get("id"),
        "uses": step.get("uses"),
        "shell": step.get("shell"),
        "if": table,
        "with": _render_all(evaluator, step.get("with"), context),
        "env": env,
    }
    if "run" in step:
        projected["run"] = _resolve_run(str(step["run"]), env)
    return projected


def project(
    evaluator: ModuleType,
    workflow: Mapping[str, Any],
    **overrides: Any,
) -> dict[str, Any]:
    """Return the effective projection of a workflow for one set of inputs.

    Args:
        evaluator: The ``gha_expr`` module.
        workflow: The parsed workflow.
        **overrides: Input values that replace the defaults.

    Returns:
        Workflow-level fields and, per job, its rendered fields and the steps
        that can run.
    """
    context = _context(workflow, **overrides)
    jobs = {}
    for job_id, job in workflow["jobs"].items():
        steps = [_project_step(evaluator, step, context) for step in job["steps"]]
        fields = {k: v for k, v in job.items() if k not in ("steps", "concurrency")}
        jobs[job_id] = {
            **_render_all(evaluator, fields, context),
            "concurrency": _render_all(evaluator, job.get("concurrency"), context),
            "steps": [step for step in steps if step is not None],
        }
    call = workflow["on"]["workflow_call"]
    return {
        "name": workflow["name"],
        "env": workflow.get("env"),
        "permissions": workflow.get("permissions"),
        "secrets": call.get("secrets"),
        "outputs": call.get("outputs"),
        "jobs": jobs,
    }


def _strip_version_step_env(projection: dict[str, Any]) -> dict[str, Any]:
    for job in projection["jobs"].values():
        for step in job["steps"]:
            if step["name"] == VERSION_STEP:
                for name in VERSION_STEP_ENV:
                    step["env"].pop(name)
    return projection


def _steps(projection: Mapping[str, Any], job: str) -> dict[str, dict[str, Any]]:
    return {step["name"]: step for step in projection["jobs"][job]["steps"]}


@pytest.fixture(name="evaluator", scope="module")
def _evaluator(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the ``gha_expr`` evaluator."""
    return load_script("tests/helpers/gha_expr.py")


@pytest.fixture(name="current", scope="module")
def _current() -> dict[str, Any]:
    """Parse the current version-pr workflow."""
    return _load(WORKFLOW)


@pytest.fixture(name="baseline", scope="module")
def _baseline() -> dict[str, Any]:
    """Parse version-pr as it was before the fold."""
    return _load(BASELINE)


# --- default behaviour is unchanged ------------------------------------------


def test_new_inputs_are_optional_with_neutral_defaults(current: dict[str, Any]) -> None:
    """Each folded input is optional, typed, and defaults to today's path."""
    inputs = _inputs(current)
    for name, (kind, default) in NEW_INPUTS.items():
        assert inputs[name]["required"] is False, name
        assert inputs[name]["type"] == kind, name
        assert inputs[name]["default"] == default, name


def test_existing_inputs_keep_type_default_and_required(
    current: dict[str, Any],
    baseline: dict[str, Any],
) -> None:
    """No pre-fold input changed or disappeared (descriptions may)."""
    before, after = _inputs(baseline), _inputs(current)
    assert set(before) <= set(after)
    assert set(after) - set(before) == set(NEW_INPUTS)
    for name, spec in before.items():
        for field in ("type", "default", "required"):
            assert after[name].get(field) == spec.get(field), (name, field)


def test_default_projection_matches_the_pre_fold_workflow(
    evaluator: ModuleType,
    current: dict[str, Any],
    baseline: dict[str, Any],
) -> None:
    """Same runnable steps, if: tables, names, PR title/body and versioning."""
    expected = project(evaluator, baseline)
    actual = _strip_version_step_env(project(evaluator, current))
    for job in expected["jobs"]:
        assert actual["jobs"][job] == expected["jobs"][job], job
    assert actual == expected


def test_job_name_and_concurrency_stay_static(
    evaluator: ModuleType,
    current: dict[str, Any],
) -> None:
    """A literal job name keeps a skipped job's required context stable."""
    assert "job-name" not in _inputs(current)
    job = current["jobs"]["version-pr"]
    assert job["name"] == "Create Version PR"
    assert "${{" not in job["name"]
    rendered = project(evaluator, current)["jobs"]["version-pr"]
    assert rendered["concurrency"]["group"] == GROUP


@pytest.mark.parametrize("job", ["prepare", "version-pr"])
def test_default_version_step_runs_calculate_version(
    evaluator: ModuleType,
    current: dict[str, Any],
    job: str,
) -> None:
    """Without bump/prerelease-tag the step still runs calculate-version.sh."""
    step = _steps(project(evaluator, current), job)[VERSION_STEP]
    assert step["run"] == f"{TOOLING}/calculate-version.sh"
    assert step["env"]["MAX_BUMP"] == "minor"


def test_calculate_version_ignores_the_added_env() -> None:
    """The env added to the version step cannot steer calculate-version.sh."""
    sources = [RELEASE / "calculate-version.sh"]
    libs = ("log.sh", "github.sh", "release.sh")
    sources += [RELEASE.parent / "lib" / name for name in libs]
    for source in sources:
        text = source.read_text(encoding="utf-8")
        for name in VERSION_STEP_ENV:
            assert name not in text, (source.name, name)


def test_default_pr_body_keeps_an_empty_changelog_empty(
    evaluator: ModuleType,
    current: dict[str, Any],
    baseline: dict[str, Any],
) -> None:
    """An empty generated changelog renders as before, with no placeholder."""

    def body(workflow: Mapping[str, Any]) -> str:
        step = next(
            s
            for s in workflow["jobs"]["version-pr"]["steps"]
            if s.get("name") == "Create or update version PR"
        )
        context = _context(workflow) | {"steps.changelog.outputs.changelog": ""}
        return str(evaluator.render(step["with"]["body"], _Placeholders(context)))

    assert body(current) == body(baseline)
    assert "_No changelog entries._" not in body(current)


# --- new behaviour ------------------------------------------------------------


@pytest.mark.parametrize(
    ("overrides", "script"),
    [
        ({"bump": "explicit", "version": "v2.0.0"}, RESOLVER),
        ({"prerelease-tag": "rc.1"}, RESOLVER),
        ({"bump": "auto-from-commits"}, "calculate-version.sh"),
    ],
)
@pytest.mark.parametrize("job", ["prepare", "version-pr"])
def test_version_step_selects_the_resolver_for_bump_or_prerelease(
    evaluator: ModuleType,
    current: dict[str, Any],
    job: str,
    overrides: dict[str, Any],
    script: str,
) -> None:
    """bump/prerelease-tag route through the multi-ecosystem resolver."""
    step = _steps(project(evaluator, current, **overrides), job)[VERSION_STEP]
    assert step["run"] == f"{TOOLING}/{script}"
    assert (RELEASE / script).is_file()
    assert step["env"]["BUMP_MODE"] == overrides.get("bump", "auto-from-commits")
    assert step["env"]["EXPLICIT_VERSION"] == overrides.get("version", "")
    assert step["env"]["PRERELEASE_TAG"] == overrides.get("prerelease-tag", "")
    assert step["env"]["MAX_BUMP"] == "minor"


@pytest.mark.parametrize("job", ["version-update-hook", "version-pr"])
def test_changelog_false_skips_both_changelog_steps(
    evaluator: ModuleType,
    current: dict[str, Any],
    job: str,
) -> None:
    """changelog: false leaves neither changelog step runnable."""
    enabled = _steps(project(evaluator, current), job)
    disabled = _steps(project(evaluator, current, changelog=False), job)
    for name in ("Generate changelog", "Update CHANGELOG.md"):
        assert name in enabled
        assert name not in disabled
    assert set(enabled) - set(disabled) == {"Generate changelog", "Update CHANGELOG.md"}


def test_changelog_false_marks_the_pr_body(
    evaluator: ModuleType,
    current: dict[str, Any],
) -> None:
    """The PR body says there is no changelog instead of leaving a gap."""
    step = _steps(project(evaluator, current, changelog=False), "version-pr")[
        "Create or update version PR"
    ]
    template = next(
        s
        for s in current["jobs"]["version-pr"]["steps"]
        if s.get("name") == "Create or update version PR"
    )["with"]["body"]
    empty = {"steps.changelog.outputs.changelog": ""}
    context = _Placeholders(_context(current, changelog=False) | empty)
    assert "_No changelog entries._" in evaluator.render(template, context)
    assert "<steps.changelog.outputs.changelog>" in step["with"]["body"]


MANIFESTS = '{"package.json":"npm","VERSION":"raw"}'


@pytest.mark.parametrize(
    "case",
    [
        (
            "version-update-hook",
            "Run ecosystem version updaters",
            "Validate version update script",
            "<needs.prepare.outputs.next-version>",
        ),
        (
            "version-pr",
            "Run ecosystem version updaters",
            "Download version update changes",
            "<steps.version.outputs.next-version>",
        ),
    ],
)
def test_manifests_runs_the_manifest_updaters_after_ecosystems(
    evaluator: ModuleType,
    current: dict[str, Any],
    case: tuple[str, str, str, str],
) -> None:
    """manifests adds the manifests runner right after the ecosystem updaters."""
    job, previous, following, next_version = case
    assert MANIFEST_STEP not in _steps(project(evaluator, current), job)
    projected = project(
        evaluator,
        current,
        manifests=MANIFESTS,
        ecosystems="node",
        **{"version-update-script": "scripts/bump.sh"},
    )
    names = [step["name"] for step in projected["jobs"][job]["steps"]]
    index = names.index(MANIFEST_STEP)
    assert names[index - 1] == previous
    assert names[index + 1] == following
    step = _steps(projected, job)[MANIFEST_STEP]
    assert step["run"] == f"{TOOLING}/ecosystems/_manifests_runner.sh"
    assert step["env"] == {"NEXT_VERSION": next_version, "MANIFESTS": MANIFESTS}


def test_manifest_updater_in_the_hook_job_holds_no_credential(
    current: dict[str, Any],
) -> None:
    """The tokenless hook job stays tokenless with manifests (#849)."""
    hook = current["jobs"]["version-update-hook"]
    step = next(s for s in hook["steps"] if s.get("name") == MANIFEST_STEP)
    text = yaml.safe_dump(step)
    for marker in ("secrets.", "token", "GH_TOKEN", "github.token"):
        assert marker not in text, marker
    assert hook["permissions"] == {"contents": "read"}


@pytest.mark.parametrize(
    ("overrides", "expected"),
    [
        ({}, "false"),
        ({"manifests": MANIFESTS}, "true"),
        ({"ecosystems": "node"}, "true"),
        ({"version-update-script": "scripts/bump.sh"}, "true"),
    ],
)
def test_manifests_count_as_expected_version_files(
    evaluator: ModuleType,
    current: dict[str, Any],
    overrides: dict[str, Any],
    expected: str,
) -> None:
    """A manifests-only caller expects version files, like ecosystems."""
    step = _steps(project(evaluator, current, **overrides), "version-pr")[
        "Check for version file changes"
    ]
    assert step["env"]["EXPECT_VERSION_FILES"] == expected


def test_summary_reports_manifests_without_ecosystems(
    evaluator: ModuleType,
    current: dict[str, Any],
) -> None:
    """The summary lists the manifests when no ecosystems are set."""
    summary = _steps(project(evaluator, current, manifests=MANIFESTS), "version-pr")[
        "Write summary"
    ]
    assert summary["env"]["ECOSYSTEMS"] == MANIFESTS
    projected = project(evaluator, current, manifests=MANIFESTS, ecosystems="node")
    both = _steps(projected, "version-pr")
    assert both["Write summary"]["env"]["ECOSYSTEMS"] == "node"
