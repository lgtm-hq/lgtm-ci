# SPDX-License-Identifier: MIT
"""The argument rules of ``echo`` and ``printf`` in a trivial step (#1624).

``inline_shell_trivial`` walks a step; for each ``echo`` or ``printf`` it
asks :func:`option_problem` about the command's first argument. Neither may
take an option:

- ``printf``'s first argument is a literal format that does not start with
  ``-`` (``-v NAME`` assigns a variable), and every ``%`` and ``\\`` in it
  starts one of ``PRINTF_CONVERSIONS`` or ``PRINTF_ESCAPES`` (``%n`` assigns
  a variable, ``%b`` and ``%q`` read escapes from the argument).
- ``echo``'s first argument, if any, is a literal that does not start with
  ``-``, or a word that opens with literal text other than ``-`` before any
  variable: ``echo "$X"`` with ``X=-e`` turns on escapes, so a word that
  opens with a variable is refused (``printf '%s\\n' "$X"`` prints it).
"""

from __future__ import annotations

from inline_shell_lexer import Word
from inline_shell_rules import PRINTF_CONVERSIONS, PRINTF_ESCAPES

ECHO_OPTION = (
    "echo takes no option (-e, -n, -E), and its first argument must start "
    "with literal text, not a variable that can expand to one; "
    "use printf '%s\\n'"
)
PRINTF_OPTION = "printf takes no option; its first argument is a literal format"


def option_problem(command: str, first: Word | None) -> str:
    """Return why a command's first argument breaks its rule, else "".

    Args:
        command: ``echo`` or ``printf``; any other command passes.
        first: The parsed first argument, past any redirections, else None.

    Returns:
        The message.
    """
    if first is None:
        return ""
    if command == "printf":
        return _printf_problem(first)
    if command != "echo":
        return ""
    literal = first.literal()
    if literal is not None:
        return ECHO_OPTION if literal.startswith("-") else ""
    kind, text = first.parts[0]
    if kind != "lit" or not text or text.startswith("-"):
        return ECHO_OPTION
    return ""


def _printf_problem(first: Word) -> str:
    """Return why printf's format is not plain text, else ""."""
    literal = first.literal()
    if literal is None or literal.startswith("-"):
        return PRINTF_OPTION
    index = 0
    while index < len(literal):
        if literal[index] not in "%\\":
            index += 1
            continue
        pair = literal[index : index + 2]
        allowed = PRINTF_CONVERSIONS if pair[0] == "%" else PRINTF_ESCAPES
        if pair not in allowed:
            return (
                f"printf format holds `{pair}`; only %s, %% and the escapes "
                "\\n, \\t, \\\\ are allowed"
            )
        index += 2
    return ""
