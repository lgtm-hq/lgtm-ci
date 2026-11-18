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
``sh`` (:data:`SHELLS`), and no ``env:`` at any level may set a name in
:data:`PROTECTED_ENV` (the runner paths the check trusts, and the variables
that make bash, the loader or an interpreter run code) or starting with one
of :data:`PROTECTED_ENV_PREFIXES`. A hand-written step
holds printable ASCII only (:func:`character_problems`).
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import dataclass, field
from enum import IntEnum

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
# Runner paths the check trusts as roots or as write targets. An env: entry
# that sets one would point a script call or a write somewhere else.
RUNNER_PATHS = frozenset(
    {
        "GITHUB_OUTPUT",
        "GITHUB_STEP_SUMMARY",
        "GITHUB_ENV",
        "GITHUB_PATH",
        "GITHUB_WORKSPACE",
        "GITHUB_ACTION_PATH",
        "SCRIPTS_DIR",
        "RUNNER_TEMP",
    },
)
# Variables that make a process run code of their own choosing before or
# around the step's text: bash (BASH_ENV and ENV are expanded, so
# '$(curl ...)' runs; PS4 runs under xtrace; SHELLOPTS/BASHOPTS turn that on),
# the dynamic loader (LD_*), command and word lookup (PATH, CDPATH, IFS,
# GLOBIGNORE), and the interpreters a script call may reach. python3 -I
# ignores PYTHON*, but python3 without -I, a script's own shebang and the
# scripts' subprocesses do not. Node is reached from scripts (setup-node.sh,
# the npm release ecosystem), and NODE_OPTIONS accepts --import / --require.
# ACTIONS_ALLOW_UNSECURE_COMMANDS brings back ::set-env and ::add-path, so a
# value a trivial step echoes could set BASH_ENV for the later steps.
CODE_HOOK_ENV = frozenset(
    {
        "ACTIONS_ALLOW_UNSECURE_COMMANDS",
        "BASH_ENV",
        "ENV",
        "SHELLOPTS",
        "BASHOPTS",
        "PS4",
        "PROMPT_COMMAND",
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        "LD_AUDIT",
        "PATH",
        "IFS",
        "CDPATH",
        "GLOBIGNORE",
        "PYTHONSTARTUP",
        "PYTHONPATH",
        "PYTHONHOME",
        "NODE_OPTIONS",
    },
)
PROTECTED_ENV = RUNNER_PATHS | CODE_HOOK_ENV
# An exported bash function arrives as BASH_FUNC_<name>%%; it replaces the
# command <name> (echo, printf) in every bash the step starts.
PROTECTED_ENV_PREFIXES = ("BASH_FUNC_",)
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
    """

    env: Mapping[str, str | None] = field(default_factory=dict)
    inherited: frozenset[str] = frozenset()
    action_dir: str | None = None
    working_directory: str | None = None
    run_shell: str | None = None
    caller_inputs: bool = False


def code_lines(script: str) -> list[str]:
    """Return the lines of a script that hold code, stripped.

    Args:
        script: The text of a ``run:`` step.

    Returns:
        Every line that is neither blank nor only a comment.
    """
    stripped = (line.strip() for line in script.splitlines())
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
    return [n for n, line in enumerate(script.splitlines(), start=1) if "${{" in line]


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
    for number, line in enumerate(script.split("\n"), start=1):
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
        A message for a shell other than bash or sh, and for each protected
        name an ``env:`` sets.
    """
    found: list[str] = []
    shell = context.run_shell
    if shell is not None and shell.strip() not in SHELLS:
        found.append(f"shell: {shell} is not bash or sh")
    for name in sorted(set(context.env) | context.inherited):
        if name in RUNNER_PATHS:
            found.append(f"env: sets {name}, a runner path the check trusts")
        elif name in CODE_HOOK_ENV or name.startswith(PROTECTED_ENV_PREFIXES):
            message = "which can make this or a later step run code"
            found.append(f"env: sets {name}, {message}")
    return found
