# SPDX-License-Identifier: MIT
"""Bounded Python token guards; inspected source is never executed."""

from __future__ import annotations

import ast
import io
import re
import sys
import tokenize
import warnings

RUNNER_FILE_NAME = re.compile(r"\bGITHUB_(?:PATH|ENV)\b")
INTERPOLATED_STRING = re.compile(r"(?i)(?:f|fr|rf|t|tr|rt)['\"]")


def python_tree(source: str) -> ast.Module:
    """Parse untrusted code without compiler diagnostics exposing its contents."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        return ast.parse(source)


def python_dependency_source(source: str) -> str:
    """Remove comments while retaining runtime-readable strings.

    Invalid or incomplete source stays intact for conservative inventory lookup;
    the normalizer independently keeps its existing invalid/opaque policy.
    Docstrings remain hints: decorators and external consumers can read module,
    function and class documentation without reflection names in this source.
    """
    # AST and tokenizer must agree on universal newlines. Other Unicode/control
    # separators are ordinary characters, including inside string literals.
    source = source.replace("\r\n", "\n").replace("\r", "\n")
    try:
        python_tree(source)
        tokens = list(tokenize.generate_tokens(io.StringIO(source).readline))
    except (SyntaxError, tokenize.TokenError):
        return source
    cleaned = []
    for item in tokens:
        if item.type == tokenize.COMMENT:
            item = item._replace(string=re.sub(r"[^\n]", " ", item.string))
        cleaned.append(item)
    return tokenize.untokenize(cleaned)


def interpolated_string_reference(tokens: list[tokenize.TokenInfo]) -> bool:
    """Reject f/template strings before either literal-only helper is reached."""
    return any(
        tokenize.tok_name[item.type] in {"FSTRING_START", "TSTRING_START"}
        or (item.type == tokenize.STRING and INTERPOLATED_STRING.match(item.string))
        for item in tokens
    )


def uninspected_python_imports(source: str, files: dict[str, str]) -> bool:
    """Only unshadowed stdlib imports have known external implementations.

    Local and third-party modules are not expanded. Even if their source
    is in the inventory, tokenizing the entrypoint alone cannot establish
    their behavior. Relative imports always depend on repository code.
    """
    try:
        tree = python_tree(source)
    except SyntaxError:
        # Tokenizable fragments may lack a complete syntax tree. Their
        # import behavior is unknown, too; keep the existing token shape.
        return True
    modules: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            modules.update(alias.name.split(".", 1)[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                return True
            modules.add((node.module or "").split(".", 1)[0])
    # Any inventoried Python module/package with this name might shadow
    # stdlib resolution; do not infer sys.path or package execution context.
    local_names = {
        part
        for path in files
        if path.endswith(".py")
        for part in path.removesuffix(".py").split("/")
    }
    return bool(modules - sys.stdlib_module_names or modules & local_names)


def runner_file_reference(tokens: list[tokenize.TokenInfo]) -> bool:
    """Inspect names and bounded adjacent/added str/bytes literals, never data flow.

    The caller rejects interpolated strings before this helper. Nonsemantic
    continuation tokens and literal grouping do not interrupt concatenation;
    names, commas, statement boundaries and other operators still do.
    """
    literals = ""
    for item in tokens:
        if item.type == tokenize.STRING:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                value = ast.literal_eval(item.string)
            # latin-1 preserves each byte; runner filenames are ASCII. Joining
            # literal fragments also covers Python's implicit concatenation.
            literals += value.decode("latin-1") if isinstance(value, bytes) else value
            if RUNNER_FILE_NAME.search(literals):
                return True
        elif item.type in {tokenize.NL, tokenize.COMMENT} or (
            item.type == tokenize.OP and item.string in {"+", "(", ")"}
        ):
            continue
        else:
            literals = ""
        if item.type == tokenize.NAME and RUNNER_FILE_NAME.search(item.string):
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
        tree = python_tree(source)
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
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        return {
            tokens[index + 2].start
            for index in calls
            if isinstance(value := ast.literal_eval(tokens[index + 2].string), str)
            and re.fullmatch(r"(?:/|\.{1,2}/)?[\w.-]+(?:/[\w.-]+)+", value)
        }
