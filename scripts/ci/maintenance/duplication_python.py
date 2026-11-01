# SPDX-License-Identifier: MIT
"""Bounded Python token guards; inspected source is never executed."""

from __future__ import annotations

import ast
import re
import tokenize

RUNNER_FILE_NAME = re.compile(r"\bGITHUB_(?:PATH|ENV)\b")


def runner_file_reference(tokens: list[tokenize.TokenInfo]) -> bool:
    """Keep runner-file references opaque, including decoded str/bytes literals."""
    for item in tokens:
        if item.type not in {tokenize.NAME, tokenize.STRING}:
            continue
        text = item.string
        if item.type == tokenize.STRING:
            text = str(ast.literal_eval(text))
        if RUNNER_FILE_NAME.search(text):
            return True
    return False


def python_path_parameters(
    source: str,
    tokens: list[tokenize.TokenInfo],
) -> set[tuple[int, int]]:
    """Recognize only direct literal Path arguments with one unaliased import.

    Any other occurrence of the constructor name (including a binding, alias
    or attribute) disables this bounded rule. Unknown string uses remain logic.
    """
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return set()
    imports = [
        node
        for node in tree.body
        if isinstance(node, ast.ImportFrom)
        and node.module == "pathlib"
        and node.level == 0
        and len(node.names) == 1
        and node.names[0].name == "Path"
        and node.names[0].asname is None
    ]
    if len(imports) != 1:
        return set()
    calls = [
        index
        for index, item in enumerate(tokens[:-3])
        if item.type == tokenize.NAME
        and item.string == "Path"
        and item.start[0] > imports[0].lineno
        and (index == 0 or tokens[index - 1].string != ".")
        and tokens[index + 1].string == "("
        and tokens[index + 2].type == tokenize.STRING
        and tokens[index + 3].string == ")"
    ]
    # The same token spelling can denote a class pattern instead of a call.
    constructors = sum(
        isinstance(node.func, ast.Name) and node.func.id == "Path"
        for node in ast.walk(tree)
        if isinstance(node, ast.Call)
    )
    if len(calls) != constructors:
        return set()
    if sum(item.type == tokenize.NAME and item.string == "Path" for item in tokens) != (
        len(calls) + 1
    ):
        return set()
    return {
        tokens[index + 2].start
        for index in calls
        if isinstance(value := ast.literal_eval(tokens[index + 2].string), str)
        and re.fullmatch(r"(?:/|\.{1,2}/)?[\w.-]+(?:/[\w.-]+)+", value)
    }
