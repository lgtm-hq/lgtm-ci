# SPDX-License-Identifier: MIT
"""Find test-standard offences in parsed test files (#1625).

Helper module of ``validate_test_standard.py``, which documents the rules.
Kept to the standard library and to Python 3.9 syntax: CI runs the check with
the runner's ``python3``, which on a self-hosted runner may predate 3.11.

Unittest classes are found by qualified identity, not by spelling: see
``standard_graph.py``. Collection follows pytest's defaults: module-level
``test*`` functions, and the ``test*`` methods of a test class, its own and
those it inherits from scanned bases. A class is a test class when it derives
from a unittest case class, or its name starts with ``Test`` (or it sets
``__test__ = True``) and neither it nor a scanned base defines ``__init__``;
``__test__ = False`` turns collection off. An inherited method is reported
once, where it is defined.
"""

from __future__ import annotations

import ast
from collections.abc import Iterator, Sequence

from standard_graph import FUNCTIONS, Graph, flat
from standard_offence import Offence

__all__ = ["RULES", "Graph", "Offence", "collected", "scan"]

BARE_ASSERT = "bare-assert"
UNITTEST_CLASS = "unittest-class"
MISSING_DOCSTRING = "missing-docstring"
RULES = (BARE_ASSERT, UNITTEST_CLASS, MISSING_DOCSTRING)


def _lineage(graph: Graph, node: ast.ClassDef) -> list[ast.ClassDef]:
    """Return a class and the definitions of its scanned ancestors, in order."""
    symbol = graph.classes[node]
    return [node, *(n for a in graph.ancestors(symbol) for n in graph.nodes[a])]


def _test_flag(lineage: Sequence[ast.ClassDef]) -> bool | None:
    """Return the first ``__test__ = True/False`` of a class or its bases."""
    for cls in lineage:
        for node in flat(cls.body):
            value = getattr(node, "value", None)
            if not isinstance(node, ast.Assign) or not isinstance(value, ast.Constant):
                continue
            names = [t.id for t in node.targets if isinstance(t, ast.Name)]
            if "__test__" in names and isinstance(value.value, bool):
                return value.value
    return None


def _is_test_class(graph: Graph, node: ast.ClassDef) -> bool:
    """Return whether pytest collects a module-level or nested class."""
    lineage = _lineage(graph, node)
    flag = _test_flag(lineage)
    if flag is False:
        return False
    if graph.is_unittest(node):
        return True
    methods = (n for cls in lineage for n in flat(cls.body) if isinstance(n, FUNCTIONS))
    has_init = any(method.name == "__init__" for method in methods)
    return (node.name.startswith("Test") or flag is True) and not has_init


def _methods(lineage: Sequence[ast.ClassDef]) -> Iterator[ast.stmt]:
    """Yield the ``test*`` methods a class has, own first, each name once."""
    seen: set[str] = set()
    for cls in lineage:
        for node in flat(cls.body):
            if not isinstance(node, FUNCTIONS) or not node.name.startswith("test"):
                continue
            if node.name not in seen:
                seen.add(node.name)
                yield node


def _tests(graph: Graph, body: Sequence[ast.stmt], module: bool) -> Iterator[ast.stmt]:
    """Yield the test functions pytest collects from a module or class body.

    Control flow is followed and test classes are entered, nested ones too;
    function bodies are not, so inner helpers named ``test*`` are exempt.
    """
    for node in flat(body):
        if module and isinstance(node, FUNCTIONS) and node.name.startswith("test"):
            yield node
        elif isinstance(node, ast.ClassDef) and _is_test_class(graph, node):
            yield from _methods(_lineage(graph, node))
            yield from _tests(graph, node.body, module=False)


def collected(graph: Graph, trees: dict[str, ast.Module]) -> set[ast.stmt]:
    """Return every test function pytest collects across the scanned files.

    Args:
        graph: The classes and bindings of every scanned file.
        trees: Every scanned file's parsed module.

    Returns:
        The collected function definitions, wherever they are defined.
    """
    found: set[ast.stmt] = set()
    for tree in trees.values():
        found.update(_tests(graph, tree.body, module=True))
    return found


def scan(
    relative: str,
    tree: ast.Module,
    graph: Graph,
    tests: set[ast.stmt],
) -> list[Offence]:
    """Return every offence in one parsed file, in line order.

    Args:
        relative: The file's repository-relative path, for the report.
        tree: The parsed file.
        graph: The classes and bindings of every scanned file.
        tests: The collected test functions (see :func:`collected`).

    Returns:
        The offences.
    """
    found: list[Offence] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Assert):
            what = "bare assert; use assertpy (assert_that)"
            found.append(Offence(relative, node.lineno, BARE_ASSERT, what))
        elif isinstance(node, ast.ClassDef) and graph.is_unittest(node):
            what = f"class {node.name} is a unittest.TestCase; use pytest functions"
            found.append(Offence(relative, node.lineno, UNITTEST_CLASS, what))
        elif isinstance(node, FUNCTIONS) and node in tests:
            documented = (ast.get_docstring(node) or "").strip()
            what = f"{node.name} has no docstring saying what it proves"
            if not documented:
                found.append(Offence(relative, node.lineno, MISSING_DOCSTRING, what))
    return sorted(found, key=lambda offence: (offence.line, offence.rule))
