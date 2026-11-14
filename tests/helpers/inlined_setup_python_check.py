#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check that run-pytest inlines setup-python's steps exactly (#1469).

run-pytest carries setup-python's steps instead of nesting the sibling (a
nested sibling needs a self-repository ref that GHES and older self-hosted
runners cannot resolve). This derives, from setup-python's steps and input
defaults, the step sequence run-pytest must start with and compares it step by
step on every key except `name`: `id`, `uses`, `with`, `run`, `shell`,
`working-directory`, `env`, `if`, and anything else.

- Each `${{ inputs.X }}` in setup-python maps to run-pytest's `inputs.X` when
  run-pytest declares that input, and otherwise to setup-python's default.
- An `if:` that reads only inputs run-pytest lacks is evaluated against the
  defaults (with gha_expr): true means run-pytest's step carries no `if:`,
  false means the step is not inlined. An `if:` that reads only inputs
  run-pytest declares is compared as written. Anything else fails closed.
- `hashFiles(...)` arguments compare as a list of literal patterns, so a
  multi-line default and separate quoted arguments are equal when they list
  the same globs. A non-literal argument fails closed.
- The block is bounded: run-pytest's first N steps must be the N expected
  steps, and no later run-pytest step may be setup-equivalent (run
  setup-python.sh or use an action setup-python uses). A step removed from or
  disabled in setup-python therefore fails unless run-pytest drops it too.

Usage:
    python3 inlined_setup_python_check.py SETUP_PYTHON_YML RUN_PYTEST_YML

Exits 0 when the steps match, 1 with one line per mismatch otherwise.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

import yaml
from expr_scan import unquoted
from gha_expr import ExpressionError, Value, evaluate, tokenize

IGNORED_KEYS = frozenset({"name"})
# Any reference to the setup script by file name, whatever path spells it.
SETUP_SCRIPT_NAME = "setup-python.sh"
RELATIONAL_OPS = frozenset({"<", ">", "<=", ">="})
INPUT_EXPR = re.compile(r"\$\{\{\s*inputs\.([A-Za-z0-9_-]+)\s*\}\}")
INPUT_PATH = re.compile(r"inputs\.([A-Za-z0-9_-]+)")
LITERAL_ARG = re.compile(r"'((?:[^']|'')*)'")
HASH_FILES = "hashFiles("
EXPR_LITERALS = frozenset({"true", "false", "null"})


class UnsupportedError(ValueError):
    """Raised for a construct the check cannot compare; it fails closed."""


def load_action(
    path: Path,
) -> dict[str, Any]:
    """Load an action.yml.

    Args:
        path: Path to the action file.

    Returns:
        The parsed action mapping.

    Raises:
        TypeError: When the file is not a mapping.
    """
    loaded: object = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(loaded, dict):
        raise TypeError(f"{path}: not a mapping")
    return loaded


def as_text(
    value: object,
) -> str:
    """Render a scalar the way GitHub passes it to an action.

    Args:
        value: YAML scalar.

    Returns:
        String form; booleans lower-case.
    """
    if isinstance(value, bool):
        return "true" if value else "false"
    return "" if value is None else str(value)


def input_defaults(
    action: dict[str, Any],
) -> dict[str, str]:
    """Return each input's default as a string.

    Args:
        action: Parsed action.

    Returns:
        Input name to default value ("" when none).
    """
    return {
        name: as_text(spec.get("default", "") if isinstance(spec, dict) else "")
        for name, spec in (action.get("inputs") or {}).items()
    }


def split_call(
    text: str,
    start: int,
) -> tuple[list[str], int]:
    """Split the arguments of a call whose `(` precedes `start`.

    Args:
        text: Expression text.
        start: Index just after the opening parenthesis.

    Returns:
        The stripped top-level arguments and the index after `)`.

    Raises:
        UnsupportedError: When the call is not closed.
    """
    args: list[str] = []
    current = start
    for index, depth in unquoted(text, start):
        # The call's own ")" is the first one at depth -1.
        if (text[index], depth) in ((",", 0), (")", -1)):
            args.append(text[current:index].strip())
            current = index + 1
            if text[index] == ")":
                return args, index + 1
    raise UnsupportedError(f"unclosed hashFiles( in {text!r}")


def hash_patterns(
    args: list[str],
    defaults: dict[str, str] | None,
) -> list[str]:
    """Resolve hashFiles arguments to literal glob patterns.

    Args:
        args: Raw arguments.
        defaults: setup-python defaults for inputs run-pytest lacks, or None
            on the run-pytest side (literals only).

    Returns:
        The glob patterns, in order.

    Raises:
        UnsupportedError: For any argument that is not a quoted literal (or,
            on the setup-python side, a defaulted input).
    """
    globs: list[str] = []
    for arg in args:
        literal = LITERAL_ARG.fullmatch(arg)
        name = INPUT_PATH.fullmatch(arg)
        if literal:
            globs.append(literal.group(1).replace("''", "'"))
        elif name and defaults is not None and name.group(1) in defaults:
            text = defaults[name.group(1)]
            globs.extend(line.strip() for line in text.splitlines() if line.strip())
        else:
            raise UnsupportedError(f"non-literal hashFiles argument {arg!r}")
    return globs


def canonical_hash_files(
    text: str,
    defaults: dict[str, str] | None,
) -> str:
    """Rewrite every hashFiles(...) call to a canonical pattern list.

    Args:
        text: Expression text.
        defaults: See hash_patterns.

    Returns:
        Text with each call as `hashFiles(<json list>)`.
    """
    out: list[str] = []
    pos = 0
    while (found := text.find(HASH_FILES, pos)) >= 0:
        args, end = split_call(text, found + len(HASH_FILES))
        out.append(text[pos:found])
        out.append(f"hashFiles({json.dumps(hash_patterns(args, defaults))})")
        pos = end
    out.append(text[pos:])
    return "".join(out)


def substitute(
    value: object,
    defaults: dict[str, str],
) -> object:
    """Map setup-python's input references onto run-pytest's view.

    Args:
        value: Step value (scalar, mapping or list).
        defaults: setup-python defaults for inputs run-pytest lacks.

    Returns:
        The value with those defaults substituted.
    """
    if isinstance(value, dict):
        return {k: substitute(v, defaults) for k, v in value.items()}
    if isinstance(value, list):
        return [substitute(v, defaults) for v in value]
    text = canonical_hash_files(as_text(value), defaults)
    return INPUT_EXPR.sub(lambda m: defaults.get(m.group(1), m.group(0)), text)


def normalize(
    value: object,
) -> object:
    """Normalize a run-pytest step value for comparison.

    Args:
        value: Step value.

    Returns:
        Strings for scalars, hashFiles calls in canonical form.
    """
    if isinstance(value, dict):
        return {k: normalize(v) for k, v in value.items()}
    if isinstance(value, list):
        return [normalize(v) for v in value]
    return canonical_hash_files(as_text(value), None)


def resolve_condition(
    condition: str,
    defaults: dict[str, str],
) -> bool | None:
    """Decide what an `if:` on a setup-python step becomes in run-pytest.

    Args:
        condition: The `if:` expression.
        defaults: setup-python defaults for inputs run-pytest lacks.

    Returns:
        True/False when it reads only defaulted inputs (inline without `if:`
        or drop the step); None when it reads only inputs run-pytest declares
        (compare as written).

    Raises:
        UnsupportedError: For any other reference or a parse error.
    """
    source = condition.strip()
    if source.startswith("${{") and source.endswith("}}"):
        source = source[3:-2]
    try:
        tokens = tokenize(source)
    except ExpressionError as error:
        raise UnsupportedError(f"if: {condition!r}: {error}") from error
    # gha_expr compares strings numerically, GitHub lexically; refuse rather
    # than risk a wrong answer (setup-python uses only == and !=).
    relational = {t.text for t in tokens if t.kind == "op"} & RELATIONAL_OPS
    if relational:
        ops = sorted(relational)
        message = f"if: {condition!r} uses {ops}; only == and != are supported"
        raise UnsupportedError(message)
    idents = {t.text for t in tokens if t.kind == "ident"}
    paths = idents - EXPR_LITERALS
    names = {m.group(1) for p in paths if (m := INPUT_PATH.fullmatch(p))}
    if len(names) != len(paths):
        raise UnsupportedError(f"if: {condition!r} reads more than inputs")
    defaulted = names & defaults.keys()
    if defaulted and defaulted != names:
        raise UnsupportedError(f"if: {condition!r} mixes declared and defaulted inputs")
    if not defaulted:
        return None
    context: dict[str, Value] = {f"inputs.{name}": defaults[name] for name in names}
    try:
        return bool(evaluate(condition, context))
    except ExpressionError as error:
        raise UnsupportedError(f"if: {condition!r}: {error}") from error


def expected_steps(
    setup: dict[str, Any],
    defaults: dict[str, str],
) -> list[dict[str, object]]:
    """Derive the steps run-pytest must start with.

    Args:
        setup: Parsed setup-python action.
        defaults: setup-python defaults for inputs run-pytest lacks.

    Returns:
        Comparable step mappings, in order.
    """
    steps: list[dict[str, object]] = []
    for step in setup["runs"]["steps"]:
        body = {k: v for k, v in step.items() if k not in IGNORED_KEYS}
        if "if" in body:
            verdict = resolve_condition(as_text(body["if"]), defaults)
            if verdict is False:
                continue
            if verdict is True:
                del body["if"]
        steps.append({k: substitute(v, defaults) for k, v in body.items()})
    return steps


def setup_equivalent(
    step: dict[str, Any],
    setup_actions: frozenset[str],
) -> bool:
    """Return whether a run-pytest step does setup-python's work.

    Args:
        step: run-pytest step.
        setup_actions: Action names (before `@`) setup-python uses.

    Returns:
        True when it runs setup-python.sh or uses one of those actions.
    """
    uses = as_text(step.get("uses")).split("@", 1)[0]
    # The file name anywhere in run: or env: (a path held in a variable and
    # run as "$VAR" counts too); the check guards against drift, so a
    # name-based match is enough.
    env = step.get("env") or {}
    values = [as_text(step.get("run"))]
    values += [as_text(v) for v in env.values()] if isinstance(env, dict) else []
    mentions = any(SETUP_SCRIPT_NAME in value for value in values)
    return mentions or uses in setup_actions


def step_mismatches(
    label: str,
    want: dict[str, object],
    step: dict[str, Any],
) -> list[str]:
    """Compare one run-pytest step with its expected form.

    Args:
        label: Step label for messages.
        want: Expected comparable step.
        step: run-pytest step as parsed.

    Returns:
        One message per differing key.
    """
    got = {k: normalize(v) for k, v in step.items() if k not in IGNORED_KEYS}
    return [
        f"{label}: {key}: expected {want.get(key)!r}, got {got.get(key)!r}"
        for key in sorted(set(want) | set(got))
        if want.get(key) != got.get(key)
    ]


def compare(
    setup: dict[str, Any],
    pytest: dict[str, Any],
) -> list[str]:
    """Compare run-pytest's setup block with setup-python's steps.

    Args:
        setup: Parsed setup-python action.
        pytest: Parsed run-pytest action.

    Returns:
        One message per mismatch; empty when the steps match.
    """
    declared = (pytest.get("inputs") or {}).keys()
    defaults = {k: v for k, v in input_defaults(setup).items() if k not in declared}
    expected = expected_steps(setup, defaults)
    actual = pytest["runs"]["steps"]
    setup_uses = [step["uses"] for step in setup["runs"]["steps"] if "uses" in step]
    setup_actions = frozenset(as_text(uses).split("@", 1)[0] for uses in setup_uses)
    problems: list[str] = []
    for index, want in enumerate(expected):
        if index >= len(actual):
            problems.append(f"step {index + 1}: missing, expected {want}")
            continue
        label = f"step {index + 1} ({actual[index].get('name', '?')})"
        problems.extend(step_mismatches(label, want, actual[index]))
    problems.extend(
        f"step {index + 1} ({step.get('name', '?')}): setup-equivalent step after"
        f" the {len(expected)}-step block setup-python defines"
        for index, step in enumerate(actual)
        if index >= len(expected) and setup_equivalent(step, setup_actions)
    )
    return problems


def mismatches(
    setup_path: Path,
    pytest_path: Path,
) -> list[str]:
    """Load both actions and compare them, failing closed.

    Args:
        setup_path: setup-python action.yml.
        pytest_path: run-pytest action.yml.

    Returns:
        One message per mismatch; empty when the steps match.
    """
    try:
        return compare(load_action(setup_path), load_action(pytest_path))
    except UnsupportedError as error:
        return [f"unsupported: {error}"]


def main(
    argv: list[str],
) -> int:
    """Run the check.

    Args:
        argv: Command-line arguments (setup-python path, run-pytest path).

    Returns:
        0 when the steps match, 1 on a mismatch, 2 on bad usage.
    """
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    problems = mismatches(setup_path=Path(argv[0]), pytest_path=Path(argv[1]))
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
