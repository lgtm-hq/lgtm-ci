# SPDX-License-Identifier: MIT
"""The definitions behind the inline-shell check (#1624).

docs/inline-shell.md states the rules for contributors; ``validate_inline_shell.py``
enforces them. A ``run:`` step is accepted when it is one of three things:

Script call
    One command that runs a script file, and nothing else
    (``inline_shell_calls.script_call``).
Generated copy
    A block that ``scripts/ci/bootstrap/sync_inline_blocks.py`` wrote, equal
    to its tested source (``inline_shell_steps``).
Trivial
    Hand-written, and passes every numbered :class:`Rule`
    (``inline_shell_trivial.trivial_problems`` for rules 1, 2 and 4; the
    validator for 3 and 5).

Every step, whatever its class, also needs ``shell:`` absent, ``bash`` or
``sh`` (:data:`SHELLS`), and no ``env:`` at any level may set a protected
name (``inline_shell_denylist``): a runner path the check trusts, a startup
hook or config redirect of a tool the scripts run, or a variable that
weakens TLS or redirects traffic. A hand-written step holds printable ASCII
only (:func:`character_problems`).

A ``run:`` value is split into lines on ``\n`` only (:func:`script_lines`),
as bash splits it: ``str.splitlines`` also breaks at ``\r``, ``\v``, ``\f``,
``\x85`` and U+2028, so it would count and read lines bash does not see.
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import dataclass, field
from enum import IntEnum

from inline_shell_denylist import protected_reason

MAX_LINES = 5
MAX_COPIES = 10
ALLOWED_COMMANDS = frozenset({"echo", "printf", "exit", "true", "false"})
# The runner files a trivial step may write. $GITHUB_ENV and $GITHUB_PATH are
# not here: every later step of the job loads them, so a line written there
# (PATH=, LD_PRELOAD=, BASH_ENV=, NODE_OPTIONS=...) changes what later steps
# run. No trivial step needs them (#1624 review, 2026-11-18).
RUNNER_FILES = frozenset({"GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY"})
# String tests only. -eq, -ne, -lt, -le, -gt and -ge evaluate their operands
# as arithmetic inside [[ ]], and -v evaluates an array subscript, so a value
# like ``a[$(curl ...)]`` runs; none of them is allowed.
TEST_OPERATORS = frozenset({"-n", "-z"})
# The operators of a three-word ``[ ]`` or ``test``: A OP B. ``<`` and ``>``
# are redirections there, never comparisons.
BRACKET_COMPARISONS = frozenset({"=", "==", "!="})
LOOP_WORDS = frozenset({"for", "while", "until", "select", "do", "done"})
INTERPRETERS: dict[str, frozenset[str]] = {
    "bash": frozenset(),
    "sh": frozenset(),
    "python": frozenset({"-I"}),
    "python3": frozenset({"-I"}),
    "/usr/bin/python3": frozenset({"-I"}),
}
SHELLS = frozenset({"bash", "sh"})
# printf conversions and escapes a trivial step's format may hold. %n assigns
# a variable, %b and %q read escapes from the argument, %(...)T and others
# compute; an escape other than these could print a control character.
PRINTF_CONVERSIONS = frozenset({"%s", "%%"})
PRINTF_ESCAPES = frozenset({"\\n", "\\t", "\\\\"})
TOOLING_CHECKOUTS = (".lgtm-ci-tooling/", ".lgtm-ci-readiness/")
# A copy staged out of the checkout before it can change, keyed by how the
# step names it: (variable, rest of the path) -> the tested source file.
STAGED_COPIES: dict[tuple[str, str], str] = {
    (
        "RUNNER_TEMP",
        "/check-tooling-ref-divergence.sh",
    ): ".github/actions/checkout-and-harden/check-tooling-ref-divergence.sh",
}
PRINTABLE = re.compile(r"[\t\n\x20-\x7e]*")


class Rule(IntEnum):
    """The numbered conditions of the trivial-step definition (#1624)."""

    ALLOW_LIST = 1
    REDIRECTION = 2
    EXPRESSION = 3
    LINES = 4
    COPIES = 5


RULE_TITLES = {
    Rule.ALLOW_LIST: "only echo, printf, exit, true, false in one conditional",
    Rule.REDIRECTION: "writes only to the console and the runner files",
    Rule.EXPRESSION: "no ${{ }} in the script; values come through env:",
    Rule.LINES: f"at most {MAX_LINES} lines of code",
    Rule.COPIES: f"the same text in fewer than {MAX_COPIES} places",
}


@dataclass(frozen=True)
class Problem:
    """One broken rule.

    Attributes:
        rule: Which condition is broken.
        message: What in the step breaks it.
    """

    rule: Rule
    message: str


@dataclass(frozen=True)
class StepContext:
    """What a step's YAML says about how its script runs.

    Attributes:
        env: The step's own ``env:``; a value is None when it is not a
            plain scalar.
        inherited: The keys of the workflow's and the job's ``env:``.
        action_dir: The composite action's directory relative to the
            repository (``.github/actions/name``), or None in a workflow.
        working_directory: The step's ``working-directory``, else the job's
            or the workflow's ``defaults.run.working-directory``, else None.
        run_shell: The step's ``shell:``, else the job's or the workflow's
            ``defaults.run.shell``, else None.
        caller_inputs: True when ``inputs`` come from a calling workflow:
            in a composite action, or in a workflow whose only trigger is
            ``workflow_call``. A ``workflow_dispatch`` input comes from
            whoever starts the run instead.
        yaml_problems: What around the step the check refuses to read: an
            ``env:`` that is not a mapping of plain names, or a job
            ``container:`` (``inline_shell_context``).
    """

    env: Mapping[str, str | None] = field(default_factory=dict)
    inherited: frozenset[str] = frozenset()
    action_dir: str | None = None
    working_directory: str | None = None
    run_shell: str | None = None
    caller_inputs: bool = False
    yaml_problems: tuple[str, ...] = ()


def script_lines(script: str) -> list[str]:
    """Return the lines of a ``run:`` value as bash reads them: split on ``\n``.

    Args:
        script: The text of a ``run:`` step.

    Returns:
        The lines, without their line breaks.
    """
    return script.split("\n")


def code_lines(script: str) -> list[str]:
    """Return the lines of a script that hold code, stripped.

    Args:
        script: The text of a ``run:`` step.

    Returns:
        Every line that is neither blank nor only a comment.
    """
    stripped = (line.strip() for line in script_lines(script))
    return [line for line in stripped if line and not line.startswith("#")]


def normalized(script: str) -> str:
    """Return the text two steps must share to count as the same code.

    Args:
        script: The text of a ``run:`` step.

    Returns:
        :func:`code_lines` joined by newlines, so indentation and comments
        do not make two copies differ.
    """
    return "\n".join(code_lines(script))


def expression_lines(script: str) -> list[int]:
    """Return the 1-based lines that hold a ``${{`` expression.

    Args:
        script: The text of a ``run:`` step.

    Returns:
        Line numbers within the script.
    """
    lines = enumerate(script_lines(script), start=1)
    return [number for number, line in lines if "${{" in line]


def character_problems(script: str) -> list[str]:
    """Return one message per line holding a character other than printable ASCII.

    Tab and newline are allowed. A control character (an ANSI escape, a
    carriage return) can hide what a line runs from a reader, and a non-ASCII
    lookalike can make a command name read as another one.

    Args:
        script: The text of a ``run:`` step.

    Returns:
        The messages, in line order.
    """
    found: list[str] = []
    for number, line in enumerate(script_lines(script), start=1):
        match = PRINTABLE.match(line)
        if match is not None and match.end() < len(line):
            char = line[match.end()]
            code = f"U+{ord(char):04X}"
            found.append(f"line {number}: character {code} is not printable ASCII")
    return found


def setting_problems(context: StepContext) -> list[str]:
    """Return what in a step's YAML makes any script in it unsafe to judge.

    Args:
        context: The step's YAML context.

    Returns:
        A message for a shell other than bash or sh, for each ``env:`` or
        ``container:`` the check refuses to read, and for each protected
        name an ``env:`` sets.
    """
    found: list[str] = []
    shell = context.run_shell
    if shell is not None and shell.strip() not in SHELLS:
        found.append(f"shell: {shell} is not bash or sh")
    found.extend(context.yaml_problems)
    for name in sorted(set(context.env) | context.inherited):
        reason = protected_reason(name)
        if reason:
            found.append(f"env: sets {name}, {reason}")
    return found
