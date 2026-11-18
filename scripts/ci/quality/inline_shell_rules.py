# SPDX-License-Identifier: MIT
"""The rules for inline shell in workflow and action files (#1624).

docs/inline-shell.md states them for contributors; this module is what
``validate_inline_shell.py`` enforces. A ``run:`` step is accepted when it is
one of three things:

Script call
    One command that runs a script file, and nothing else: no ``;``, ``&&``,
    ``||``, pipe, redirection, second line or command substitution. It is
    ``[INTERPRETER [OPTION]] PATH [ARGUMENT...]``, where INTERPRETER is one of
    :data:`INTERPRETERS` with only the options listed for it, and every
    argument is a literal or a plain variable (``$NAME``, ``${NAME}``,
    ``${NAME:-word}``). PATH is, in order of preference:

    - a file of this repository under ``scripts/``, written relative to the
      repository (``scripts/...``), to a tooling checkout of it
      (``.lgtm-ci-tooling/scripts/...``, ``.lgtm-ci-readiness/scripts/...``),
      to ``$GITHUB_WORKSPACE``, to ``$SCRIPTS_DIR`` (the composite actions'
      name for ``scripts/``) or, in a composite action, to
      ``$GITHUB_ACTION_PATH`` (``$GITHUB_ACTION_PATH/../../../scripts/...``).
      The file must exist;
    - in a composite action, a file next to its ``action.yml``
      (``$GITHUB_ACTION_PATH/name.sh``). The file must exist;
    - a path that names a variable set in the step's own ``env:``, alone or
      after one of the prefixes above (``"$GITHUB_WORKSPACE/$AUDIT_SCRIPT"``,
      ``.lgtm-ci-tooling/scripts/ci/release/${VERSION_SCRIPT}``). The value
      is input or caller data that the runner hands over as an environment
      variable, never shell code; the reusable documents the script it runs;
    - a staged copy listed in :data:`STAGED_COPIES`, with its source.

Generated copy
    Checked by ``validate_inline_shell.py``, not here.

Trivial
    All of :func:`trivial_problems` is empty:

    1. Only ``echo``, ``printf``, ``exit``, ``true`` and ``false`` run,
       inside at most one conditional: one ``if``/``elif``/``else``, one
       ``case``, or one ``A && B`` / ``A || B`` list. A condition is a
       ``[[ ]]``, ``[ ]`` or ``test`` that compares plain variables and
       literals (only the operators in :data:`TEST_OPERATORS`; no file
       tests). No other command or builtin, no assignment, no pipe, no
       command substitution, no expansion beyond ``${NAME:-word}``, no
       subshell, loop, function or background job. A ``case`` subject is a
       plain variable or literal.
    2. No redirection except ``>`` or ``>>`` to ``$GITHUB_OUTPUT``,
       ``$GITHUB_ENV`` or ``$GITHUB_STEP_SUMMARY``, and ``>&2`` / ``2>&1``
       to the console.
    3. No ``${{ }}`` expression (:func:`expression_lines`); this one applies
       to every inline step.
    4. At most :data:`MAX_LINES` lines of code (blank and comment-only
       lines do not count; a continued line counts per physical line).
    5. The same text (:func:`normalized`) in fewer than :data:`MAX_COPIES`
       steps; counted across the tree by the validator.
"""

from __future__ import annotations

import posixpath
import re
import sys
from dataclasses import dataclass
from enum import IntEnum
from pathlib import Path

if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))

# pylint: disable-next=wrong-import-position
from inline_shell_lexer import Kind, ShellSyntaxError, Token, Word, tokenize  # noqa: E402

MAX_LINES = 5
ASSIGNMENT = re.compile(r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)(\[[^]]*\])?\+?=")
MAX_COPIES = 10
ALLOWED_COMMANDS = frozenset({"echo", "printf", "exit", "true", "false"})
RUNNER_FILES = frozenset({"GITHUB_OUTPUT", "GITHUB_ENV", "GITHUB_STEP_SUMMARY"})
TEST_OPERATORS = frozenset(
    {
        "-n",
        "-z",
        "-v",
        "-eq",
        "-ne",
        "-lt",
        "-le",
        "-gt",
        "-ge",
    },
)
LOOP_WORDS = frozenset({"for", "while", "until", "select", "do", "done"})
INTERPRETERS: dict[str, frozenset[str]] = {
    "bash": frozenset(),
    "sh": frozenset(),
    "python": frozenset({"-I"}),
    "python3": frozenset({"-I"}),
    "/usr/bin/python3": frozenset({"-I"}),
}
TOOLING_CHECKOUTS = (".lgtm-ci-tooling/", ".lgtm-ci-readiness/")
# A copy staged out of the checkout before it can change, keyed by how the
# step names it: (variable, rest of the path) -> the tested source file.
STAGED_COPIES: dict[tuple[str, str], str] = {
    (
        "RUNNER_TEMP",
        "/check-tooling-ref-divergence.sh",
    ): ".github/actions/checkout-and-harden/check-tooling-ref-divergence.sh",
}


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


@dataclass(frozen=True)
class CallVerdict:
    """Whether a step is a script call.

    Attributes:
        ok: True when the step is exactly one script call.
        reason: Why it is not, else what it calls.
        shaped: True when the step looks like a call (one command with an
            interpreter or a path), so ``reason`` is worth reporting.
    """

    ok: bool
    reason: str
    shaped: bool = False


def script_call(
    script: str,
    *,
    env: frozenset[str],
    action_dir: str | None,
    repo: Path,
) -> CallVerdict:
    """Tell whether a step is one call to a script file.

    Args:
        script: The text of a ``run:`` step.
        env: The keys of the step's own ``env:``.
        action_dir: The composite action's directory relative to the
            repository (``.github/actions/name``), or None in a workflow.
        repo: The repository root, where a named script must exist.

    Returns:
        The verdict; ``reason`` names the script or what is not a call.
    """
    try:
        tokens = tokenize(script)
    except ShellSyntaxError as error:
        return CallVerdict(ok=False, reason=str(error))
    while tokens and tokens[-1].kind is Kind.NEWLINE:
        tokens.pop()
    while tokens and tokens[0].kind is Kind.NEWLINE:
        tokens.pop(0)
    other = [token for token in tokens if token.kind is not Kind.WORD]
    if not tokens or other:
        return CallVerdict(ok=False, reason="not exactly one command")
    words = [token.word for token in tokens if token.word is not None]
    for word in words:
        if word.substitution or word.expansion:
            return CallVerdict(ok=False, reason="a word substitutes or expands")
    index = 0
    interpreter = words[0].literal()
    if interpreter in INTERPRETERS:
        index = 1
        while index < len(words) and (words[index].literal() or "").startswith("-"):
            if words[index].literal() not in INTERPRETERS[interpreter]:
                return CallVerdict(
                    ok=False,
                    reason=f"{interpreter} option {words[index].literal()}",
                    shaped=True,
                )
            index += 1
    if index >= len(words):
        return CallVerdict(ok=False, reason="no script path", shaped=True)
    verdict = script_path(words[index], env=env, action_dir=action_dir, repo=repo)
    path_text = "".join(text for _, text in words[index].parts)
    shaped = index > 0 or "/" in path_text or bool(words[index].variables())
    return CallVerdict(ok=verdict.ok, reason=verdict.reason, shaped=shaped)


def script_path(
    word: Word,
    *,
    env: frozenset[str],
    action_dir: str | None,
    repo: Path,
) -> CallVerdict:
    """Tell whether a word names a script file the rules accept.

    Args:
        word: The path word of the command.
        env: The keys of the step's own ``env:``.
        action_dir: The composite action's directory, or None.
        repo: The repository root.

    Returns:
        The verdict for the path.
    """
    parts = list(word.parts)
    if len(parts) == 2 and parts[0][0] == "var" and parts[1][0] == "lit":
        staged = STAGED_COPIES.get((parts[0][1], parts[1][1]))
        if staged is not None:
            return CallVerdict(ok=True, reason=f"staged copy of {staged}")
    prefix = ""
    if parts and parts[0][0] == "var":
        name = parts[0][1]
        rest = parts[1:]
        if name in env:
            return _env_selected(rest, env)
        roots = {"GITHUB_WORKSPACE": "", "SCRIPTS_DIR": "scripts/"}
        if action_dir is not None:
            roots["GITHUB_ACTION_PATH"] = f"{action_dir}/"
        if name not in roots:
            return CallVerdict(
                ok=False,
                reason=f"path starts with ${name}, not a known root or a step env: key",
            )
        if not rest or rest[0][0] != "lit" or not rest[0][1].startswith("/"):
            return CallVerdict(ok=False, reason=f"${name} is not followed by /")
        prefix = roots[name]
        parts = [("lit", rest[0][1][1:]), *rest[1:]]
    static = ""
    for index, (kind, text) in enumerate(parts):
        if kind == "var":
            return _env_selected(parts[index:], env, prefix + static)
        static += text
    return _repository_file(prefix + static, action_dir=action_dir, repo=repo)


def _strip_checkout(path: str) -> str:
    """Return a path without a leading ``./`` or tooling checkout directory."""
    path = path.removeprefix("./")
    for checkout in TOOLING_CHECKOUTS:
        if path.startswith(checkout):
            return path[len(checkout) :]
    return path


def _env_selected(
    parts: list[tuple[str, str]],
    env: frozenset[str],
    prefix: str = "",
) -> CallVerdict:
    """Accept a path whose variable parts are all keys of the step's env."""
    names = [text for kind, text in parts if kind == "var"]
    missing = [name for name in names if name not in env]
    if missing:
        return CallVerdict(
            ok=False,
            reason=f"path uses ${missing[0]}, which the step's env: does not set",
        )
    directory = _strip_checkout(posixpath.normpath(prefix) if prefix else "")
    if prefix and not (directory + "/").startswith("scripts/"):
        return CallVerdict(ok=False, reason=f"{prefix} is not under scripts/")
    return CallVerdict(ok=True, reason="script chosen through the step's env:")


def _repository_file(path: str, *, action_dir: str | None, repo: Path) -> CallVerdict:
    """Accept a literal path to an existing script under the allowed places."""
    relative = _strip_checkout(posixpath.normpath(path))
    if relative.startswith("../") or relative.startswith("/"):
        return CallVerdict(ok=False, reason=f"{path} leaves the repository")
    allowed = relative.startswith("scripts/") or (
        action_dir is not None and relative.startswith(f"{action_dir}/")
    )
    if not allowed:
        return CallVerdict(ok=False, reason=f"{path} is not under scripts/")
    if not (repo / relative).is_file():
        return CallVerdict(ok=False, reason=f"{relative} is not a file")
    return CallVerdict(ok=True, reason=relative)


def trivial_problems(script: str) -> list[Problem]:
    """Return every rule (1, 2 and 4) a hand-written step breaks.

    Rule 3 and rule 5 are checked by the validator: rule 3 applies to every
    step, and rule 5 needs the whole tree.

    Args:
        script: The text of a ``run:`` step.

    Returns:
        The problems, in script order; empty when the step is trivial.
    """
    problems: list[Problem] = []
    try:
        tokens = tokenize(script)
    except ShellSyntaxError as error:
        problems.append(Problem(Rule.ALLOW_LIST, f"cannot be read as shell: {error}"))
    else:
        problems.extend(_Walker(tokens).run())
    lines = len(code_lines(script))
    if lines > MAX_LINES:
        problems.append(Problem(Rule.LINES, f"{lines} lines of code"))
    return problems


def _assigned(text: str) -> str:
    """Return the variable a word assigns (``NAME=value``), else ""."""
    match = ASSIGNMENT.match(text)
    return match["name"] if match else ""


class _Walker:  # pylint: disable=too-few-public-methods,too-many-instance-attributes
    """Walk the tokens of one script and collect what rules 1 and 2 forbid."""

    def __init__(self, tokens: list[Token]) -> None:
        self.tokens = tokens
        self.index = 0
        self.problems: list[Problem] = []
        self.at_command = True
        self.in_condition = False
        self.list_counted = False
        self.conditionals = 0
        self.case = ""

    def fail(self, rule: Rule, token: Token, message: str) -> None:
        """Record a problem at a token's line."""
        self.problems.append(Problem(rule, f"line {token.line}: {message}"))

    def run(self) -> list[Problem]:
        """Walk every token."""
        while self.index < len(self.tokens):
            token = self.tokens[self.index]
            self.index += 1
            if token.kind is Kind.NEWLINE:
                self._end_statement()
            elif token.kind is Kind.OPERATOR:
                self._operator(token)
            elif token.kind is Kind.REDIRECT:
                self._redirect(token)
            else:
                self._word(token)
        if self.conditionals > 1:
            limit = "at most one if, case or && / || list"
            message = f"{self.conditionals} conditionals; {limit}"
            self.problems.append(Problem(Rule.ALLOW_LIST, message))
        return self.problems

    def _end_statement(self) -> None:
        self.at_command = True
        self.list_counted = False

    def _operator(self, token: Token) -> None:
        text = token.text
        if self.case == "pattern" and text in {"|", "("}:
            return
        if self.case == "pattern" and text == ")":
            self.case = "body"
            self._end_statement()
        elif text in {";", ";;", ";&", ";;&"}:
            if text != ";" and self.case == "body":
                self.case = "pattern"
            self._end_statement()
        elif text in {"&&", "||"}:
            if not self.in_condition and not self.list_counted:
                self.conditionals += 1
                self.list_counted = True
            self.at_command = True
        elif text in {"|", "|&"}:
            self.fail(Rule.ALLOW_LIST, token, "a pipe")
            self.at_command = True
        elif text == "&":
            self.fail(Rule.ALLOW_LIST, token, "a background job")
        else:
            self.fail(Rule.ALLOW_LIST, token, f"`{text}`: a subshell or function")

    def _redirect(self, token: Token) -> None:
        target = self._next_word()
        if target is None:
            self.fail(Rule.REDIRECTION, token, f"`{token.text}` without a target")
            return
        word = target.word
        assert word is not None  # noqa: S101 - _next_word returns words only
        parts = word.parts
        to_file = (
            token.text in {">", ">>"}
            and token.fd in {"", "1"}
            and len(parts) == 1
            and parts[0][0] == "var"
            and parts[0][1] in RUNNER_FILES
        )
        to_console = token.text == ">&" and word.literal() in {"1", "2"}
        if not (to_file or to_console):
            self.fail(
                Rule.REDIRECTION,
                token,
                f"redirection `{token.fd}{token.text} {target.text}`",
            )

    def _next_word(self) -> Token | None:
        if self.index < len(self.tokens) and self.tokens[self.index].kind is Kind.WORD:
            self.index += 1
            return self.tokens[self.index - 1]
        return None

    def _check_word(self, token: Token) -> None:
        word = token.word
        assert word is not None  # noqa: S101 - called for words only
        if word.substitution:
            message = f"command substitution {word.substitution}"
            self.fail(Rule.ALLOW_LIST, token, message)
        if word.expansion:
            self.fail(Rule.ALLOW_LIST, token, f"expansion {word.expansion}")

    def _word(self, token: Token) -> None:
        self._check_word(token)
        word = token.word
        assert word is not None  # noqa: S101 - called for words only
        literal = word.literal()
        reserved = literal if not word.quoted else None
        if self.case and self._case_word(token, reserved):
            return
        if not self.at_command:
            return
        if reserved in {"if", "elif", "then", "else", "fi", "{", "}", "!", "case"}:
            self._keyword(reserved)
        elif reserved in {"[[", "[", "test"}:
            self._test(reserved)
        elif reserved in LOOP_WORDS:
            self.fail(Rule.ALLOW_LIST, token, f"a loop (`{reserved}`)")
            self.at_command = reserved in {"do", "done"}
        elif reserved == "function" or self._defines_function():
            self.fail(Rule.ALLOW_LIST, token, "a function")
            self.index += 2 if reserved != "function" else 0
        elif _assigned(token.text):
            self.fail(Rule.ALLOW_LIST, token, f"assigns {_assigned(token.text)}")
        elif literal not in ALLOWED_COMMANDS:
            self.fail(
                Rule.ALLOW_LIST,
                token,
                f"runs `{token.text}`, which is not echo, printf, exit, true or false",
            )
            self.at_command = False
        else:
            self.at_command = False
            if literal == "printf":
                self._printf_options()

    def _keyword(self, reserved: str | None) -> None:
        if reserved == "if":
            self.conditionals += 1
            self.in_condition = True
        elif reserved == "elif":
            self.in_condition = True
        elif reserved == "then":
            self.in_condition = False
        elif reserved in {"fi", "}"}:
            self.at_command = False
        elif reserved == "case":
            self.conditionals += 1
            self.case = "subject"
            self.at_command = False

    def _case_word(self, token: Token, reserved: str | None) -> bool:
        """Handle a word inside a case statement; True when consumed."""
        word = token.word
        assert word is not None  # noqa: S101 - called for words only
        if self.case == "subject":
            if len(word.parts) > 1:
                message = "case on more than one plain variable"
                self.fail(Rule.ALLOW_LIST, token, message)
            self.case = "in"
            return True
        if self.case == "in":
            if reserved != "in":
                self.fail(Rule.ALLOW_LIST, token, "case without `in`")
            self.case = "pattern"
            return True
        if reserved == "esac" and (self.case == "pattern" or self.at_command):
            self.case = ""
            self.at_command = False
            return True
        return self.case == "pattern"

    def _defines_function(self) -> bool:
        rest = self.tokens[self.index : self.index + 2]
        return [token.text for token in rest] == ["(", ")"]

    def _printf_options(self) -> None:
        nxt = self.tokens[self.index] if self.index < len(self.tokens) else None
        if nxt is not None and nxt.word is not None and nxt.word.literal() == "-v":
            self.fail(Rule.ALLOW_LIST, nxt, "printf -v assigns a variable")

    def _test(self, opener: str | None) -> None:
        """Consume one test and check that it only compares values."""
        closer = "]]" if opener == "[[" else "]"
        while self.index < len(self.tokens):
            token = self.tokens[self.index]
            if token.kind is Kind.NEWLINE or (
                token.kind is Kind.OPERATOR
                and token.text not in {"&&", "||", "(", ")"}
                and opener == "[["
            ):
                break
            if opener != "[[" and token.kind is not Kind.WORD:
                break
            self.index += 1
            if token.kind is Kind.REDIRECT and opener == "[[":
                continue
            if token.kind is not Kind.WORD:
                continue
            self._check_word(token)
            word = token.word
            assert word is not None  # noqa: S101 - kind is WORD
            literal = word.literal()
            if literal == closer and not word.quoted:
                self.at_command = False
                return
            if (
                literal is not None
                and not word.quoted
                and len(literal) > 1
                and literal.startswith("-")
                and literal not in TEST_OPERATORS
            ):
                self.fail(
                    Rule.ALLOW_LIST,
                    token,
                    f"test `{literal}` reads more than a plain variable",
                )
        self.at_command = False
        if opener == "[[":
            last = self.tokens[self.index - 1] if self.index else None
            self.fail(
                Rule.ALLOW_LIST,
                last or self.tokens[0],
                "unclosed [[",
            )
