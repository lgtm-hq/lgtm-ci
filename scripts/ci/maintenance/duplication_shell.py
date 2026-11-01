# SPDX-License-Identifier: MIT
"""Bounded shell command positions and escape handling, without execution."""

from __future__ import annotations

import re

# This is a bounded set of recognizable command positions, not a shell parser.
# The same positions/wrappers must guard directory changes and executable paths.
SHELL_POSITION = r"(?:^|[;&|\n(){}])\s*(?:(?:if|then|else|elif|do|while|until|!)\s+)*"
COMMAND_START = (
    SHELL_POSITION + r"(?:(?:sudo|nohup|command|builtin|env|exec|time)\s+"
    r"|[A-Za-z_]\w*=[^\s;&|]*\s+)*"
)
RUNNER = r"(?:(?P<runner>uv|bun)\s+run\s+|timeout\s+\d+(?:\.\d+)?[smhd]?\s+)?"
# Escaped whitespace/separators defeat the bounded assignment prefix above.
# Fail closed before any command guard or dependency lookup uses that prefix;
# ordinary escapes such as X=a\b do not change its recognized boundaries.
# Look ahead in both guards: rejecting an escaped boundary must not consume a
# later real command position, e.g. the newline following echo \;.
ESCAPED_ASSIGNMENT = re.compile(
    r"(?=" + COMMAND_START + r"[A-Za-z_]\w*=[^\s;&|]*?(?P<escape>\\)[\s;&|])",
)
# Escapes can spell builtins, interpreters or wrappers without matching their
# literal names. Do not decode command words or mistake assignments for them.
# A standalone escaped separator cannot spell one of those names; in particular
# find's {} \; arguments must not look like an escaped command after }.
ESCAPED_COMMAND = re.compile(
    r"(?="
    + COMMAND_START
    + RUNNER
    + r"(?![A-Za-z_]\w*=)(?!\\[;&|](?=\s|$))"
    + r"""[^\s;&|(){}<>'"\\]*\\)""",
)


def shell_escaped(source: str, start: int) -> bool:
    """Count escapes against original offsets, including lexeme boundaries."""
    offset = start
    while offset > 0 and source[offset - 1] == "\\":
        offset -= 1
    return (start - offset) % 2 != 0


def unescaped_matches(
    source: str,
    matches: list[re.Match[str]],
    escape: str | None = None,
) -> bool:
    """Check real command boundaries and, optionally, an assignment's escape."""
    return any(
        not shell_escaped(source, match.start())
        and (escape is None or not shell_escaped(source, match.start(escape)))
        for match in matches
    )


def shell_words(source: str, lexer: re.Pattern[str]) -> tuple[str, ...]:
    """Rejoin adjacent lexemes when tokenizing an already normalized script."""
    # The guard lexer isolates parameters so their whitespace-# stays literal.
    # Those lexical boundaries are not shell word boundaries: ${dir}/* and
    # ${a}${b} each remain one word. Only intervening spacing separates words.
    words: list[str] = []
    previous_end = -1
    for match in lexer.finditer(source):
        if match.group().isspace():
            continue
        if match.start() == previous_end:
            words[-1] += match.group()
        else:
            words.append(match.group())
        previous_end = match.end()
    return tuple(words)
