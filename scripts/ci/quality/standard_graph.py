# SPDX-License-Identifier: MIT
"""Resolve the classes of parsed test files by qualified identity (#1625).

Helper module of ``standard_scan.py``. Kept to the standard library and to
Python 3.9 syntax, like the check it serves.

Every class and every binding is a symbol ``(module, name)``. ``module`` is a
scanned file's repository-relative path, or an outside module's dotted name
(``unittest.case``); ``name`` is a dotted path inside it (``Outer.Inner``,
``build.Plain`` for a class defined in a function), empty for the module
itself. Imports and simple assignments (``Base = unittest.TestCase``,
``U = unittest``) are aliases from the bound symbol to the symbol named.
Following aliases, attribute by attribute, ends at a class, an outside name
such as ``unittest.case.TestCase``, or nothing (a parameter, a call result).

Names resolve with Python's scoping: a name bound anywhere in a function or
class body (parameters, imports, assignments, loop targets) is that scope's
own; a class body's names are not visible in its methods or nested classes;
a name bound nowhere is the module's own, so an unrelated local
``class TestCase`` is not reported.
"""

from __future__ import annotations

import ast
import posixpath
from collections.abc import Iterable, Iterator, Sequence
from dataclasses import dataclass, field

Symbol = tuple[str, str]
FUNCTIONS = (ast.FunctionDef, ast.AsyncFunctionDef)
SCOPES = (*FUNCTIONS, ast.ClassDef)
EXPRESSION_SCOPES = (
    ast.Lambda,
    ast.ListComp,
    ast.SetComp,
    ast.DictComp,
    ast.GeneratorExp,
)
UNITTEST_MODULES = ("unittest", "unittest.case", "unittest.async_case")
UNITTEST_NAMES = ("TestCase", "IsolatedAsyncioTestCase")
UNITTEST = frozenset(f"{m}.{n}" for m in UNITTEST_MODULES for n in UNITTEST_NAMES)


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
        package = _dotted(posixpath.dirname(importer) + "/") if importer else ""
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


def flat(body: Sequence[ast.stmt]) -> Iterator[ast.stmt]:
    """Yield the statements of a scope, through control flow, not nested scopes."""
    for node in body:
        yield node
        if not isinstance(node, SCOPES):
            for block in blocks(node):
                yield from flat(block)


def _parameters(args: ast.arguments) -> set[str]:
    """Return every parameter name of a function."""
    every = [*args.posonlyargs, *args.args, *args.kwonlyargs]
    every += [arg for arg in (args.vararg, args.kwarg) if arg is not None]
    return {arg.arg for arg in every}


def _stored(body: Sequence[ast.stmt]) -> set[str]:
    """Return every name a scope's body binds, nested scopes excluded."""
    names: set[str] = set()
    todo: list[ast.AST] = list(body)
    while todo:
        node = todo.pop()
        if isinstance(node, SCOPES):
            names.add(node.name)
            continue
        if isinstance(node, EXPRESSION_SCOPES):
            continue
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store):
            names.add(node.id)
        elif isinstance(node, ast.ExceptHandler) and node.name:
            names.add(node.name)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            bound = [a for a in node.names if a.name != "*"]
            names.update((a.asname or a.name.split(".")[0]) for a in bound)
        todo.extend(ast.iter_child_nodes(node))
    return names


@dataclass
class _Scope:
    """Names bound in one scope, with their qualified prefix."""

    prefix: str
    names: set[str] = field(default_factory=set)
    is_class: bool = False


class Graph:
    """Classes and bindings of every scanned file, linked by identity.

    Args:
        trees: Every scanned file's parsed module, by repository-relative path.
    """

    def __init__(self, trees: dict[str, ast.Module]) -> None:
        self.modules = Modules(trees)
        self.aliases: dict[Symbol, set[Symbol]] = {}
        self.bases: dict[Symbol, list[Symbol]] = {}
        self.classes: dict[ast.ClassDef, Symbol] = {}
        self.nodes: dict[Symbol, list[ast.ClassDef]] = {}
        self._derived: dict[Symbol, bool] = {}
        for key, tree in trees.items():
            self._walk(key, tree.body, [], _Scope("", _stored(tree.body)))

    def _module(self, dotted: str, importer: str) -> Symbol:
        """Return the symbol of a module: a scanned file or an outside name."""
        return (self.modules.find(dotted, importer), "")

    def attributes(
        self,
        ref: Symbol,
        parts: Sequence[str],
        importer: str = "",
    ) -> Symbol:
        """Return the symbol ``ref.part.part...`` names, submodules included."""
        for attr in parts:
            module, name = ref
            if name:
                ref = (module, f"{name}.{attr}")
                continue
            scanned = module.endswith(".py")
            dotted = _dotted(module) if scanned else module
            sub = self.modules.find(f"{dotted}.{attr}", importer)
            ref = (sub, "") if sub.endswith(".py") or not scanned else (module, attr)
        return ref

    def resolve(self, key: str, stack: list[_Scope], node: ast.expr) -> Symbol | None:
        """Return the symbol an expression names, if it is a dotted name."""
        parts: list[str] = []
        while isinstance(node, ast.Attribute):
            parts.insert(0, node.attr)
            node = node.value
        if not isinstance(node, ast.Name):
            return None
        head = (key, node.id)
        for depth, scope in enumerate(reversed(stack)):
            if scope.is_class and depth:
                continue
            if node.id in scope.names:
                head = (key, scope.prefix + node.id)
                break
        return (head[0], ".".join([head[1], *parts]))

    def _alias(self, source: Symbol, target: Symbol | None) -> None:
        if target is not None:
            self.aliases.setdefault(source, set()).add(target)

    def _bind(self, key: str, stack: list[_Scope], node: ast.stmt) -> None:
        """Record the aliases an import or assignment binds in the current scope."""
        scope = stack[-1]
        if isinstance(node, ast.Import):
            for alias in node.names:
                local = alias.asname or alias.name.split(".")[0]
                module = self._module(alias.name if alias.asname else local, key)
                self._alias((key, scope.prefix + local), module)
        elif isinstance(node, ast.ImportFrom):
            base = self._module(self.modules.absolute(node, key), key)
            for alias in node.names:
                star = alias.name == "*"
                if star and base[0] not in UNITTEST_MODULES:
                    continue
                for name in UNITTEST_NAMES if star else (alias.name,):
                    local = alias.asname or name
                    scope.names.add(local)
                    target = self.attributes(base, [name], key)
                    self._alias((key, scope.prefix + local), target)
        elif isinstance(node, (ast.Assign, ast.AnnAssign)) and node.value is not None:
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for bound in targets:
                if isinstance(bound, ast.Name):
                    value = self.resolve(key, stack, node.value)
                    self._alias((key, scope.prefix + bound.id), value)

    def _walk(
        self,
        key: str,
        body: Sequence[ast.stmt],
        stack: list[_Scope],
        scope: _Scope,
    ) -> None:
        """Link the classes and bindings of one scope, then of its nested scopes."""
        stack = [*stack, scope]
        statements = list(flat(body))
        for node in statements:
            self._bind(key, stack, node)
        for node in statements:
            if isinstance(node, ast.ClassDef):
                symbol = (key, scope.prefix + node.name)
                self.classes[node] = symbol
                self.nodes.setdefault(symbol, []).append(node)
                found = (self.resolve(key, stack, b) for b in node.bases)
                self.bases.setdefault(symbol, []).extend(b for b in found if b)
                inner = _Scope(f"{symbol[1]}.", _stored(node.body), is_class=True)
                self._walk(key, node.body, stack, inner)
            elif isinstance(node, FUNCTIONS):
                names = _stored(node.body) | _parameters(node.args)
                inner = _Scope(f"{scope.prefix}{node.name}.", names)
                self._walk(key, node.body, stack, inner)

    def terminals(
        self,
        ref: Symbol,
        seen: set[Symbol] | None = None,
    ) -> Iterator[Symbol]:
        """Yield the classes and outside names a symbol reaches through aliases."""
        seen = set() if seen is None else seen
        if ref in seen:
            return
        seen.add(ref)
        module, name = ref
        if not module.endswith(".py") or not name or ref in self.bases:
            yield ref
            return
        parts = name.split(".")
        for size in range(len(parts), 0, -1):
            prefix = (module, ".".join(parts[:size]))
            if prefix in self.aliases:
                for target in self.aliases[prefix]:
                    attribute = self.attributes(target, parts[size:])
                    yield from self.terminals(attribute, seen)
                return
            if prefix in self.bases:
                return

    def base_classes(self, symbol: Symbol) -> Iterator[Symbol]:
        """Yield the scanned classes a class's bases reach, in base order."""
        for base in self.bases.get(symbol, ()):
            yield from (t for t in self.terminals(base) if t in self.bases)

    def ancestors(self, symbol: Symbol) -> list[Symbol]:
        """Return a class's scanned ancestors, depth first, each once."""
        found: list[Symbol] = []
        todo = [symbol]
        while todo:
            for parent in self.base_classes(todo.pop(0)):
                if parent != symbol and parent not in found:
                    found.append(parent)
                    todo.append(parent)
        return found

    def _derives(self, symbol: Symbol, active: set[Symbol]) -> bool:
        """Return whether a class reaches a unittest case class."""
        if symbol in self._derived:
            return self._derived[symbol]
        if symbol in active:
            return False
        active.add(symbol)
        result = False
        for base in self.bases.get(symbol, ()):
            for end in self.terminals(base):
                outside = not end[0].endswith(".py") and end[0] in UNITTEST
                if outside or (end in self.bases and self._derives(end, active)):
                    result = True
        active.discard(symbol)
        self._derived[symbol] = result
        return result

    def is_unittest(self, node: ast.ClassDef) -> bool:
        """Return whether a class derives from a unittest case class."""
        symbol = self.classes.get(node)
        return symbol is not None and self._derives(symbol, set())
