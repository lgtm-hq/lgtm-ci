# SPDX-License-Identifier: MIT
"""Read what a step's YAML says about how its script runs (#1624).

``inline_shell_steps`` reads the steps; this module turns one step, its job
and its workflow into an :class:`inline_shell_rules.StepContext`.

An ``env:`` the check cannot read name by name is refused rather than
skipped: an expression (``env: ${{ fromJSON(vars.E) }}``) or a list can set
any name, ``BASH_ENV`` included, and a ``<<`` merge key or a name that is not
a string hides which names are set, and so does a name that is not a plain
``[A-Za-z_][A-Za-z0-9_]*`` (``${{ matrix.n }}``, ``A B``, ``A-B``). A job
``container:`` is refused too: its ``env:`` reaches every step, and its image
decides which bash and which tools the steps run. No job in the tree has one
(2026-11-18).

The ``env:`` of a step without ``run:`` is read too (:func:`env_problems`):
the runner passes a ``uses:`` step's ``env:`` to the action, so a composite
action's ``run:`` steps, and those of any other action, start with it. So is
the ``env:`` of a job, or of the workflow, that no ``run:`` step below it
reports.
"""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass

import yaml
from inline_shell_denylist import name_problem, protected_reason
from inline_shell_rules import StepContext

COMPOSITE = "(composite)"
STR_TAG = "tag:yaml.org,2002:str"
MERGE_TAG = "tag:yaml.org,2002:merge"
CONTAINER = (
    "container: is refused; its env: reaches every step and its image picks "
    "the bash and tools the steps run"
)
# A workflow's or job's mapping: its keys and value nodes.
Scope = dict[str, yaml.Node]


@dataclass(frozen=True)
class EnvProblem:
    """A refused ``env:`` that no ``run:`` step reports.

    Attributes:
        line: The line (1-based) of the step, the job or the ``env:``.
        job: The job id, ``(composite)`` in an action, or ``(workflow)``.
        step: The step's name, else its id, else its index; ``(job)`` or
            ``(env)`` for a scope.
        message: What is refused.
    """

    line: int
    job: str
    step: str
    message: str


def mapping(node: yaml.Node | None) -> dict[str, yaml.Node]:
    """Return a mapping node's scalar keys and value nodes.

    Args:
        node: Any node, or None.

    Returns:
        The fields; empty when the node is not a mapping.
    """
    if not isinstance(node, yaml.MappingNode):
        return {}
    fields: dict[str, yaml.Node] = {}
    for key, value in node.value:
        if isinstance(key, yaml.ScalarNode):
            fields[str(key.value)] = value
    return fields


def scalar(node: yaml.Node | None) -> str | None:
    """Return a scalar node's text, else None.

    Args:
        node: Any node, or None.

    Returns:
        The text of a scalar.
    """
    return str(node.value) if isinstance(node, yaml.ScalarNode) else None


def env_names(
    node: yaml.Node | None,
    where: str,
) -> tuple[dict[str, str | None], list[str]]:
    """Return the names an ``env:`` sets, and what keeps a name from being read.

    Args:
        node: The ``env:`` value node, or None when there is none.
        where: ``step``, ``job`` or ``workflow``, for the messages.

    Returns:
        Each name with its value (None when not a plain scalar), and one
        message per form the check cannot read.
    """
    if node is None:
        return {}, []
    if not isinstance(node, yaml.MappingNode):
        message = (
            f"{where} env: is not a mapping of names to values; an expression "
            "or a list can set any name, so write each name out"
        )
        return {}, [message]
    names: dict[str, str | None] = {}
    problems: list[str] = []
    for key, value in node.value:
        if key.tag == MERGE_TAG:
            problems.append(f"{where} env: uses a << merge key; write each name out")
        elif not isinstance(key, yaml.ScalarNode) or key.tag != STR_TAG:
            problems.append(f"{where} env: has a name that is not a string")
        else:
            name = str(key.value)
            names[name] = scalar(value)
            problem = name_problem(name, where)
            if problem:
                problems.append(problem)
    return names, problems


def _run_default(scopes: list[tuple[str, Scope]], key: str) -> str | None:
    """Return ``defaults.run.<key>`` of the innermost scope that sets it."""
    for _, scope in scopes:
        value = mapping(mapping(scope.get("defaults")).get("run")).get(key)
        if value is not None:
            return scalar(value) or "(not a string)"
    return None


def step_context(
    node: yaml.Node,
    scopes: list[tuple[str, Scope]],
    action_dir: str | None,
    *,
    caller: bool,
) -> StepContext:
    """Return a step's YAML context.

    Args:
        node: The step's mapping node.
        scopes: ``(job or workflow, mapping)`` around the step, innermost
            first; empty in a composite action.
        action_dir: The composite action's directory, or None in a workflow.
        caller: True when a calling workflow sets ``inputs``.

    Returns:
        The context, with every ``env:`` or ``container:`` the check refuses.
    """
    fields = mapping(node)
    env, problems = env_names(fields.get("env"), "step")
    inherited: set[str] = set()
    for where, scope in scopes:
        names, found = env_names(scope.get("env"), where)
        inherited.update(names)
        problems.extend(found)
        if "container" in scope:
            problems.append(f"{where} {CONTAINER}")
    directory = fields.get("working-directory")
    shell_node = fields.get("shell")
    shell = _run_default(scopes, "shell") if shell_node is None else scalar(shell_node)
    return StepContext(
        env=env,
        inherited=frozenset(inherited),
        action_dir=action_dir,
        working_directory=(
            scalar(directory)
            if directory is not None
            else _run_default(scopes, "working-directory")
        ),
        run_shell=shell,
        caller_inputs=caller,
        yaml_problems=tuple(problems),
    )


def step_groups(
    root: yaml.Node | None,
) -> Iterator[tuple[str, yaml.Node, list[tuple[str, Scope]]]]:
    """Yield ``(job id, steps node, scopes)`` per job, or the composite action.

    Args:
        root: A workflow's or an action's root node.

    Yields:
        The job id (``(composite)`` in an action), its ``steps:`` node, and
        ``(job, mapping)`` and ``(workflow, mapping)``, innermost first.
    """
    top = mapping(root)
    for job_id, job in mapping(top.get("jobs")).items():
        steps = mapping(job).get("steps")
        if steps is not None:
            yield job_id, steps, [("job", mapping(job)), ("workflow", top)]
    steps = mapping(top.get("runs")).get("steps")
    if steps is not None:
        yield COMPOSITE, steps, []


def step_label(fields: Scope, index: int) -> str:
    """Return a step's name, else its id, else its index.

    Args:
        fields: The step's mapping.
        index: Its position in ``steps:``.

    Returns:
        The label.
    """
    for key in ("name", "id"):
        value = fields.get(key)
        if isinstance(value, yaml.ScalarNode):
            return str(value.value)
    return str(index)


def _env_messages(node: yaml.Node | None, where: str) -> list[str]:
    """Return every problem of one ``env:``: its form, its names, protected names."""
    names, problems = env_names(node, where)
    for name in sorted(names):
        reason = protected_reason(name)
        if reason:
            problems.append(f"{where} env: sets {name}, {reason}")
    return problems


def env_problems(root: yaml.Node | None) -> list[EnvProblem]:
    """Return what the ``env:`` blocks no ``run:`` step reports refuse.

    A ``run:`` step reports its own ``env:`` and those of its job and
    workflow (:func:`step_context`). This reads the rest: the ``env:`` of
    every step without ``run:`` (a ``uses:`` of any action, local or not),
    of every job with no ``run:`` step, with its ``container:``, and of the
    workflow when no job has a ``run:`` step.

    Args:
        root: A workflow's or an action's root node.

    Returns:
        The problems: steps first, then jobs, then the workflow. A step's
        line is its first line; a scope's is the first line of its ``env:``
        or ``container:`` value.
    """
    found: list[EnvProblem] = []
    covered: set[str] = set()
    for job_id, steps, _ in step_groups(root):
        if not isinstance(steps, yaml.SequenceNode):
            continue
        for index, node in enumerate(steps.value):
            fields = mapping(node)
            if "run" in fields:
                covered.add(job_id)
                continue
            label = step_label(fields, index)
            line = node.start_mark.line + 1
            for message in _env_messages(fields.get("env"), "step"):
                found.append(EnvProblem(line, job_id, label, message))
    top = mapping(root)
    for job_id, job in mapping(top.get("jobs")).items():
        if job_id in covered:
            continue
        fields = mapping(job)
        env = fields.get("env")
        if env is not None:
            line = env.start_mark.line + 1
            for message in _env_messages(env, "job"):
                found.append(EnvProblem(line, job_id, "(job)", message))
        container = fields.get("container")
        if container is not None:
            line = container.start_mark.line + 1
            found.append(EnvProblem(line, job_id, "(job)", f"job {CONTAINER}"))
    env = top.get("env")
    if env is not None and not covered:
        line = env.start_mark.line + 1
        for message in _env_messages(env, "workflow"):
            found.append(EnvProblem(line, "(workflow)", "(env)", message))
    return found
