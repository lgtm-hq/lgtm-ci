#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Evaluate a GitHub Actions `if:` expression against a flat test context.

Contract tests use this to check what a workflow condition *does* in a given
scenario (prepare failed, draft PR, single-version call, ...) rather than
which tokens it contains. It covers the subset of the expression language the
workflows here use: literals, dotted context paths, `!`, `&&`, `||`,
comparisons, parentheses, and the status functions.

Usage:
    gha_expr.py [--value] EXPRESSION [KEY=STRING | KEY:=JSON]...

`KEY=STRING` binds a string (step and job outputs are always strings);
`KEY:=JSON` binds a typed value (`true`, `false`, `null`, numbers) for
boolean inputs and event fields. Unbound paths evaluate to null. `job.status`
(default `success`) drives the status functions; an expression without one is
wrapped in an implicit `success() && (...)`, as the runner does for `if:`.
Pass `--value` to evaluate a plain value expression (for example a job
output) without that wrapper.

Both operands of `&&` / `||` are evaluated eagerly. Evaluation has no side
effects, so the result matches the runner's short-circuit evaluation; the only
difference is that a parse error on either side is always reported.

Prints `true` or `false` for the expression's truthiness; exits 2 on a parse
error.
"""

from __future__ import annotations

import json
import math
import re
import sys
from collections.abc import Callable
from dataclasses import dataclass

Value = str | float | bool | None

_TOKEN = re.compile(
    r"\s*(?:"
    r"(?P<str>'(?:[^']|'')*')"
    r"|(?P<num>-?\d+(?:\.\d+)?)"
    r"|(?P<op>&&|\|\||==|!=|<=|>=|<|>|!|\(|\)|,)"
    r"|(?P<ident>[A-Za-z_][A-Za-z0-9_-]*(?:\.[A-Za-z_][A-Za-z0-9_-]*)*)"
    r")",
)
_STATUS_FUNCTIONS = ("always", "success", "failure", "cancelled")
_LITERALS: dict[str, Value] = {"true": True, "false": False, "null": None}
_USAGE = "usage: gha_expr.py [--value] EXPRESSION [KEY=VALUE | KEY:=JSON]..."


class ExpressionError(ValueError):
    """Raised when an expression cannot be parsed."""


@dataclass(frozen=True)
class Token:
    """One lexical token.

    Attributes:
        kind: Token category (`str`, `num`, `op`, or `ident`).
        text: Raw token text.
    """

    kind: str
    text: str


def tokenize(expression: str) -> list[Token]:
    """Split an expression into tokens.

    Args:
        expression: Expression source, without the `${{ }}` wrapper.

    Returns:
        The token list.

    Raises:
        ExpressionError: On an unrecognised character.
    """
    tokens: list[Token] = []
    pos = 0
    source = expression.strip()
    while pos < len(source):
        match = _TOKEN.match(source, pos)
        if match is None or match.end() == pos:
            raise ExpressionError(f"unexpected input at {source[pos:]!r}")
        kind = match.lastgroup
        if kind is None:
            raise ExpressionError(f"unexpected input at {source[pos:]!r}")
        tokens.append(Token(kind=kind, text=match.group(kind)))
        pos = match.end()
        while pos < len(source) and source[pos].isspace():
            pos += 1
    return tokens


def to_number(value: Value) -> float:
    """Coerce a value to a number using GitHub's rules.

    Args:
        value: Value to coerce.

    Returns:
        The numeric value, or NaN when the string is not numeric.
    """
    if value is None:
        return 0.0
    if isinstance(value, bool):
        return 1.0 if value else 0.0
    if isinstance(value, float):
        return value
    text = value.strip()
    if text == "":
        return 0.0
    try:
        return float(text)
    except ValueError:
        return math.nan


def truthy(value: Value) -> bool:
    """Return the truthiness of a value using GitHub's rules.

    Args:
        value: Value to test.

    Returns:
        False for null, false, 0, NaN, and the empty string; otherwise True.
    """
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    if isinstance(value, float):
        return not (value == 0 or math.isnan(value))
    return value != ""


def equals(left: Value, right: Value) -> bool:
    """Compare two values with GitHub's loose equality.

    Args:
        left: Left operand.
        right: Right operand.

    Returns:
        Whether the operands are equal.
    """
    if isinstance(left, str) and isinstance(right, str):
        return left.casefold() == right.casefold()
    if type(left) is type(right) and not isinstance(left, float):
        return left == right
    return to_number(left) == to_number(right)


class Parser:
    """Recursive-descent evaluator over a token list.

    Args:
        tokens: Tokens to evaluate.
        context: Flat mapping of dotted paths to values.
    """

    def __init__(self, tokens: list[Token], context: dict[str, Value]) -> None:
        self.tokens = tokens
        self.pos = 0
        self.context = context

    def peek(self) -> Token | None:
        """Return the next token without consuming it.

        Returns:
            The next token, or None at the end.
        """
        return self.tokens[self.pos] if self.pos < len(self.tokens) else None

    def take(self, text: str | None = None) -> Token:
        """Consume the next token, optionally requiring its text.

        Args:
            text: Required token text, if any.

        Returns:
            The consumed token.

        Raises:
            ExpressionError: When the input ends or the text does not match.
        """
        token = self.peek()
        if token is None or (text is not None and token.text != text):
            raise ExpressionError(f"expected {text or 'a token'}, got {token}")
        self.pos += 1
        return token

    def parse(self) -> Value:
        """Evaluate the whole token list.

        Returns:
            The expression value.

        Raises:
            ExpressionError: On trailing tokens.
        """
        value = self.parse_or()
        if self.peek() is not None:
            raise ExpressionError(f"unexpected trailing token {self.peek()}")
        return value

    def parse_or(self) -> Value:
        """Evaluate a `||` chain.

        Returns:
            The first truthy operand, else the last operand.
        """
        value = self.parse_and()
        while self._at_op("||"):
            self.take()
            right = self.parse_and()
            value = value if truthy(value) else right
        return value

    def parse_and(self) -> Value:
        """Evaluate a `&&` chain.

        Returns:
            The first falsy operand, else the last operand.
        """
        value = self.parse_comparison()
        while self._at_op("&&"):
            self.take()
            right = self.parse_comparison()
            value = right if truthy(value) else value
        return value

    def parse_comparison(self) -> Value:
        """Evaluate an optional binary comparison.

        Returns:
            The comparison result, or the operand when there is none.
        """
        left = self.parse_unary()
        token = self.peek()
        if token is None or token.kind != "op":
            return left
        compare: dict[str, Callable[[Value, Value], bool]] = {
            "==": equals,
            "!=": lambda a, b: not equals(a, b),
            "<": lambda a, b: to_number(a) < to_number(b),
            "<=": lambda a, b: to_number(a) <= to_number(b),
            ">": lambda a, b: to_number(a) > to_number(b),
            ">=": lambda a, b: to_number(a) >= to_number(b),
        }
        if token.text not in compare:
            return left
        self.take()
        return compare[token.text](left, self.parse_unary())

    def parse_unary(self) -> Value:
        """Evaluate an optional `!` prefix.

        Returns:
            The negated or plain operand.
        """
        if self._at_op("!"):
            self.take()
            return not truthy(self.parse_unary())
        return self.parse_primary()

    def parse_primary(self) -> Value:
        """Evaluate a literal, path, function call, or group.

        Returns:
            The operand value.

        Raises:
            ExpressionError: On an unknown function.
        """
        token = self.take()
        if token.text == "(":
            value = self.parse_or()
            self.take(")")
        elif token.kind == "str":
            value = token.text[1:-1].replace("''", "'")
        elif token.kind == "num":
            value = float(token.text)
        elif token.kind != "ident":
            raise ExpressionError(f"unexpected token {token}")
        elif token.text in _LITERALS:
            value = _LITERALS[token.text]
        elif self._at_op("("):
            self.take("(")
            self.take(")")
            value = self._status(token.text)
        else:
            value = self.context.get(token.text)
        return value

    def _status(self, name: str) -> bool:
        if name not in _STATUS_FUNCTIONS:
            raise ExpressionError(f"unsupported function {name}()")
        status = str(self.context.get("job.status") or "success")
        return name in ("always", status)

    def _at_op(self, text: str) -> bool:
        token = self.peek()
        return token is not None and token.kind == "op" and token.text == text


def evaluate(
    expression: str,
    context: dict[str, Value],
    *,
    is_condition: bool = True,
) -> bool:
    """Evaluate an expression the way the runner does.

    Args:
        expression: Expression, with or without the `${{ }}` wrapper.
        context: Flat mapping of dotted paths to values.
        is_condition: Whether this is an `if:` condition, which gets the
            implicit `success() &&` when it calls no status function.

    Returns:
        Whether the condition is truthy.
    """
    source = expression.strip()
    if source.startswith("${{") and source.endswith("}}"):
        source = source[3:-2]
    tokens = tokenize(source)
    idents = {token.text for token in tokens if token.kind == "ident"}
    has_status = not idents.isdisjoint(_STATUS_FUNCTIONS)
    if is_condition and not has_status:
        tokens = [
            Token("ident", "success"),
            Token("op", "("),
            Token("op", ")"),
            Token("op", "&&"),
            Token("op", "("),
            *tokens,
            Token("op", ")"),
        ]
    return truthy(Parser(tokens=tokens, context=context).parse())


def parse_bindings(args: list[str]) -> dict[str, Value]:
    """Build a context from `KEY=STRING` and `KEY:=JSON` arguments.

    Args:
        args: Binding arguments; later bindings override earlier ones.

    Returns:
        The flat context mapping.

    Raises:
        ExpressionError: On a malformed binding.
    """
    context: dict[str, Value] = {}
    for arg in args:
        eq = arg.find("=")
        if eq <= 0:
            raise ExpressionError(f"malformed binding {arg!r}")
        if arg[eq - 1] == ":":
            value = json.loads(arg[eq + 1 :])
            if isinstance(value, int) and not isinstance(value, bool):
                value = float(value)
            context[arg[: eq - 1]] = value
        else:
            context[arg[:eq]] = arg[eq + 1 :]
    return context


def main(argv: list[str]) -> int:
    """Run the CLI.

    Args:
        argv: Arguments after the program name.

    Returns:
        Process exit code.
    """
    is_condition = not (argv and argv[0] == "--value")
    if not is_condition:
        argv = argv[1:]
    if not argv:
        print(_USAGE, file=sys.stderr)
        return 2
    try:
        result = evaluate(
            argv[0],
            parse_bindings(argv[1:]),
            is_condition=is_condition,
        )
    except (ExpressionError, json.JSONDecodeError) as error:
        print(f"gha_expr: {error}", file=sys.stderr)
        return 2
    print("true" if result else "false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
