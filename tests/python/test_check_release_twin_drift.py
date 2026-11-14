# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/workflows/check-release-twin-drift.py`` (#1356).

The real-repository test is the CI hook: ``python-tests`` runs every test
here on each PR, so drift between the release twins fails that job.
"""

from __future__ import annotations

import copy
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
import yaml
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/workflows/check-release-twin-drift.py"
JOBS = ("prepare", "version-update-hook", "version-pr", "report-release-failure")
CHECKOUT = {"name": "Checkout", "uses": "actions/checkout@abc"}


@pytest.fixture(name="drift", scope="module")
def fixture_drift(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the drift check without running it."""
    return load_script(SCRIPT_PATH)


def _upload(name: str) -> dict[str, Any]:
    """Return an upload-artifact step with the given artifact name."""
    return {
        "name": "Upload metadata",
        "uses": "actions/upload-artifact@abc",
        "with": {"name": name, "path": "out"},
    }


def _twin(namespace: str) -> dict[str, Any]:
    """Return a minimal twin whose artifacts and concurrency use ``namespace``.

    Args:
        namespace: The per-twin prefix for artifacts and concurrency.

    Returns:
        A parsed workflow with the four checked jobs.
    """
    jobs: dict[str, Any] = {job: {"steps": [CHECKOUT]} for job in JOBS}
    jobs["prepare"]["steps"] = [CHECKOUT, _upload(f"{namespace}-metadata")]
    jobs["version-pr"]["concurrency"] = {"group": f"{namespace}-group"}
    return {
        "on": {
            "workflow_call": {
                "inputs": {"auto-merge": {"type": "boolean", "default": False}},
                "secrets": {"TOKEN": {"required": False}},
            },
        },
        "permissions": {"contents": "read"},
        "jobs": jobs,
    }


@pytest.fixture(name="twins")
def fixture_twins() -> tuple[dict[str, Any], dict[str, Any]]:
    """Return a version-pr and multi-ecosystem pair with no drift."""
    return _twin("release-version-pr"), _twin("release-multi-ecosystem")


# The fixture twins differ only in their namespaced artifact and group.
INTENDED = {
    ("prepare", "Upload metadata", "with.name"): "namespaced",
    ("version-pr", None, "concurrency.group"): "namespaced",
}
Twins = tuple[dict[str, Any], dict[str, Any]]


RunCheck = Callable[[tuple[dict[str, Any], dict[str, Any]], dict[Any, str]], int]


@pytest.fixture(name="run_check")
def fixture_run_check(
    drift: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> RunCheck:
    """Return a runner that writes the twins to ``tmp_path`` and calls ``main``.

    Args:
        drift: The loaded script module.
        tmp_path: Directory for the fixture YAML files.
        monkeypatch: Used to replace ``INTENDED_DIFFERENCES``.

    Returns:
        A callable taking the twins and the allowlist, returning the exit code.
    """

    def run(
        twins: Twins,
        intended: dict[Any, str],
    ) -> int:
        left, right = tmp_path / "version-pr.yml", tmp_path / "multi.yml"
        left.write_text(yaml.safe_dump(twins[0]), encoding="utf-8")
        right.write_text(yaml.safe_dump(twins[1]), encoding="utf-8")
        monkeypatch.setattr(drift, "INTENDED_DIFFERENCES", intended)
        result: int = drift.main(
            ["--version-pr", str(left), "--multi-ecosystem", str(right)],
        )
        return result

    return run


def test_real_repository_passes(
    drift: ModuleType,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The committed twins are in sync with the recorded differences."""
    code = drift.main([])

    assert_that(capsys.readouterr().err).is_empty()
    assert_that(code).is_equal_to(0)


def test_fixture_twins_pass(
    run_check: RunCheck,
    twins: Twins,
) -> None:
    """The baseline fixture pair has no drift."""
    assert_that(run_check(twins, INTENDED)).is_equal_to(0)


def test_unquoted_on_key_is_read(drift: ModuleType, tmp_path: Path) -> None:
    """An unquoted ``on:`` (parsed as ``True``) still yields the secrets."""
    path = tmp_path / "w.yml"
    path.write_text("on:\n  workflow_call:\n    secrets: {A: {}}\n", "utf-8")

    workflow = drift.load_workflow(path)

    assert_that(workflow["on"]["workflow_call"]["secrets"]).is_equal_to({"A": {}})


def test_changed_shared_step_fails(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A shared step edited in one twin only is reported with its fields."""
    changed = dict(CHECKOUT, uses="actions/checkout@def")
    twins[1]["jobs"]["version-pr"]["steps"] = [changed]

    code = run_check(twins, INTENDED)

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "version-pr: step 'Checkout' differs in 'uses'",
    )


def test_unrecorded_one_sided_step_fails(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A step added to one twin only fails until it is recorded."""
    twins[0]["jobs"]["version-update-hook"]["steps"].append(
        {"id": "extra", "run": "true"},
    )

    code = run_check(twins, INTENDED)

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "version-update-hook: step 'extra' exists only in the version-pr twin",
    )


def test_unrecorded_difference_fails(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Without its allowlist entry, the namespaced upload step is drift."""
    code = run_check(twins, {})

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "prepare: step 'Upload metadata' differs in 'with.name'",
    )


def test_stale_entry_for_identical_step_fails(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """An entry for a step that is now identical must be removed."""
    intended = {**INTENDED, ("report-release-failure", "Checkout", "uses"): "old"}

    code = run_check(twins, intended)

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "report-release-failure: INTENDED_DIFFERENCES entry for step 'Checkout' "
        "field 'uses' is stale",
    )


def test_stale_entry_for_removed_step_fails(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """An entry for a step neither twin has any longer must be removed."""
    intended = {**INTENDED, ("prepare", "Gone", "*"): "old"}

    code = run_check(twins, intended)

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "prepare: INTENDED_DIFFERENCES entry for step 'Gone' is stale; neither",
    )


def test_secrets_mismatch_fails(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A secret declared in one twin only is reported."""
    twins[1]["on"]["workflow_call"]["secrets"]["EXTRA"] = {"required": False}

    code = run_check(twins, INTENDED)

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "on.workflow_call.secrets differ",
    )


def test_collided_artifact_name_fails(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Both twins uploading the same artifact name is a collision."""
    twins[1]["jobs"]["prepare"]["steps"] = copy.deepcopy(
        twins[0]["jobs"]["prepare"]["steps"],
    )

    code = run_check(twins, {})

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "artifact name 'release-version-pr-metadata' is used by both twins",
    )


@pytest.mark.parametrize(
    "concurrency",
    [{"group": "shared"}, "shared"],
    ids=["mapping", "string"],
)
def test_collided_concurrency_group_fails(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
    concurrency: Any,
) -> None:
    """Both twins taking the same concurrency group is a collision."""
    twins[0]["jobs"]["version-pr"]["concurrency"] = {"group": "shared"}
    twins[1]["concurrency"] = concurrency

    code = run_check(twins, INTENDED)

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "concurrency group 'shared' is used by both twins",
    )


def test_missing_job_fails(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A checked job absent from a twin is reported, not skipped."""
    del twins[1]["jobs"]["report-release-failure"]

    code = run_check(twins, INTENDED)

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "report-release-failure: job exists only in the version-pr twin",
    )


def test_repeated_step_names_get_ordinals(drift: ModuleType) -> None:
    """A repeated name is keyed by occurrence; an anonymous step is a problem."""
    keys, problems = drift.keyed_steps(
        {"steps": [CHECKOUT, {"run": "x"}, CHECKOUT]},
    )

    assert_that(list(keys)).is_equal_to([("Checkout", 1), ("Checkout", 2)])
    assert_that(problems).is_equal_to(["step 2 has neither a name nor an id"])


def test_unreadable_file_is_an_error(
    drift: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A missing file exits 2, never 1."""
    missing = str(tmp_path / "missing.yml")

    code = drift.main(["--version-pr", missing, "--multi-ecosystem", missing])

    assert_that(code).is_equal_to(2)
    assert_that(capsys.readouterr().err).contains("cannot load the release twins")


def test_job_permission_change_fails(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Granting a permission to one twin's job is drift (Sol's repro)."""
    twins[0]["jobs"]["prepare"]["permissions"] = {"contents": "read"}
    twins[1]["jobs"]["prepare"]["permissions"] = {
        "contents": "read",
        "id-token": "write",
    }

    code = run_check(twins, INTENDED)

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "prepare: job-level field differs in 'permissions.id-token'",
    )


def test_allowlisted_step_with_extra_changed_field_fails(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """An entry covers its one field; the step's other fields must match."""
    upload = twins[1]["jobs"]["prepare"]["steps"][1]
    upload["if"] = False
    upload["with"]["path"] = "/etc"

    code = run_check(twins, INTENDED)

    err = capsys.readouterr().err
    assert_that(code).is_equal_to(1)
    assert_that(err).contains("step 'Upload metadata' differs in 'if'")
    assert_that(err).contains("step 'Upload metadata' differs in 'with.path'")


def test_whole_step_entry_for_shared_step_fails(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A whole-step entry cannot hide a shared step's differences."""
    intended = {**INTENDED, ("prepare", "Upload metadata", "*"): "too broad"}

    code = run_check(twins, intended)

    message = "step 'Upload metadata' is in both twins, so its whole entry"
    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(f"prepare: {message} is stale")


def test_generated_key_cannot_collide_with_a_real_name(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``[A, A #2]`` vs ``[A, A(changed), A #2]`` is drift (Sol's repro)."""
    step_a = {"name": "A", "run": "a"}
    step_a2 = {"name": "A #2", "run": "a2"}
    twins[0]["jobs"]["version-pr"]["steps"] = [step_a, step_a2]
    twins[1]["jobs"]["version-pr"]["steps"] = [
        step_a,
        {"name": "A", "run": "changed"},
        step_a2,
    ]

    code = run_check(twins, INTENDED)

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "version-pr: step 'A' (occurrence 2) exists only in the multi-ecosystem",
    )


def test_swapped_shared_steps_fail(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Shared steps in another relative order are drift (Sol's repro)."""
    harden = {"name": "Harden runner", "uses": "harden@abc"}
    preset = {"name": "Fail on unknown egress-preset", "run": "check"}
    twins[0]["jobs"]["version-update-hook"]["steps"] = [harden, preset]
    twins[1]["jobs"]["version-update-hook"]["steps"] = [preset, harden]

    code = run_check(twins, INTENDED)

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "version-update-hook: shared steps are out of order; version-pr has "
        "step 'Harden runner' where multi-ecosystem has step 'Fail on unknown",
    )


def test_workflow_permission_change_fails(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A workflow-level permission granted in one twin is drift (Sol's repro)."""
    twins[1]["permissions"]["id-token"] = "write"

    code = run_check(twins, INTENDED)

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "(workflow): workflow field differs in 'permissions.id-token'",
    )


def test_shared_input_default_change_fails(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A shared input's default changed in one twin is drift (Sol's repro)."""
    twins[1]["on"]["workflow_call"]["inputs"]["auto-merge"]["default"] = True

    code = run_check(twins, INTENDED)

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        "on.workflow_call.inputs: input 'auto-merge' differs in 'default'",
    )


def test_one_sided_input_needs_a_whole_entry(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """An input in one twin only fails until recorded, then passes."""
    twins[1]["on"]["workflow_call"]["inputs"]["job-name"] = {"type": "string"}
    entry = ("on.workflow_call.inputs", "job-name", "*")

    unrecorded = run_check(twins, INTENDED)
    recorded = run_check(twins, {**INTENDED, entry: "API"})

    assert_that(unrecorded).is_equal_to(1)
    assert_that(recorded).is_equal_to(0)
    assert_that(capsys.readouterr().err).contains(
        "input 'job-name' exists only in the multi-ecosystem twin",
    )


def test_one_sided_extra_job_fails(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A job only one twin has fails until recorded as a whole entry."""
    twins[1]["jobs"]["extra"] = {"steps": [CHECKOUT]}

    unrecorded = run_check(twins, INTENDED)
    recorded = run_check(twins, {**INTENDED, ("extra", None, "*"): "reason"})

    assert_that(unrecorded).is_equal_to(1)
    assert_that(recorded).is_equal_to(0)
    assert_that(capsys.readouterr().err).contains(
        "extra: job exists only in the multi-ecosystem twin",
    )


def test_stale_input_entry_fails(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Entries for an agreeing input field or a missing input are stale."""
    intended = {
        **INTENDED,
        ("on.workflow_call.inputs", "auto-merge", "default"): "old",
        ("on.workflow_call.inputs", "gone", "*"): "old",
    }

    code = run_check(twins, intended)

    err = capsys.readouterr().err
    assert_that(code).is_equal_to(1)
    assert_that(err).contains(
        "INTENDED_DIFFERENCES entry for input 'auto-merge' field 'default' is stale",
    )
    assert_that(err).contains(
        "INTENDED_DIFFERENCES entry for input 'gone' is stale; neither twin",
    )


def test_entry_for_unknown_job_is_stale(
    run_check: RunCheck,
    twins: Twins,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """An entry naming a job neither twin has fails."""
    code = run_check(twins, {**INTENDED, ("ghost", None, "*"): "old"})

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains("neither twin has that job")


def test_artifact_names_skips_malformed_steps(drift: ModuleType) -> None:
    """Malformed steps or ``with:`` values are skipped, not crashed on."""
    workflow = {
        "jobs": {
            "prepare": {
                "steps": [
                    "not-a-step",
                    {"uses": "actions/upload-artifact@v4", "with": "not-a-map"},
                    _upload("kept"),
                ],
            },
        },
    }
    assert_that(drift.artifact_names(workflow)).is_equal_to({"kept"})
