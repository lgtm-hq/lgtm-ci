# SPDX-License-Identifier: MIT
"""Find test-standard offences in parsed test files (#1625).

Helper module of ``validate_test_standard.py``, which documents the rules.
Kept to the standard library and to Python 3.9 syntax: CI runs the check with
the runner's ``python3``, which on a self-hosted runner may predate 3.11.

Unittest classes are found by qualified identity, not by spelling. Every
class and every module-level binding is a symbol ``(module, name)``: a scanned
file's repository-relative path, or an outside module's dotted name such as
``unittest``. Each class points at the symbols of its bases, each import and
each simple assignment (``Base = unittest.TestCase``) at the symbol it names,
and a symbol derives from unittest when it reaches ``unittest.TestCase`` or
``unittest.IsolatedAsyncioTestCase`` through those links. A name with no
import binding is the module's own, so an unrelated local ``class TestCase``
or a ``class Base`` that shares a name with a unittest base elsewhere is not
reported.
"""

from __future__ import annotations

import ast
import posixpath
from collections.abc import Iterable, Iterator, Sequence
from dataclasses import dataclass, field

BARE_ASSERT = "bare-assert"
UNITTEST_CLASS = "unittest-class"
MISSING_DOCSTRING = "missing-docstring"
RULES = (BARE_ASSERT, UNITTEST_CLASS, MISSING_DOCSTRING)

Symbol = tuple[str, str]
FUNCTIONS = (ast.FunctionDef, ast.AsyncFunctionDef)
UNITTEST_MODULES = ("unittest", "unittest.case", "unittest.async_case")
UNITTEST_NAMES = ("TestCase", "IsolatedAsyncioTestCase")
UNITTEST = frozenset((m, n) for m in UNITTEST_MODULES for n in UNITTEST_NAMES)


@dataclass(frozen=True)
class Offence:
    """One place in a test file that breaks a rule."""

    file: str
    line: int
    rule: str
    what: str

    def render(self) -> str:
        """Return the offence as ``file:line: [rule] what``."""
        return f"{self.file}:{self.line}: [{self.rule}] {self.what}"


def _dotted(relative: str) -> str:
    """Return the module name of a repository-relative path."""
    parts = relative[: -len(".py")].split("/") if relative.endswith(".py") else []
    if not parts:
        parts = [part for part in relative.split("/") if part]
    if parts and parts[-1] == "__init__":
        parts.pop()
    return ".".join(parts)


class Modules:
    """Map imported module names to the scanned files they load.

    Args:
        files: The scanned files' repository-relative paths.
    """

    def __init__(self, files: Iterable[str]) -> None:
        self.files = {_dotted(name): name for name in files}

    def find(self, module: str, importer: str) -> str:
        """Return the scanned file ``module`` names, or ``module`` itself.

        A full path from the repository root wins, then a module next to the
        importer (helpers run as scripts import their siblings), then the one
        scanned file whose name ends with ``module`` (``pythonpath`` roots).
        """
        if module in self.files:
            return self.files[module]
        package = _dotted(posixpath.dirname(importer) + "/")
        sibling = f"{package}.{module}" if package else module
        if sibling in self.files:
            return self.files[sibling]
        matches = [f for name, f in self.files.items() if name.endswith(f".{module}")]
        return matches[0] if len(matches) == 1 else module

    def absolute(self, node: ast.ImportFrom, importer: str) -> str:
        """Return the dotted module an ``import from`` reads, relative or not."""
        if not node.level:
            return node.module or ""
        package = _dotted(posixpath.dirname(importer) + "/").split(".")
        package = package[: len(package) - node.level + 1]
        return ".".join([*package, *([node.module] if node.module else [])])


def blocks(node: ast.stmt) -> Iterator[list[ast.stmt]]:
    """Yield the statement lists of a compound statement that is not a scope."""
    for name in ("body", "orelse", "finalbody"):
        block = getattr(node, name, None)
        if isinstance(block, list):
            yield block
    for part in [*getattr(node, "handlers", []), *getattr(node, "cases", [])]:
        yield part.body


def _flat(body: Sequence[ast.stmt]) -> Iterator[ast.stmt]:
    """Yield the statements of a scope, through control flow, not nested scopes."""
    for node in body:
        yield node
        if not isinstance(node, (*FUNCTIONS, ast.ClassDef)):
            for block in blocks(node):
                yield from _flat(block)


@dataclass
class _Scope:
    """Names bound directly in one scope, with their qualified prefix."""

    prefix: str
    names: set[str] = field(default_factory=set)
    modules: dict[str, str] = field(default_factory=dict)


class Graph:
    """Classes and bindings of every scanned file, linked by identity.

    Args:
        trees: Every scanned file's parsed module, by repository-relative path.
    """

    def __init__(self, trees: dict[str, ast.Module]) -> None:
        self.modules = Modules(trees)
        self.links: dict[Symbol, set[Symbol]] = {}
        self.classes: dict[ast.ClassDef, Symbol] = {}
        for key, tree in trees.items():
            self._walk(key, tree.body, [], "")
        self.unittest = self._derived()

    def _link(self, source: Symbol, targets: Iterable[Symbol | None]) -> None:
        self.links.setdefault(source, set()).update(t for t in targets if t)

    def resolve(self, key: str, stack: list[_Scope], node: ast.expr) -> Symbol | None:
        """Return the symbol an expression names, if it is a dotted name."""
        parts: list[str] = []
        while isinstance(node, ast.Attribute):
            parts.insert(0, node.attr)
            node = node.value
        if not isinstance(node, ast.Name):
            return None
        head = node.id
        for scope in reversed(stack):
            if head in scope.modules and parts:
                module = ".".join([scope.modules[head], *parts[:-1]])
                return (self.modules.find(module, key), parts[-1])
            if head in scope.names:
                return (key, ".".join([scope.prefix + head, *parts]))
        return (key, ".".join([head, *parts]))

    def _bind(self, key: str, stack: list[_Scope], node: ast.stmt) -> None:
        """Record the names an import or assignment binds in the current scope."""
        scope = stack[-1]
        if isinstance(node, ast.Import):
            for alias in node.names:
                local = alias.asname or alias.name.split(".")[0]
                scope.modules[local] = alias.name if alias.asname else local
        elif isinstance(node, ast.ImportFrom):
            module = self.modules.absolute(node, key)
            for alias in node.names:
                names = UNITTEST_NAMES if alias.name == "*" else (alias.name,)
                if alias.name == "*" and module not in UNITTEST_MODULES:
                    continue
                for name in names:
                    local = alias.asname or name
                    if self.modules.find(f"{module}.{name}", key).endswith(".py"):
                        scope.modules[local] = f"{module}.{name}"
                        continue
                    scope.names.add(local)
                    target = (self.modules.find(module, key), name)
                    self._link((key, scope.prefix + local), [target])
        elif isinstance(node, (ast.Assign, ast.AnnAssign)) and node.value is not None:
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for bound in targets:
                if isinstance(bound, ast.Name):
                    scope.names.add(bound.id)
                    value = self.resolve(key, stack, node.value)
                    self._link((key, scope.prefix + bound.id), [value])

    def _walk(
        self,
        key: str,
        body: Sequence[ast.stmt],
        stack: list[_Scope],
        prefix: str,
    ) -> None:
        """Link the classes and bindings of one scope, then of its nested scopes."""
        scope = _Scope(prefix)
        statements = list(_flat(body))
        scopes = (*FUNCTIONS, ast.ClassDef)
        scope.names.update(n.name for n in statements if isinstance(n, scopes))
        stack = [*stack, scope]
        for node in statements:
            self._bind(key, stack, node)
        for node in statements:
            if isinstance(node, ast.ClassDef):
                symbol = (key, prefix + node.name)
                self.classes[node] = symbol
                self._link(symbol, (self.resolve(key, stack, b) for b in node.bases))
                self._walk(key, node.body, stack, f"{symbol[1]}.")
            elif isinstance(node, FUNCTIONS):
                self._walk(key, node.body, stack, f"{prefix}{node.name}.")

    def _derived(self) -> set[Symbol]:
        """Return every symbol that reaches a unittest case class, to a fixed point."""
        found = set(UNITTEST)
        changed = True
        while changed:
            changed = False
            for symbol, targets in self.links.items():
                if symbol not in found and targets & found:
                    found.add(symbol)
                    changed = True
        return found

    def is_unittest(self, node: ast.ClassDef) -> bool:
        """Return whether a class derives from a unittest case class."""
        return self.classes.get(node) in self.unittest


def _collected(
    body: Sequence[ast.stmt], graph: Graph
) -> Iterator[ast.FunctionDef | ast.AsyncFunctionDef]:
    """Yield the ``test*`` functions pytest collects from a module body.

    Control flow at module and class level is followed and test classes are
    entered, nested ones too; function bodies are not, so inner helpers named
    ``test*`` are exempt. A class is a test class when it is a unittest case
    class, or its name starts with ``Test`` and it defines no ``__init__``.
    """
    for node in body:
        if isinstance(node, FUNCTIONS):
            if node.name.startswith("test"):
                yield node
        elif isinstance(node, ast.ClassDef):
            methods = [item.name for item in node.body if isinstance(item, FUNCTIONS)]
            has_init = "__init__" in methods
            named = node.name.startswith("Test") and not has_init
            if named or graph.is_unittest(node):
                yield from _collected(node.body, graph)
        else:
            for block in blocks(node):
                yield from _collected(block, graph)


def scan(relative: str, tree: ast.Module, graph: Graph) -> list[Offence]:
    """Return every offence in one parsed file, in line order.

    Args:
        relative: The file's repository-relative path, for the report.
        tree: The parsed file.
        graph: The classes and bindings of every scanned file.

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
    for function in _collected(tree.body, graph):
        if not (ast.get_docstring(function) or "").strip():
            what = f"{function.name} has no docstring saying what it proves"
            found.append(Offence(relative, function.lineno, MISSING_DOCSTRING, what))
    return sorted(found, key=lambda offence: (offence.line, offence.rule))
