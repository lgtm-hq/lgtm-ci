#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Check that the two release version PR workflows have not drifted (#1356).

``reusable-release-version-pr.yml`` and ``reusable-release-multi-ecosystem.yml``
are twins: the same jobs, mostly the same steps, and the same secrets. They
differ in their API surface (ecosystems vs manifests, versioning, changelog,
job name) and in their namespaces (artifacts, concurrency, failure reports).
This check keeps the shared part shared and the namespaces apart:

- every workflow-level field (``name``, ``on``, ``permissions``, ``env``,
  ``defaults``, ``concurrency`` and any other key except ``jobs``) is
  identical;
- every ``on.workflow_call`` input and output both twins have is identical
  field by field (``type``, ``default``, ``required``, ``description``);
- both twins have the same jobs, derived from the files;
- every job-level field (``permissions``, ``if``, ``needs``, ``runs-on`` and
  any other key except ``steps``) is identical;
- every step both twins have, per job, is identical field by field, and the
  shared steps appear in the same relative order;
- every intended difference is recorded in :data:`INTENDED_DIFFERENCES`,
  keyed ``(scope, item, field path)`` with a reason; a step, input, output or
  job in one twin only needs a whole entry (field ``*``); a recorded
  difference that no longer exists is stale and fails;
- ``on.workflow_call.secrets`` is identical;
- no artifact name and no ``concurrency.group`` is shared between the twins.

Steps are matched by ``name``, falling back to ``id``, plus the occurrence of
that name within the job: ``("Checkout repository", 2)`` is the second step so
named. A step with neither name nor id cannot be matched and fails.

Field paths join nested mapping keys with dots (``with.name``,
``env.RELEASE_WORKFLOW_KEY``, ``concurrency.group``); lists compare whole.

Usage:
    python3 scripts/ci/workflows/check-release-twin-drift.py \
        [--version-pr PATH] [--multi-ecosystem PATH]

Exit codes:
    0 - no drift
    1 - one or more violations, one line each on stderr
    2 - a file could not be read or parsed
"""

# pylint: disable=invalid-name  # the hyphenated CLI filename is the contract

from __future__ import annotations

import argparse
import sys
from collections.abc import Callable, Iterator, Mapping
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[3]
WORKFLOWS = ROOT / ".github" / "workflows"
VERSION_PR = WORKFLOWS / "reusable-release-version-pr.yml"
MULTI_ECOSYSTEM = WORKFLOWS / "reusable-release-multi-ecosystem.yml"

ARTIFACT_ACTIONS = ("actions/upload-artifact@", "actions/download-artifact@")

# Entry scopes besides job names. Job ids cannot hold "(" or ".", so these
# never collide with a job.
WORKFLOW = "(workflow)"
INPUTS = "on.workflow_call.inputs"
OUTPUTS = "on.workflow_call.outputs"
SECRETS = "on.workflow_call.secrets"
INTERFACE = {INPUTS: "input", OUTPUTS: "output"}

# The item slot of an entry for a job-level or workflow-level field.
JOB = None
# The field slot of an entry for a step, input, output or job in one twin only.
WHOLE = "*"

EXIT_OK = 0
EXIT_DRIFT = 1
EXIT_ERROR = 2

StepKey = tuple[str, int]
# A step in an entry: its name (first occurrence), a StepKey, or JOB.
StepRef = str | StepKey | None
# (scope, item, field): scope is a job name, WORKFLOW, INPUTS or OUTPUTS; item
# is a StepRef in a job scope, an input or output name, or None.
Entry = tuple[str, StepRef, str]

# Reasons shared by several entries below.
_NAMESPACE = "artifact names and failure keys are namespaced per twin"
_VERSIONING = "multi-ecosystem resolves bump/version/prerelease-tag inputs"
_UPDATERS = "version-pr runs ecosystem updaters; multi-ecosystem runs manifests"
_RUST = "only version-pr supports the rust ecosystem"
_CHANGELOG_GATE = "multi-ecosystem gates the changelog on inputs.changelog"
_CATALOG = "only version-pr merges catalog release notes into the changelog"
_MANIFESTS = "multi-ecosystem reports manifests where version-pr has ecosystems"
_KEY = "env.RELEASE_WORKFLOW_KEY"
_NAME = "with.name"
_HOOK = "version-update-hook"
_DESCRIPTION = "description"

# Every known difference between the twins. A field that differs, or a step,
# input, output or job that exists in one twin only, fails until it is
# recorded here; an entry for a difference that no longer exists fails too.
INTENDED_DIFFERENCES: dict[Entry, str] = {
    # workflow
    (WORKFLOW, JOB, "name"): "each twin has its own display name",
    # inputs
    (INPUTS, "ecosystems", WHOLE): _UPDATERS,
    (INPUTS, "ecosystem-config", WHOLE): _UPDATERS,
    (INPUTS, "manifests", WHOLE): _UPDATERS,
    (INPUTS, "catalog-release-notes", WHOLE): _CATALOG,
    (INPUTS, "bump", WHOLE): _VERSIONING,
    (INPUTS, "version", WHOLE): _VERSIONING,
    (INPUTS, "prerelease-tag", WHOLE): _VERSIONING,
    (INPUTS, "changelog", WHOLE): _CHANGELOG_GATE,
    (INPUTS, "job-name", WHOLE): "multi-ecosystem takes the job name as an input",
    (INPUTS, "max-bump", _DESCRIPTION): "multi-ecosystem applies it in auto mode only",
    (INPUTS, "version-update-script", _DESCRIPTION): _MANIFESTS,
    (INPUTS, "egress-preset", _DESCRIPTION): (
        "multi-ecosystem notes that it shares the release-version-pr preset"
    ),
    # prepare
    ("prepare", "Calculate next version", WHOLE): _VERSIONING,
    ("prepare", "Resolve next version", WHOLE): _VERSIONING,
    ("prepare", "Upload release metadata", _NAME): _NAMESPACE,
    ("prepare", "Upload tooling for the version update hook", _NAME): _NAMESPACE,
    # version-update-hook
    (_HOOK, "Download lgtm-ci tooling", _NAME): _NAMESPACE,
    (_HOOK, "Download release metadata", _NAME): _NAMESPACE,
    (_HOOK, "Generate changelog", "if"): _CHANGELOG_GATE,
    (_HOOK, "Generate changelog", "env.CATALOG_RELEASE_NOTES"): _CATALOG,
    (_HOOK, "Update CHANGELOG.md", "if"): _CHANGELOG_GATE,
    (_HOOK, "Setup Rust toolchain", WHOLE): _RUST,
    (_HOOK, "Run ecosystem version updaters", WHOLE): _UPDATERS,
    (_HOOK, "Run manifest version updaters", WHOLE): _UPDATERS,
    (_HOOK, "Upload version update changes", _NAME): _NAMESPACE,
    # version-pr
    ("version-pr", JOB, "name"): "multi-ecosystem takes the job name as an input",
    ("version-pr", JOB, "concurrency.group"): (
        "each twin serialises its own version PR runs; groups must stay distinct"
    ),
    ("version-pr", "Calculate next version", WHOLE): _VERSIONING,
    ("version-pr", "Resolve next version", WHOLE): _VERSIONING,
    ("version-pr", "Generate changelog", "if"): _CHANGELOG_GATE,
    ("version-pr", "Generate changelog", "env.CATALOG_RELEASE_NOTES"): _CATALOG,
    ("version-pr", "Update CHANGELOG.md", "if"): _CHANGELOG_GATE,
    ("version-pr", "Setup Rust toolchain", WHOLE): _RUST,
    ("version-pr", "Run ecosystem version updaters", WHOLE): _UPDATERS,
    ("version-pr", "Run manifest version updaters", WHOLE): _UPDATERS,
    ("version-pr", "Download version update changes", _NAME): _NAMESPACE,
    ("version-pr", "Check for version file changes", "env.EXPECT_VERSION_FILES"): (
        "multi-ecosystem always expects version files (manifests is required)"
    ),
    ("version-pr", "Create or update version PR", "with.body"): (
        "the PR body names the workflow and lists the manifests"
    ),
    ("version-pr", "Write summary", "env.ECOSYSTEMS"): _MANIFESTS,
    # report-release-failure
    ("report-release-failure", "Write failure trigger summary", _KEY): _NAMESPACE,
    ("report-release-failure", "Notify release failure", _KEY): _NAMESPACE,
}


def load_workflow(path: Path) -> dict[str, Any]:
    """Parse one workflow file.

    Args:
        path: The workflow YAML to read.

    Returns:
        The parsed mapping, with an unquoted ``on`` key (parsed as ``True``)
        restored to ``"on"``.

    Raises:
        ValueError: When the document is not a mapping.
    """
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"{path}: not a YAML mapping")
    if True in data and "on" not in data:
        data["on"] = data.pop(True)
    return data


def keyed_steps(job: Mapping[str, Any]) -> tuple[dict[StepKey, Any], list[str]]:
    """Index a job's steps by ``(name or id, occurrence)``.

    Args:
        job: One job mapping from ``jobs:``.

    Returns:
        The steps by key, in order, and one problem per step that has neither
        a name nor an id (such a step cannot be matched across the twins).
    """
    result: dict[StepKey, Any] = {}
    problems: list[str] = []
    seen: dict[str, int] = {}
    for position, step in enumerate(job.get("steps") or [], start=1):
        base = step.get("name") or step.get("id") if isinstance(step, dict) else None
        if not base:
            problems.append(f"step {position} has neither a name nor an id")
            continue
        seen[str(base)] = seen.get(str(base), 0) + 1
        result[(str(base), seen[str(base)])] = step
    return result, problems


def flatten(value: Any, prefix: str = "") -> dict[str, Any]:
    """Flatten nested mappings into dotted field paths.

    Args:
        value: A mapping (or leaf) to flatten.
        prefix: The path of ``value`` itself.

    Returns:
        Leaf values by dotted path. Lists and empty mappings are leaves.
    """
    if not isinstance(value, dict) or not value:
        return {prefix: value}
    result: dict[str, Any] = {}
    for key, item in value.items():
        result.update(flatten(item, f"{prefix}.{key}" if prefix else str(key)))
    return result


def differing_fields(left: Any, right: Any) -> set[str]:
    """Return the dotted field paths whose values differ.

    Args:
        left: One mapping.
        right: The other mapping.

    Returns:
        Paths present in only one side, or present in both with other values.
    """
    flat_left, flat_right = flatten(left), flatten(right)
    missing = object()
    return {
        path
        for path in {*flat_left, *flat_right}
        if flat_left.get(path, missing) != flat_right.get(path, missing)
    }


def _step_ref(ref: StepRef) -> StepKey | None:
    """Normalise an entry's step slot to a ``StepKey`` (``None`` for JOB)."""
    if ref is None or isinstance(ref, tuple):
        return ref
    return (ref, 1)


def _label(key: StepKey | None) -> str:
    """Describe a step key, or the job itself, for a message."""
    if key is None:
        return "job-level field"
    name, occurrence = key
    return f"step '{name}'" + (f" (occurrence {occurrence})" if occurrence > 1 else "")


def _recorded(scope: str, intended: Mapping[Entry, str]) -> dict[Any, set[str]]:
    """Return the recorded fields per item for one scope.

    Args:
        scope: A job name, :data:`WORKFLOW`, :data:`INPUTS` or :data:`OUTPUTS`.
        intended: The recorded differences.

    Returns:
        Field paths by item key: a ``StepKey`` (or ``None`` for the job itself)
        in a job scope, the input or output name in an interface scope, and
        ``None`` in the workflow scope.
    """
    result: dict[Any, set[str]] = {}
    for entry_scope, ref, field in intended:
        if entry_scope == scope:
            key = ref if scope in INTERFACE else _step_ref(ref)
            result.setdefault(key, set()).add(field)
    return result


def _compare_fields(
    scope: str,
    label: str,
    differing: set[str],
    recorded: set[str],
) -> Iterator[str]:
    """Yield unrecorded and stale field differences for one shared item."""
    if WHOLE in recorded:
        yield (
            f"{scope}: {label} is in both twins, so its whole entry is stale; "
            "record the differing fields instead"
        )
    for field in sorted(differing - recorded):
        yield (
            f"{scope}: {label} differs in '{field}'; make it identical "
            "or record it in INTENDED_DIFFERENCES"
        )
    for field in sorted(recorded - differing - {WHOLE}):
        yield (
            f"{scope}: INTENDED_DIFFERENCES entry for {label} field "
            f"'{field}' is stale; the twins agree there, so remove it"
        )


def _check_items(
    scope: str,
    pair: tuple[Mapping[Any, Any], Mapping[Any, Any]],
    recorded: dict[Any, set[str]],
    label: Callable[[Any], str],
) -> Iterator[str]:
    """Compare named items (steps, inputs, outputs) across the twins.

    Shared items must match field by field; an item in one twin only needs a
    whole entry; an entry for an item neither twin has is stale.

    Args:
        scope: The scope for messages.
        pair: The items by key in version-pr and in multi-ecosystem.
        recorded: The recorded fields per item key; consumed.
        label: Describes an item key for a message.

    Yields:
        One message per violation.
    """
    left, right = pair
    for key in [*left, *(k for k in right if k not in left)]:
        fields = recorded.pop(key, set())
        if key in left and key in right:
            differing = differing_fields(left[key], right[key])
            yield from _compare_fields(scope, label(key), differing, fields)
        elif fields != {WHOLE}:
            twin = "version-pr" if key in left else "multi-ecosystem"
            yield (
                f"{scope}: {label(key)} exists only in the {twin} twin; add it "
                "to both or record it as a whole entry"
            )
    for leftover in recorded:
        yield (
            f"{scope}: INTENDED_DIFFERENCES entry for {label(leftover)} is "
            "stale; neither twin has it, so remove it"
        )


def _check_order(
    job_name: str,
    left: Mapping[StepKey, Any],
    right: Mapping[StepKey, Any],
) -> Iterator[str]:
    """Yield a violation when shared steps are ordered differently."""
    left_order = [key for key in left if key in right]
    right_order = [key for key in right if key in left]
    for left_key, right_key in zip(left_order, right_order, strict=True):
        if left_key != right_key:
            yield (
                f"{job_name}: shared steps are out of order; version-pr has "
                f"{_label(left_key)} where multi-ecosystem has {_label(right_key)}"
            )
            return


def _check_job(
    job_name: str,
    left: Mapping[str, Any],
    right: Mapping[str, Any],
    intended: Mapping[Entry, str],
) -> Iterator[str]:
    """Yield the violations for one job present in both twins."""
    recorded = _recorded(job_name, intended)
    left_steps, left_problems = keyed_steps(left)
    right_steps, right_problems = keyed_steps(right)
    for problem in left_problems:
        yield f"{job_name}: version-pr {problem}"
    for problem in right_problems:
        yield f"{job_name}: multi-ecosystem {problem}"
    job_fields = differing_fields(
        {k: v for k, v in left.items() if k != "steps"},
        {k: v for k, v in right.items() if k != "steps"},
    )
    yield from _compare_fields(
        job_name,
        _label(JOB),
        job_fields,
        recorded.pop(JOB, set()),
    )
    yield from _check_items(job_name, (left_steps, right_steps), recorded, _label)
    yield from _check_order(job_name, left_steps, right_steps)


def _check_one_sided_job(
    job_name: str,
    twin: str,
    intended: Mapping[Entry, str],
) -> Iterator[str]:
    """Yield violations for a job that only one twin has."""
    recorded = _recorded(job_name, intended)
    if recorded.pop(JOB, set()) != {WHOLE}:
        yield (
            f"{job_name}: job exists only in the {twin} twin; add it to both or "
            f"record ({job_name!r}, JOB, WHOLE) in INTENDED_DIFFERENCES"
        )
    for leftover in recorded:
        yield (
            f"{job_name}: INTENDED_DIFFERENCES entry for {_label(leftover)} is "
            "stale; the job is in one twin only and is not compared"
        )


def _walk_jobs(workflow: Mapping[str, Any]) -> Iterator[Mapping[str, Any]]:
    """Yield every job mapping in the workflow."""
    for job in (workflow.get("jobs") or {}).values():
        if isinstance(job, dict):
            yield job


def artifact_names(workflow: Mapping[str, Any]) -> set[str]:
    """Collect every upload/download artifact ``name:`` in the workflow.

    Args:
        workflow: The parsed workflow.

    Returns:
        The artifact names, as written (expressions included).
    """
    names: set[str] = set()
    for job in _walk_jobs(workflow):
        for step in job.get("steps") or []:
            # Malformed steps are reported by keyed_steps; skip them here.
            if not isinstance(step, dict):
                continue
            uses = str(step.get("uses", ""))
            with_ = step.get("with")
            name = with_.get("name") if isinstance(with_, dict) else None
            if uses.startswith(ARTIFACT_ACTIONS) and name:
                names.add(str(name))
    return names


def _group(concurrency: Any) -> str | None:
    """Return the group of a ``concurrency:`` value (string or mapping)."""
    if isinstance(concurrency, str):
        return concurrency
    if isinstance(concurrency, dict) and concurrency.get("group"):
        return str(concurrency["group"])
    return None


def concurrency_groups(workflow: Mapping[str, Any]) -> set[str]:
    """Collect the workflow-level and job-level concurrency groups.

    Args:
        workflow: The parsed workflow.

    Returns:
        The group strings, as written.
    """
    candidates = [workflow.get("concurrency")]
    candidates += [job.get("concurrency") for job in _walk_jobs(workflow)]
    return {group for group in map(_group, candidates) if group}


def check(
    version_pr: Mapping[str, Any],
    multi_ecosystem: Mapping[str, Any],
    intended: Mapping[Entry, str] | None = None,
) -> list[str]:
    """Compare the twins and return one message per violation.

    Args:
        version_pr: The parsed ``reusable-release-version-pr.yml``.
        multi_ecosystem: The parsed ``reusable-release-multi-ecosystem.yml``.
        intended: The recorded differences; defaults to
            :data:`INTENDED_DIFFERENCES`.

    Returns:
        The violations, empty when the twins are in sync.
    """
    intended = INTENDED_DIFFERENCES if intended is None else intended
    left_jobs = version_pr.get("jobs") or {}
    right_jobs = multi_ecosystem.get("jobs") or {}
    jobs = [*left_jobs, *(job for job in right_jobs if job not in left_jobs)]
    violations = list(_check_jobs(jobs, (left_jobs, right_jobs), intended))
    scopes = {*jobs, WORKFLOW, *INTERFACE}
    for scope, item, field in intended:
        if scope not in scopes:
            entry = f"INTENDED_DIFFERENCES entry ({scope!r}, {item!r}, {field!r})"
            violations.append(f"{entry} is stale; neither twin has that job")
    violations += _check_workflow(version_pr, multi_ecosystem, intended)
    return violations


def _check_jobs(
    jobs: list[str],
    pair: tuple[Mapping[str, Any], Mapping[str, Any]],
    intended: Mapping[Entry, str],
) -> Iterator[str]:
    """Yield the violations for every job either twin has."""
    left_jobs, right_jobs = pair
    for job_name in jobs:
        left, right = left_jobs.get(job_name), right_jobs.get(job_name)
        if isinstance(left, dict) and isinstance(right, dict):
            yield from _check_job(job_name, left, right, intended)
        else:
            twin = "version-pr" if isinstance(left, dict) else "multi-ecosystem"
            yield from _check_one_sided_job(job_name, twin, intended)


def _call(workflow: Mapping[str, Any]) -> Mapping[str, Any]:
    """Return ``on.workflow_call``, or an empty mapping."""
    on = workflow.get("on")
    call = on.get("workflow_call") if isinstance(on, dict) else None
    return call if isinstance(call, dict) else {}


def _secrets(workflow: Mapping[str, Any]) -> Any:
    """Return ``on.workflow_call.secrets``, or ``None`` when absent."""
    return _call(workflow).get("secrets")


def _workflow_shape(workflow: Mapping[str, Any]) -> dict[str, Any]:
    """Return the workflow-level fields compared in the :data:`WORKFLOW` scope.

    Args:
        workflow: The parsed workflow.

    Returns:
        A copy without ``jobs`` and without the interface (inputs, outputs,
        secrets), which are compared on their own.
    """
    shape = {key: value for key, value in workflow.items() if key != "jobs"}
    call = {
        key: value
        for key, value in _call(workflow).items()
        if key not in ("inputs", "outputs", "secrets")
    }
    if isinstance(shape.get("on"), dict):
        shape["on"] = {**shape["on"], "workflow_call": call}
    return shape


def _interface_label(noun: str) -> Callable[[Any], str]:
    """Return a labeller for input or output names."""

    def label(key: Any) -> str:
        return f"{noun} '{key}'"

    return label


def _check_workflow(
    version_pr: Mapping[str, Any],
    multi_ecosystem: Mapping[str, Any],
    intended: Mapping[Entry, str],
) -> Iterator[str]:
    """Yield workflow-level, interface, secrets and collision violations."""
    yield from _compare_fields(
        WORKFLOW,
        "workflow field",
        differing_fields(_workflow_shape(version_pr), _workflow_shape(multi_ecosystem)),
        _recorded(WORKFLOW, intended).pop(JOB, set()),
    )
    for scope, noun in INTERFACE.items():
        name = scope.rsplit(".", 1)[1]
        left = _call(version_pr).get(name) or {}
        right = _call(multi_ecosystem).get(name) or {}
        yield from _check_items(
            scope,
            (left, right),
            _recorded(scope, intended),
            _interface_label(noun),
        )
    if _secrets(version_pr) != _secrets(multi_ecosystem):
        yield f"{SECRETS} differ between the twins; keep them identical"
    for label, collect in (
        ("artifact name", artifact_names),
        ("concurrency group", concurrency_groups),
    ):
        for shared in sorted(collect(version_pr) & collect(multi_ecosystem)):
            yield f"{label} '{shared}' is used by both twins; namespace it per twin"


def main(argv: list[str] | None = None) -> int:
    """Run the drift check.

    Args:
        argv: Optional argument vector (defaults to ``sys.argv[1:]``).

    Returns:
        0 without drift, 1 on any violation, 2 when a file cannot be read.
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--version-pr", type=Path, default=VERSION_PR)
    parser.add_argument("--multi-ecosystem", type=Path, default=MULTI_ECOSYSTEM)
    args = parser.parse_args(argv)
    try:
        version_pr = load_workflow(args.version_pr)
        multi_ecosystem = load_workflow(args.multi_ecosystem)
    except (OSError, ValueError, yaml.YAMLError) as error:
        print(f"[ERROR] cannot load the release twins: {error}", file=sys.stderr)
        return EXIT_ERROR
    violations = check(version_pr, multi_ecosystem)
    for violation in violations:
        print(f"[ERROR] release twin drift: {violation}", file=sys.stderr)
    if violations:
        return EXIT_DRIFT
    print("Release twins in sync.")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
