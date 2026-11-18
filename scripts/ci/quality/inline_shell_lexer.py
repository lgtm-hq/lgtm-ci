# SPDX-License-Identifier: MIT
"""Split the text of a ``run:`` step into shell tokens (#1624).

This is not a shell parser. It reads just enough bash to tell what an inline
step runs: words, operators, redirections and newlines, and for each word
whether it holds a command substitution or an expansion other than a plain
variable. Anything it cannot read is a :class:`ShellSyntaxError`, which the
check treats as a broken rule, never as harmless.

A word keeps its parts: literal text and the names of the variables it
expands, so ``"$GITHUB_WORKSPACE"/.lgtm-ci-tooling/x.sh`` reads as the
variable ``GITHUB_WORKSPACE`` followed by ``/.lgtm-ci-tooling/x.sh``.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from enum import StrEnum, auto

NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# ${NAME}, ${NAME:-word} and ${NAME-word} with a literal word: the only braced
# forms a trivial step or a script call may use. They read a value and change
# nothing (``:=`` assigns, so it is not here).
BRACED = re.compile(r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)(?::?-(?P<default>[^$`\\\"']*))?")
SPECIAL = frozenset("?#@*$!-0123456789")
# Longest first, so ``>>`` wins over ``>``.
OPERATORS = (
    "&>>",
    "<<<",
    "<<-",
    ";;&",
    "&&",
    "||",
    ";;",
    ";&",
    "|&",
    ">>",
    ">|",
    ">&",
    "<&",
    "<>",
    "<<",
    "&>",
    ";",
    "|",
    "&",
    "(",
    ")",
    "<",
    ">",
)
REDIRECTIONS = frozenset(
    {"&>>", "<<<", "<<-", ">>", ">|", ">&", "<&", "<>", "<<", "&>", "<", ">"},
)


class ShellSyntaxError(ValueError):
    """The text is not shell this lexer can read (an unclosed quote, say)."""


class Kind(StrEnum):
    """What a token is."""

    WORD = auto()
    OPERATOR = auto()
    REDIRECT = auto()
    NEWLINE = auto()


@dataclass
class Word:
    """The parts of one shell word.

    Attributes:
        parts: ``("lit", text)`` and ``("var", name)`` in order.
        quoted: True when any part of the word was quoted.
        substitution: What runs a command or computes inside the word
            (``$(...)``, a backtick, ``$((...))``, ``<(...)``), else "".
        expansion: A parameter expansion other than ``$NAME``, ``${NAME}``
            and ``${NAME:-word}``, else "".
    """

    parts: list[tuple[str, str]] = field(default_factory=list)
    quoted: bool = False
    substitution: str = ""
    expansion: str = ""

    def literal(self) -> str | None:
        """Return the text when the word expands nothing, else None."""
        if any(kind == "var" for kind, _ in self.parts):
            return None
        return "".join(text for _, text in self.parts)

    def variables(self) -> list[str]:
        """Return the names of the variables the word expands."""
        return [text for kind, text in self.parts if kind == "var"]

    def add(self, kind: str, text: str) -> None:
        """Append a part, merging adjacent literal text."""
        if kind == "lit" and self.parts and self.parts[-1][0] == "lit":
            self.parts[-1] = ("lit", self.parts[-1][1] + text)
        else:
            self.parts.append((kind, text))


@dataclass
class Token:
    """One token with the line it starts on (1-based, within the script).

    Attributes:
        kind: What the token is.
        text: The source text (an operator, or the word as written).
        line: Line number within the script.
        word: The parsed word, for :attr:`Kind.WORD` tokens.
        fd: The file descriptor written before a redirection (``2>``), or "".
    """

    kind: Kind
    text: str
    line: int
    word: Word | None = None
    fd: str = ""


class _Lexer:  # pylint: disable=too-few-public-methods
    """Read a script once, left to right."""

    def __init__(self, script: str) -> None:
        self.text = script
        self.pos = 0
        self.line = 1
        self.tokens: list[Token] = []

    def peek(self, offset: int = 0) -> str:
        """Return the character ``offset`` ahead, or "" past the end."""
        index = self.pos + offset
        return self.text[index] if index < len(self.text) else ""

    def run(self) -> list[Token]:
        """Tokenize the whole script."""
        while self.pos < len(self.text):
            char = self.peek()
            if char in " \t":
                self.pos += 1
            elif char == "\\" and self.peek(1) == "\n":
                self.pos += 2
                self.line += 1
            elif char == "\n":
                self.tokens.append(Token(Kind.NEWLINE, "\n", self.line))
                self.pos += 1
                self.line += 1
            elif char == "#":
                while self.pos < len(self.text) and self.peek() != "\n":
                    self.pos += 1
            elif self._operator():
                continue
            else:
                self._word()
        return self.tokens

    def _operator(self, fd: str = "") -> bool:
        """Read an operator at the cursor, if there is one."""
        for operator in OPERATORS:
            if self.text.startswith(operator, self.pos):
                if operator in {"<", ">"} and self.peek(1) == "(":
                    raise ShellSyntaxError(f"line {self.line}: process substitution")
                kind = Kind.REDIRECT if operator in REDIRECTIONS else Kind.OPERATOR
                self.tokens.append(Token(kind, operator, self.line, fd=fd))
                self.pos += len(operator)
                return True
        return False

    def _word(self) -> None:
        """Read one word, which ends at a blank, a newline or an operator."""
        start, line, word = self.pos, self.line, Word()
        while self.pos < len(self.text):
            char = self.peek()
            at_operator = any(self.text.startswith(op, self.pos) for op in OPERATORS)
            if char in " \t\n" or at_operator:
                break
            if char == "\\":
                if self.peek(1) == "\n":
                    self.pos += 2
                    self.line += 1
                    continue
                word.add("lit", self.peek(1))
                self.pos += 2
            elif char == "'":
                end = self.text.find("'", self.pos + 1)
                if end < 0:
                    raise ShellSyntaxError(f"line {self.line}: unclosed single quote")
                word.add("lit", self.text[self.pos + 1 : end])
                word.quoted = True
                self.line += self.text.count("\n", self.pos, end)
                self.pos = end + 1
            elif char == '"':
                word.quoted = True
                self._double_quoted(word)
            elif char == "$":
                self._dollar(word)
            elif char == "`":
                word.substitution = word.substitution or "backtick"
                end = self.text.find("`", self.pos + 1)
                if end < 0:
                    raise ShellSyntaxError(f"line {self.line}: unclosed backtick")
                self.pos = end + 1
            else:
                word.add("lit", char)
                self.pos += 1
        raw = self.text[start : self.pos]
        literal = word.literal()
        if (
            literal is not None
            and literal.isdigit()
            and not word.quoted
            and self.peek() in {"<", ">"}
        ):
            # ``2>&1``: the digits are the redirection's descriptor.
            self._operator(fd=literal)
            return
        self.tokens.append(Token(Kind.WORD, raw, line, word=word))

    def _double_quoted(self, word: Word) -> None:
        """Read a double-quoted string into ``word``."""
        self.pos += 1
        while True:
            if self.pos >= len(self.text):
                raise ShellSyntaxError(f"line {self.line}: unclosed double quote")
            char = self.peek()
            if char == '"':
                self.pos += 1
                return
            if char == "\\" and self.peek(1) in '$`"\\\n':
                if self.peek(1) == "\n":
                    self.line += 1
                else:
                    word.add("lit", self.peek(1))
                self.pos += 2
            elif char == "$":
                self._dollar(word)
            elif char == "`":
                word.substitution = word.substitution or "backtick"
                end = self.text.find("`", self.pos + 1)
                if end < 0:
                    raise ShellSyntaxError(f"line {self.line}: unclosed backtick")
                self.pos = end + 1
            else:
                if char == "\n":
                    self.line += 1
                word.add("lit", char)
                self.pos += 1

    def _dollar(self, word: Word) -> None:
        """Read what follows a ``$`` into ``word``."""
        nxt = self.peek(1)
        if nxt == "(":
            word.substitution = word.substitution or (
                "$((...))" if self.peek(2) == "(" else "$(...)"
            )
            self.pos = self._closing(self.pos + 1, "(", ")")
        elif nxt == "{":
            end = self._closing(self.pos + 1, "{", "}")
            inner = self.text[self.pos + 2 : end - 1]
            match = BRACED.fullmatch(inner)
            if "$(" in inner or "`" in inner:
                word.substitution = word.substitution or "$(...)"
            elif match is None:
                word.expansion = word.expansion or f"${{{inner}}}"
            else:
                word.add("var", match["name"])
            self.pos = end
        elif nxt and NAME.match(nxt):
            match = NAME.match(self.text, self.pos + 1)
            assert match is not None  # noqa: S101 - nxt matched above
            word.add("var", match.group(0))
            self.pos = match.end()
        elif nxt and nxt in SPECIAL:
            word.add("var", nxt)
            self.pos += 2
        else:
            word.add("lit", "$")
            self.pos += 1

    def _closing(self, start: int, opening: str, closing: str) -> int:
        """Return the index just past the bracket that closes ``start``."""
        depth, index = 0, start
        while index < len(self.text):
            char = self.text[index]
            if char == opening:
                depth += 1
            elif char == closing:
                depth -= 1
                if depth == 0:
                    self.line += self.text.count("\n", start, index)
                    return index + 1
            index += 1
        raise ShellSyntaxError(f"line {self.line}: unclosed {opening}")


def tokenize(script: str) -> list[Token]:
    """Split a script into tokens.

    Args:
        script: The text of a ``run:`` step.

    Returns:
        The tokens, comments dropped and line continuations joined.

    Raises:
        ShellSyntaxError: When the text cannot be read (an unclosed quote,
            bracket or backtick, or a process substitution).
    """
    return _Lexer(script).run()
