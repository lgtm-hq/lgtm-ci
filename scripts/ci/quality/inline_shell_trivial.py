# SPDX-License-Identifier: MIT
"""Rules 1, 2 and 4 of the trivial-step definition (#1624).

1. Only ``echo``, ``printf``, ``exit``, ``true`` and ``false`` run, inside at
   most one conditional: one ``if``/``elif``/``else``, one ``case``, or one
   ``A && B`` / ``A || B`` list. A condition is a ``[[ ]]``, ``[ ]`` or
   ``test`` that compares plain variables and literals as strings (only
   ``TEST_OPERATORS`` and comparisons; no file, arithmetic or ``-v`` test).
   In ``[ ]`` and ``test`` every variable is double-quoted and the test is
   ``A``, ``-n A``, ``-z A``, ``! A`` or ``A OP B`` with OP a literal ``=``,
   ``==`` or ``!=``. ``printf`` and ``echo`` take no option
   (``inline_shell_options``): printf's first argument is a literal format
   that does not start with ``-``, and echo's starts with literal text other
   than ``-``, so no variable can expand into ``-e``. No other command or
   builtin, no assignment, no pipe, no command substitution or arithmetic
   (``$(( ))``, ``(( ))``, ``let``), no expansion beyond ``${NAME:-word}`` and
   ``${NAME-word}``, no subshell, loop, function or background job. A ``case``
   subject is a plain variable or literal.
2. No redirection except ``>`` or ``>>`` to a plain ``$GITHUB_OUTPUT`` or
   ``$GITHUB_STEP_SUMMARY`` (no default, suffix or substitution), and
   ``>&1`` / ``>&2`` from descriptor 1 or 2 to the console.
4. At most ``MAX_LINES`` lines of code (blank and comment-only lines do not
   count; a continued line counts per physical line).
"""

from __future__ import annotations

import re

from inline_shell_lexer import Kind, ShellSyntaxError, Token, tokenize
from inline_shell_options import option_problem
from inline_shell_rules import (
    ALLOWED_COMMANDS,
    BRACKET_COMPARISONS,
    LOOP_WORDS,
    MAX_LINES,
    RUNNER_FILES,
    TEST_OPERATORS,
    Problem,
    Rule,
    code_lines,
)

ASSIGNMENT = re.compile(r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)(\[[^]]*\])?\+?=")
CONSOLE = frozenset({"", "1", "2"})


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
        """Expect a new command after a statement ends."""
        self.at_command = True
        self.list_counted = False

    def _operator(self, token: Token) -> None:
        """Check one operator token and track the statement and ``case`` state."""
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
            message = f"`{text}`: a subshell, function or arithmetic"
            self.fail(Rule.ALLOW_LIST, token, message)

    def _redirect(self, token: Token) -> None:
        """Check a redirection and its target word."""
        target = self._next_word()
        if target is None:
            self.fail(Rule.REDIRECTION, token, f"`{token.text}` without a target")
            return
        word = target.word
        assert word is not None  # noqa: S101 - _next_word returns words only
        parts = word.parts
        plain = not (word.substitution or word.expansion or word.defaulted)
        named = parts[0][1] if len(parts) == 1 and parts[0][0] == "var" else ""
        to_file = token.text in {">", ">>"} and token.fd in {"", "1"} and plain
        duplicate = token.text == ">&" and token.fd in CONSOLE
        to_console = duplicate and word.literal() in {"1", "2"}
        if to_file and named in {"GITHUB_ENV", "GITHUB_PATH"}:
            message = f"writes ${named}, which every later step loads; use a script"
            self.fail(Rule.REDIRECTION, token, message)
        elif not ((to_file and named in RUNNER_FILES) or to_console):
            message = f"redirection `{token.fd}{token.text} {target.text}`"
            self.fail(Rule.REDIRECTION, token, message)

    def _next_word(self) -> Token | None:
        """Consume and return the next token when it is a word, else None."""
        if self.index < len(self.tokens) and self.tokens[self.index].kind is Kind.WORD:
            self.index += 1
            return self.tokens[self.index - 1]
        return None

    def _check_word(self, token: Token) -> None:
        """Fail a word that holds a command substitution or an expansion."""
        word = token.word
        assert word is not None  # noqa: S101 - called for words only
        if word.substitution:
            message = f"command substitution {word.substitution}"
            self.fail(Rule.ALLOW_LIST, token, message)
        if word.expansion:
            self.fail(Rule.ALLOW_LIST, token, f"expansion {word.expansion}")

    def _word(self, token: Token) -> None:
        """Check one word token as a command, argument or keyword."""
        self._check_word(token)
        word = token.word
        assert word is not None  # noqa: S101 - called for words only
        literal = word.literal()
        reserved = literal if not word.quoted else None
        if self.case and self._case_word(token, reserved):
            return
        self._check_pattern(token)
        if not self.at_command:
            if word.unquoted_variable:
                message = (
                    f"unquoted variable in `{token.text}`: bash splits and globs "
                    'its value into options or several words; write "$NAME"'
                )
                self.fail(Rule.ALLOW_LIST, token, message)
            return
        if reserved in {"if", "elif", "then", "else", "fi", "{", "}", "!", "case"}:
            self._keyword(reserved)
        elif reserved == "[[":
            self._double_test()
        elif reserved in {"[", "test"}:
            self._bracket_test(reserved)
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
            self._options(token, literal)

    def _options(self, command: Token, name: str) -> None:
        """Fail an option of printf or echo (``inline_shell_options``).

        A redirection before the first argument
        (``printf >> $GITHUB_OUTPUT -v NAME``) does not hide it.
        """
        first = self._first_argument()
        message = option_problem(name, first.word if first is not None else None)
        if message:
            self.fail(Rule.ALLOW_LIST, command, message)

    def _first_argument(self) -> Token | None:
        """Return the running command's first argument, past any redirections."""
        index = self.index
        while index < len(self.tokens) and self.tokens[index].kind is Kind.REDIRECT:
            index += 2
        if index < len(self.tokens) and self.tokens[index].kind is Kind.WORD:
            return self.tokens[index]
        return None

    def _keyword(self, reserved: str | None) -> None:
        """Track conditionals for a reserved word."""
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
        """Tell whether the next tokens are ``()``, which define a function."""
        rest = self.tokens[self.index : self.index + 2]
        return [token.text for token in rest] == ["(", ")"]

    def _check_pattern(self, token: Token) -> None:
        """Fail a word that brace, pathname or tilde expansion would change."""
        word = token.word
        assert word is not None  # noqa: S101 - called for words only
        kind = word.pattern()
        if kind:
            message = (
                f"`{token.text}` is open to {kind} expansion, which can turn it "
                "into an option or several words; quote it"
            )
            self.fail(Rule.ALLOW_LIST, token, message)

    def _double_test(self) -> None:
        """Consume one ``[[ ]]`` and check that it only compares strings."""
        while self.index < len(self.tokens):
            token = self.tokens[self.index]
            if token.kind is Kind.NEWLINE or (
                token.kind is Kind.OPERATOR and token.text not in {"&&", "||", "(", ")"}
            ):
                break
            self.index += 1
            if token.kind is not Kind.WORD:
                # `<` and `>` compare strings inside [[ ]]; `&&`, `||` and
                # parentheses group tests.
                continue
            self._check_word(token)
            word = token.word
            assert word is not None  # noqa: S101 - kind is WORD
            literal = word.literal()
            if literal == "]]" and not word.quoted:
                self.at_command = False
                return
            if (
                literal is not None
                and not word.quoted
                and len(literal) > 1
                and literal.startswith("-")
                and literal not in TEST_OPERATORS
            ):
                message = f"test `{literal}` is not a string comparison"
                self.fail(Rule.ALLOW_LIST, token, message)
        self.at_command = False
        last = self.tokens[self.index - 1] if self.index else self.tokens[0]
        self.fail(Rule.ALLOW_LIST, last, "unclosed [[")

    def _bracket_test(self, opener: str) -> None:
        """Consume one ``[ ]`` or ``test`` and check its shape.

        Its words are expanded before the test reads them, so a variable must
        be quoted and must not take an operator's place.
        """
        start = self.tokens[self.index - 1]
        words: list[Token] = []
        closed = opener == "test"
        while self.index < len(self.tokens):
            token = self.tokens[self.index]
            if token.kind is not Kind.WORD:
                break
            self.index += 1
            word = token.word
            assert word is not None  # noqa: S101 - kind is WORD
            if opener == "[" and word.literal() == "]" and not word.quoted:
                closed = True
                break
            self._check_word(token)
            self._check_pattern(token)
            if word.unquoted_variable:
                message = f"unquoted variable in {opener}: `{token.text}`"
                self.fail(Rule.ALLOW_LIST, token, message)
            words.append(token)
        self.at_command = False
        if not closed:
            self.fail(Rule.ALLOW_LIST, start, f"unclosed {opener}")
        texts = [token.word.literal() if token.word else None for token in words]
        unquoted = [not token.word.quoted if token.word else False for token in words]
        if len(words) == 2 and unquoted[0] and texts[0] in {*TEST_OPERATORS, "!"}:
            return
        if len(words) == 3 and unquoted[1] and texts[1] in BRACKET_COMPARISONS:
            return
        if len(words) == 1 and not (unquoted[0] and (texts[0] or "").startswith("-")):
            return
        first = next((t for t, u in zip(texts, unquoted, strict=True) if u and t), "")
        shown = f"test `{first}`" if first.startswith("-") else f"a {opener} test"
        message = f"{shown}: only A, -n A, -z A, ! A or A = B (==, !=) on strings"
        self.fail(Rule.ALLOW_LIST, start, message)
