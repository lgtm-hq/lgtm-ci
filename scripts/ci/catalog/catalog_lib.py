# SPDX-License-Identifier: MIT
"""Shared model for the support-tier catalog (``catalog/catalog.yml``, #1079).

``validate.py`` checks the catalog against the repository and ``render.py``
generates ``docs/catalog.md`` and the README index from it. Both import this
module from their own directory. The caller-facing permission union is not
recomputed here: it comes from ``scripts/ci/docs/validate-caller-permissions.py``
(#735/#736), loaded by path because its filename is hyphenated.

PyYAML is required. It ships with the system ``python3`` on GitHub-hosted
Ubuntu runners (the YAML cases of ``test_generate_file_breakdown.bats`` run,
not skip, in CI) and is in this repository's ``dev`` extra for local runs.
"""

from __future__ import annotations

import importlib.util
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
    name = "validate_caller_permissions"
    cached = sys.modules.get(name)
    if cached is not None:
        return cached
    path = repo_root / PERMISSIONS_VALIDATOR
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    # Dataclasses resolve annotations through sys.modules at class creation.
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except Exception:
        sys.modules.pop(name, None)
        raise
    return module


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


def resolve_expressions(
    text: str,
    values: dict[str, str],
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
            return values[plain.group("name")]
        fallback = INPUT_OR_LITERAL.match(expr) or INPUT_GUARDED_OR_LITERAL.match(expr)
        if fallback is not None and fallback.group("name") in values:
            return values[fallback.group("name")] or fallback.group("literal")
        return match.group(0)

    return EXPRESSION.sub(substitute, text)


def workflow_facts(
    workflows_dir: Path,
    name: str,
    overrides: dict[str, str] | None = None,
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
    document = yaml.safe_load((workflows_dir / name).read_text(encoding="utf-8"))
    jobs = document.get("jobs") if isinstance(document, dict) else None
    message = f"{name}: `jobs` must be a mapping of job id to mapping"
    if not isinstance(jobs, dict):
        raise ValueError(message)
    if any(not isinstance(job, dict) for job in jobs.values()):
        raise ValueError(message)
    # An input without a default (a required job-name) has no value a caller
    # can rely on, so its expression stays verbatim.
    values = {
        key: render_default(spec["default"])
        for key, spec in workflow_call_inputs(document).items()
        if isinstance(spec, dict) and "default" in spec
    }
    values.update(overrides or {})
    check_names: list[str] = []
    runners: set[str] = set()
    for job_id, job in jobs.items():
        label = resolve_expressions(text=str(job.get("name", job_id)), values=values)
        nested = LOCAL_WORKFLOW_USES.match(str(job.get("uses", "")))
        if nested is not None and nested.group("name") not in seen:
            passed = {
                key: resolve_expressions(text=render_default(value), values=values)
                for key, value in (job.get("with") or {}).items()
            }
            inner = workflow_facts(
                workflows_dir=workflows_dir,
                name=nested.group("name"),
                overrides=passed,
                seen=seen | {name},
            )
            for inner_name in inner.check_names:
                check_names.append(f"{label} / {inner_name}")
            # The nested jobs run on their own runners, chosen by the values
            # this job passes; the caller still needs to know them.
            runners.update(inner.runners)
            continue
        check_names.append(label)
        runner = resolve_expressions(text=str(job.get("runs-on", "")), values=values)
        if runner and "${{" not in runner:
            runners.add(runner)
    # Two jobs may share a display name (the sharded and unsharded legs of
    # reusable-test-shell); a check name is listed once.
    unique_names = tuple(dict.fromkeys(check_names))
    return WorkflowFacts(check_names=unique_names, runners=tuple(sorted(runners)))
