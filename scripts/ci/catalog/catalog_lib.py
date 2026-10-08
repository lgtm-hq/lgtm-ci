# SPDX-License-Identifier: MIT
"""Shared model for the support-tier catalog (``catalog/catalog.yml``, #1079).

``validate.py`` checks the catalog against the repository and ``render.py``
generates ``docs/catalog.md`` and the README index from it; ``deprecations.py``
(#1082) gates removals on the known-consumer registry and ``release_notes.py``
turns a catalog diff into changelog bullets. All import this module from their
own directory. The caller-facing permission union is not
recomputed here: it comes from ``scripts/ci/docs/validate-caller-permissions.py``
(#735/#736), loaded by path because its filename is hyphenated.

PyYAML is required. It ships with the system ``python3`` on GitHub-hosted
Ubuntu runners (the YAML cases of ``test_generate_file_breakdown.bats`` run,
not skip, in CI) and is in this repository's ``dev`` extra for local runs.
"""

from __future__ import annotations

import argparse
import importlib
import re
import sys
from dataclasses import dataclass
from enum import StrEnum, auto
from pathlib import Path
from types import ModuleType
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover - exercised only on a bare interpreter
    sys.stderr.write(
        "ERROR: PyYAML is required (system python3 on GitHub-hosted runners, "
        "or this repository's dev extra locally)\n",
    )
    raise SystemExit(2) from None

REPO_ROOT = Path(__file__).resolve().parents[3]
CATALOG_RELPATH = Path("catalog") / "catalog.yml"
CONSUMERS_RELPATH = Path("catalog") / "consumers.yml"
EXCEPTIONS_RELPATH = Path("catalog") / "deprecation-exceptions.yml"
WORKFLOWS_RELDIR = Path(".github") / "workflows"
ACTIONS_RELDIR = Path(".github") / "actions"
PERMISSIONS_VALIDATOR = Path("scripts/ci/docs/validate-caller-permissions.py")

EXPRESSION = re.compile(r"\$\{\{\s*(?P<expr>.*?)\s*\}\}")
INPUT_REF = re.compile(r"^inputs\.(?P<name>[\w-]+)$")
INPUT_OR_LITERAL = re.compile(
    r"^inputs\.(?P<name>[\w-]+)\s*\|\|\s*'(?P<literal>[^']*)'$",
)
INPUT_GUARDED_OR_LITERAL = re.compile(
    r"^inputs\.(?P<name>[\w-]+)\s*!=\s*''\s*&&"
    r"\s*inputs\.(?P=name)\s*\|\|\s*'(?P<literal>[^']*)'$",
)
LOCAL_WORKFLOW_USES = re.compile(r"^\./\.github/workflows/(?P<name>[\w.-]+\.ya?ml)$")


class Kind(StrEnum):
    """Entry-point kind; the catalog spells these with hyphens."""

    REUSABLE_WORKFLOW = "reusable-workflow"
    COMPOSITE_ACTION = "composite-action"


class Tier(StrEnum):
    """Support tier, in the order the docs present them."""

    STABLE = auto()
    PREVIEW = auto()
    INTERNAL = auto()
    DEPRECATED = auto()


@dataclass(frozen=True)
class EntryPoint:
    """A public file the catalog must classify.

    Attributes:
        kind: Reusable workflow or composite action.
        id: Workflow file stem or action directory name.
        path: Repository-relative path of the defining file.
    """

    kind: Kind
    id: str
    path: Path


@dataclass(frozen=True)
class WorkflowFacts:
    """What a reusable workflow's YAML says about its callers' view of it.

    Attributes:
        check_names: Callee job display names with input defaults applied.
        runners: Default runner labels its jobs resolve to.
    """

    check_names: tuple[str, ...]
    runners: tuple[str, ...]


def load_permissions_validator(
    repo_root: Path = REPO_ROOT,
) -> ModuleType:
    """Load ``validate-caller-permissions.py`` as a module.

    Args:
        repo_root: Repository root holding ``scripts/ci``.

    Returns:
        The executed validator module (``workflow_union`` and friends).

    Raises:
        ImportError: When the validator cannot be loaded.
    """
    # import_module takes the hyphenated stem as-is once its directory is on
    # sys.path, and caches the module in sys.modules like any import.
    directory = str(repo_root / PERMISSIONS_VALIDATOR.parent)
    if directory not in sys.path:
        sys.path.insert(0, directory)
    return importlib.import_module("validate-caller-permissions")


def add_repo_root_argument(
    parser: argparse.ArgumentParser,
) -> None:
    """Add the shared ``--repo-root`` option to a catalog CLI.

    Args:
        parser: Parser to extend.
    """
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=REPO_ROOT,
        help="Repository root (default: this checkout)",
    )


def load_catalog(
    path: Path,
) -> dict[str, Any]:
    """Parse the catalog file.

    Args:
        path: Path to ``catalog.yml``.

    Returns:
        The top-level mapping.

    Raises:
        ValueError: When the file is not a YAML mapping.
    """
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"{path}: top level must be a mapping")
    return data


def discover_entry_points(
    repo_root: Path,
) -> list[EntryPoint]:
    """List every file the catalog must classify, sorted by kind then id.

    Args:
        repo_root: Repository root.

    Returns:
        One entry point per ``reusable-*.yml`` workflow and ``action.yml``.
    """
    workflows = [
        EntryPoint(
            kind=Kind.REUSABLE_WORKFLOW,
            id=path.stem,
            path=path.relative_to(repo_root),
        )
        for path in (repo_root / WORKFLOWS_RELDIR).glob("reusable-*.yml")
    ]
    actions = [
        EntryPoint(
            kind=Kind.COMPOSITE_ACTION,
            id=path.parent.name,
            path=path.relative_to(repo_root),
        )
        for path in (repo_root / ACTIONS_RELDIR).glob("*/action.yml")
    ]
    # Sort by id, not path: `reusable-docker.yml` sorts after
    # `reusable-docker-build.yml` as a path but before it as an id.
    by_id = sorted(workflows, key=lambda ep: ep.id)
    return by_id + sorted(actions, key=lambda ep: ep.id)


def entry_path(
    kind: Kind,
    entry_id: str,
) -> Path:
    """Return the repository-relative file a catalog entry describes.

    Args:
        kind: Entry kind.
        entry_id: Entry id.

    Returns:
        Path of the workflow or ``action.yml``.
    """
    if kind is Kind.REUSABLE_WORKFLOW:
        return WORKFLOWS_RELDIR / f"{entry_id}.yml"
    return ACTIONS_RELDIR / entry_id / "action.yml"


def workflow_call_inputs(
    document: dict[Any, Any],
) -> dict[str, Any]:
    """Return a workflow's ``on.workflow_call.inputs`` mapping.

    Args:
        document: Parsed workflow (PyYAML reads the ``on`` key as ``True``).

    Returns:
        Input name to definition; empty when absent.
    """
    triggers = document.get("on", document.get(True)) or {}
    if not isinstance(triggers, dict):
        return {}
    call = triggers.get("workflow_call") or {}
    inputs = call.get("inputs") if isinstance(call, dict) else None
    return inputs if isinstance(inputs, dict) else {}


def render_default(
    value: Any,
) -> str:
    """Render an input default the way GitHub interpolates it.

    Args:
        value: Default from the workflow YAML.

    Returns:
        String form; booleans lower-case, missing defaults empty.
    """
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def is_truthy(
    value: Any,
) -> bool:
    """Return whether GitHub's expression engine treats a value as true.

    ``||`` yields its right side for ``false``, ``0``, ``''`` and ``null``;
    the rendered string ``"false"`` would be truthy in Python.

    Args:
        value: Raw input value (YAML-typed default or passed value).

    Returns:
        GitHub's truthiness of the value.
    """
    return value not in (None, False, 0, "")


def resolve_expressions(
    text: str,
    values: dict[str, Any],
) -> str:
    """Substitute ``${{ inputs.* }}`` references with known values.

    Only the three shapes reusables use for display names are resolved:
    ``inputs.x``, ``inputs.x || 'lit'`` and ``inputs.x != '' && inputs.x ||
    'lit'``. Anything else (matrix values, other contexts) stays verbatim,
    which is also how a caller sees it before the run expands it.

    Args:
        text: A job ``name:`` or ``runs-on:`` value.
        values: Input name to its effective value.

    Returns:
        The text with resolvable expressions replaced.
    """

    def substitute(match: re.Match[str]) -> str:
        expr = match.group("expr")
        plain = INPUT_REF.match(expr)
        if plain is not None and plain.group("name") in values:
            return render_default(values[plain.group("name")])
        fallback = INPUT_OR_LITERAL.match(expr) or INPUT_GUARDED_OR_LITERAL.match(expr)
        if fallback is not None and fallback.group("name") in values:
            value = values[fallback.group("name")]
            if is_truthy(value):
                return render_default(value)
            return fallback.group("literal")
        return match.group(0)

    return EXPRESSION.sub(substitute, text)


def input_values(
    document: dict[Any, Any],
    overrides: dict[str, Any] | None,
) -> dict[str, Any]:
    """Return the effective value of every input that has one.

    An input without a default (a required job-name) has no value a caller
    can rely on, so it is left out and its expression stays verbatim.

    Args:
        document: Parsed workflow.
        overrides: Values a calling job passes (nested calls only).

    Returns:
        Input name to effective value.
    """
    values = {
        key: spec["default"]
        for key, spec in workflow_call_inputs(document).items()
        if isinstance(spec, dict) and "default" in spec
    }
    values.update(overrides or {})
    return values


def passed_values(
    job: dict[str, Any],
    values: dict[str, Any],
) -> dict[str, Any]:
    """Return the ``with:`` values a job passes to a nested reusable.

    Args:
        job: Job that calls a local reusable workflow.
        values: The calling workflow's effective input values.

    Returns:
        Input name to the value after resolving the caller's expressions.
    """
    passed: dict[str, Any] = {}
    for key, value in (job.get("with") or {}).items():
        if isinstance(value, str):
            value = resolve_expressions(text=value, values=values)
        passed[key] = value
    return passed


def load_workflow(
    workflows_dir: Path,
    name: str,
) -> tuple[dict[Any, Any], dict[str, dict[str, Any]]]:
    """Parse a workflow file and return it with its ``jobs`` mapping.

    Args:
        workflows_dir: Directory holding the workflow files.
        name: Workflow file name.

    Returns:
        ``(document, jobs)``.

    Raises:
        ValueError: When the workflow or one of its jobs is not a mapping.
    """
    document = yaml.safe_load((workflows_dir / name).read_text(encoding="utf-8"))
    jobs = document.get("jobs") if isinstance(document, dict) else None
    message = f"{name}: `jobs` must be a mapping of job id to mapping"
    if not isinstance(jobs, dict):
        raise ValueError(message)
    if any(not isinstance(job, dict) for job in jobs.values()):
        raise ValueError(message)
    return document, jobs


def job_runner(
    job: dict[str, Any],
    values: dict[str, Any],
) -> str | None:
    """Return a job's runner label when it resolves to a literal.

    Args:
        job: Job mapping.
        values: Effective input values.

    Returns:
        The label, or None for matrix or otherwise dynamic runners.
    """
    raw = job.get("runs-on", "")
    if not isinstance(raw, str):
        # A label list or runner group is not a single default label.
        return None
    runner = resolve_expressions(text=raw, values=values)
    return runner if runner and "${{" not in runner else None


def job_label(
    job_id: str,
    job: dict[str, Any],
    values: dict[str, Any],
) -> str:
    """Return a job's display name with input defaults applied.

    A name that GitHub expands per matrix leg is a template, so it is kept
    verbatim: substituting defaults there would document a value such as
    `(shard 1/1)` that the job's own `if:` never lets run.

    Args:
        job_id: Job key.
        job: Job mapping.
        values: Effective input values.

    Returns:
        The display name.
    """
    name = str(job.get("name", job_id))
    expressions = (match.group("expr") for match in EXPRESSION.finditer(name))
    if any("matrix." in expr for expr in expressions):
        return name
    return resolve_expressions(text=name, values=values)


class DeprecationKind(StrEnum):
    """What a deprecation record retires (#1082)."""

    INPUT = auto()
    OUTPUT = auto()
    SECRET = auto()
    ENTRY = auto()


# A description that says an input or output is deprecated or inert must be
# backed by a deprecation record, so the removal gate knows about it.
DEPRECATION_MARKER = re.compile(
    r"\b(?:deprecated|deprecate|deprecates|deprecation|deprecating|inert)\b",
    re.IGNORECASE,
)


def removal_key(
    entry_id: str,
    kind: DeprecationKind,
    name: str = "",
) -> str:
    """Return the key that names one removable interface item.

    The same spelling is used by deprecation records, the consumer registry's
    ``deprecated-in-use`` lists, exceptions and the removal gate's messages.

    Args:
        entry_id: Catalog entry id.
        kind: Input, output or the whole entry.
        name: Input or output name; empty for the whole entry.

    Returns:
        ``<entry>:<input|output|secret>:<name>`` or ``<entry>:entry``.
    """
    if kind is DeprecationKind.ENTRY:
        return f"{entry_id}:entry"
    return f"{entry_id}:{kind.value}:{name}"


def interface_holder(
    kind: Kind,
    document: Any,
) -> dict[str, Any]:
    """Return the mapping that declares an entry point's interface.

    Args:
        kind: Entry kind.
        document: Parsed workflow or ``action.yml``.

    Returns:
        ``on.workflow_call`` for a workflow, the document for an action.
    """
    if not isinstance(document, dict):
        return {}
    if kind is Kind.COMPOSITE_ACTION:
        return document
    triggers = document.get("on", document.get(True)) or {}
    call = triggers.get("workflow_call") if isinstance(triggers, dict) else None
    return call if isinstance(call, dict) else {}


def required_inputs(
    kind: Kind,
    document: Any,
) -> set[str]:
    """Return the inputs a caller must pass.

    Args:
        kind: Entry kind.
        document: Parsed workflow or ``action.yml``.

    Returns:
        Names of inputs with ``required: true`` and no default.
    """
    inputs = interface_holder(kind=kind, document=document).get("inputs")
    required = set()
    for name, spec in inputs.items() if isinstance(inputs, dict) else []:
        if not isinstance(spec, dict) or "default" in spec:
            continue
        if spec.get("required") is True:
            required.add(str(name))
    return required


def interface(
    kind: Kind,
    document: Any,
) -> dict[DeprecationKind, dict[str, str]]:
    """Return the inputs, outputs and secrets an entry point exposes.

    Args:
        kind: Entry kind.
        document: Parsed workflow or ``action.yml``.

    Returns:
        Kind to item name to one-line description. Composite actions have
        no secrets.
    """
    holder = interface_holder(kind=kind, document=document)
    result: dict[DeprecationKind, dict[str, str]] = {}
    for deprecation_kind, key in (
        (DeprecationKind.INPUT, "inputs"),
        (DeprecationKind.OUTPUT, "outputs"),
        (DeprecationKind.SECRET, "secrets"),
    ):
        items = holder.get(key)
        result[deprecation_kind] = {
            str(name): " ".join(str((spec or {}).get("description", "")).split())
            for name, spec in (items.items() if isinstance(items, dict) else [])
            if isinstance(spec, dict) or spec is None
        }
    return result


def removal_keys(
    entry_id: str,
    surface: dict[DeprecationKind, dict[str, str]],
) -> set[str]:
    """Return every removal key an entry point currently exposes.

    Args:
        entry_id: Catalog entry id.
        surface: ``interface()`` result for the entry.

    Returns:
        The entry key plus one key per input and output.
    """
    keys = {removal_key(entry_id=entry_id, kind=DeprecationKind.ENTRY)}
    for kind, names in surface.items():
        keys.update(removal_key(entry_id=entry_id, kind=kind, name=n) for n in names)
    return keys


def deprecation_keys(
    record: dict[str, Any],
) -> set[str]:
    """Return the removal keys a deprecation record covers.

    Args:
        record: Entry of the catalog's ``deprecations`` list (schema-checked).

    Returns:
        One key per listed entry.
    """
    kind = DeprecationKind(record["kind"])
    name = str(record.get("name", ""))
    entries = [str(entry_id) for entry_id in record["entries"]]
    return {removal_key(entry_id=e, kind=kind, name=name) for e in entries}


def workflow_facts(
    workflows_dir: Path,
    name: str,
    overrides: dict[str, Any] | None = None,
    seen: frozenset[str] = frozenset(),
) -> WorkflowFacts:
    """Derive a reusable workflow's check names and default runners.

    A job that calls a local reusable shows as ``<job> / <nested job>``; the
    nested workflow is rendered with the ``with:`` values the job passes.

    Args:
        workflows_dir: Directory holding the workflow files.
        name: Workflow file name.
        overrides: Input values a calling job passes (nested calls only).
        seen: Workflows already on the nested-call stack (cycle guard).

    Returns:
        Check names in job order and the sorted set of resolvable runners.

    Raises:
        ValueError: When the workflow or one of its jobs is not a mapping.
    """
    document, jobs = load_workflow(workflows_dir=workflows_dir, name=name)
    values = input_values(document=document, overrides=overrides)
    check_names: list[str] = []
    runners: set[str] = set()
    for job_id, job in jobs.items():
        label = job_label(job_id=job_id, job=job, values=values)
        nested = LOCAL_WORKFLOW_USES.match(str(job.get("uses", "")))
        if nested is not None and nested.group("name") not in seen:
            inner = workflow_facts(
                workflows_dir=workflows_dir,
                name=nested.group("name"),
                overrides=passed_values(job=job, values=values),
                seen=seen | {name},
            )
            for inner_name in inner.check_names:
                check_names.append(f"{label} / {inner_name}")
            # The nested jobs run on their own runners, chosen by the values
            # this job passes; the caller still needs to know them.
            runners.update(inner.runners)
            continue
        check_names.append(label)
        runners.update(filter(None, [job_runner(job=job, values=values)]))
    # Two jobs may share a display name (the sharded and unsharded legs of
    # reusable-test-shell); a check name is listed once.
    return WorkflowFacts(
        check_names=tuple(dict.fromkeys(check_names)),
        runners=tuple(sorted(runners)),
    )
