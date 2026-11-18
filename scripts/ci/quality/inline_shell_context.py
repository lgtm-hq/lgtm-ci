# SPDX-License-Identifier: MIT
"""Read what a step's YAML says about how its script runs (#1624).

``inline_shell_steps`` reads the steps; this module turns one step, its job
and its workflow into an :class:`inline_shell_rules.StepContext`.

An ``env:`` the check cannot read name by name is refused rather than
skipped: an expression (``env: ${{ fromJSON(vars.E) }}``) or a list can set
any name, ``BASH_ENV`` included, and a ``<<`` merge key or a name that is not
a string hides which names are set. A job ``container:`` is refused too: its
``env:`` reaches every step, and its image decides which bash and which tools
the steps run. No job in the tree has one (2026-11-18).
"""

from __future__ import annotations

import yaml
from inline_shell_rules import StepContext

STR_TAG = "tag:yaml.org,2002:str"
MERGE_TAG = "tag:yaml.org,2002:merge"
# A workflow's or job's mapping: its keys and value nodes.
Scope = dict[str, yaml.Node]


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
            names[str(key.value)] = scalar(value)
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
            problems.append(
                f"{where} container: is refused; its env: reaches every step "
                "and its image picks the bash and tools the steps run",
            )
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
