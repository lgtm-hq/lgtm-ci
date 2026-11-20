# SPDX-License-Identifier: MIT
"""Python half of the analysis behind ``test_comment_renderer_guard.py`` (#1676).

Each function of a Python formatter is walked statement by statement, in
order, merging the safe values of ``if``/loop/``try``/``match`` paths (a
value is safe after them only when it is safe on every path), so a raw value
assigned after a safe one is caught. Every way of adding to the comment's
``sections`` list is checked, a list filled with a raw value is no longer
safe, and every write to stdout (``print`` with ``sep``/``end``, ``write``
on ``sys.stdout`` or an alias of it, ``os.write``) is checked like an
addition. A module-level function whose every return is safe may be
printed; a method of the same name never stands in for it, and a module
list that another function changes is never a safe constant. A statement
marked ``# comment-safe: <reason>`` (on its first line or the line above) is
a reviewer's word, as in the bash half (``comment_guard_support.py``).
"""

from __future__ import annotations

import ast
import re
from typing import TypeGuard

REVIEWED = re.compile(r"#\s*comment-safe:\s*\S")
REVIEWED_LINE = re.compile(r"\s*#\s*comment-safe:\s*\S.*")
_BLOCKS = (ast.Try, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)


#: The sanitiser's mode functions; its helpers (``cap``, ``strip_invisible``,
#: ``neutralise_marker``) are not modes and do not make a value safe.
MODE_FUNCTIONS = frozenset(
    {
        "text",
        "cell",
        "code",
        "cell_code",
        "fence",
        "markdown",
        "report",
        "url",
        "host",
        "link",
        "labelled_link",
        "html",
    },
)
#: Calls whose result the Python formatter may insert.
#: ``SANITISER`` stands for the ``comment_sanitize`` module itself: it is
#: removed where a parameter or a local or module binding shadows that name.
SANITISER = "<comment_sanitize>"
SAFE_CALLS = frozenset({"_count", SANITISER})
#: Marks, inside a safe set, that ``sections`` is a list this path created.
OWN_SECTIONS = "<own sections>"
#: Methods that put a value into the list, set or dict they are called on.
MUTATORS = frozenset({"append", "extend", "insert", "add", "update", "setdefault"})
#: Calls that change a module-level container in place (any argument).
CHANGERS = MUTATORS | {
    "clear",
    "pop",
    "popitem",
    "remove",
    "discard",
    "sort",
    "reverse",
}
#: Expressions that name the comment stream.
STDOUT = frozenset({"sys.stdout", "sys.stdout.buffer", "sys.__stdout__"})
#: File-writing methods whose first argument is written out.
FILE_WRITES = frozenset({"write_text", "write_bytes"})
#: Methods of a stream that emit their arguments.
STREAM_WRITES = frozenset({"write", "writelines"})


def _safe_call(node: ast.Call, safe: set[str], calls: frozenset[str]) -> bool:
    """Tell whether a call's result is safe.

    A sanitiser mode, a listed call, a module-level function whose every
    return is safe (``calls``), ``"<constant>".join(<safe>)``, or
    ``<safe>.encode(<constants>)``. A method never stands in for a module
    function of the same name: only a bare-name call matches ``calls``.
    """
    func = node.func
    owner = func.value if isinstance(func, ast.Attribute) else None
    if isinstance(owner, ast.Name) and owner.id == "comment_sanitize":
        return SANITISER in calls and getattr(func, "attr", "") in MODE_FUNCTIONS
    if isinstance(func, ast.Attribute) and func.attr == "encode":
        constant_args = all(isinstance(arg, ast.Constant) for arg in node.args)
        return constant_args and not node.keywords and is_safe(func.value, safe, calls)
    if isinstance(func, ast.Attribute) and isinstance(func.value, ast.Constant):
        joins = isinstance(func.value.value, str) and func.attr == "join"
        args_safe = all(is_safe(arg, safe, calls) for arg in node.args)
        return joins and not node.keywords and args_safe
    return isinstance(func, ast.Name) and func.id in calls


# A dispatch on node type: one return per kind of node reads best.
def is_safe(  # pylint: disable=too-many-return-statements
    node: ast.AST | None,
    safe: set[str],
    calls: frozenset[str] = SAFE_CALLS,
) -> bool:
    """Tell whether a Python expression is sanitiser output or built from safe parts."""
    if node is None or isinstance(node, ast.Constant):
        return True
    if isinstance(node, ast.Name):
        return node.id in safe
    if isinstance(node, ast.Call):
        return _safe_call(node, safe, calls)
    if isinstance(node, ast.JoinedStr):
        return all(is_safe(part, safe, calls) for part in node.values)
    if isinstance(node, ast.FormattedValue):
        return is_safe(node.value, safe, calls)
    if isinstance(node, ast.BinOp):
        return is_safe(node.left, safe, calls) and is_safe(node.right, safe, calls)
    if isinstance(node, ast.IfExp):
        return is_safe(node.body, safe, calls) and is_safe(node.orelse, safe, calls)
    if isinstance(node, ast.BoolOp):
        return all(is_safe(value, safe, calls) for value in node.values)
    if isinstance(node, (ast.List, ast.Tuple)):
        return all(is_safe(element, safe, calls) for element in node.elts)
    if isinstance(node, (ast.ListComp, ast.GeneratorExp, ast.SetComp)):
        # A comprehension variable is never safe, even if it shadows one that is.
        bound = {
            name.id
            for generator in node.generators
            for name in ast.walk(generator.target)
            if isinstance(name, ast.Name)
        }
        return is_safe(node.elt, safe - bound, calls)
    return False


def _sections_call(node: ast.AST) -> TypeGuard[ast.Call]:
    """Tell whether ``node`` is ``sections.append/extend/insert(...)``."""
    if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
        return False
    owner = node.func.value
    is_sections = isinstance(owner, ast.Name) and owner.id == "sections"
    return is_sections and node.func.attr in {"append", "extend", "insert"}


def _own_expressions(statement: ast.stmt) -> list[ast.AST]:
    """Return the parts of a statement that are not nested statements."""
    if isinstance(statement, (ast.If, ast.While)):
        return [statement.test]
    if isinstance(statement, (ast.For, ast.AsyncFor)):
        return [statement.iter]
    if isinstance(statement, (ast.With, ast.AsyncWith)):
        return [item.context_expr for item in statement.items]
    if isinstance(statement, ast.Match):
        return [statement.subject]
    if isinstance(statement, _BLOCKS):
        return []
    return [statement]


#: Stands for a value the analysis cannot follow (tuple unpacking).
_UNKNOWN = ast.Name(id="<unknown>")


def _python_binding(statement: ast.stmt) -> list[tuple[str, ast.AST | None]]:
    """Return each name a statement binds with the value it binds.

    Chained assignment (``a = b = value``) binds every name to the value;
    unpacking binds each name to a value the analysis cannot follow.
    """
    # A walrus anywhere in the statement binds its target too, inside an
    # assignment's value included (``x = (y := raw)`` binds y to raw).
    walrus: list[tuple[str, ast.AST | None]] = [
        (node.target.id, node.value)
        for part in _own_expressions(statement)
        for node in ast.walk(part)
        if isinstance(node, ast.NamedExpr)
    ]
    if isinstance(statement, ast.Assign):
        bound: list[tuple[str, ast.AST | None]] = []
        for target in statement.targets:
            if isinstance(target, ast.Name):
                bound.append((target.id, statement.value))
            elif isinstance(target, (ast.Tuple, ast.List)):
                names = [n.id for n in ast.walk(target) if isinstance(n, ast.Name)]
                bound.extend((name, _UNKNOWN) for name in names)
        return [*bound, *walrus]
    loops: list[ast.AST] = []
    if isinstance(statement, (ast.For, ast.AsyncFor)):
        loops.append(statement.target)
    if isinstance(statement, (ast.With, ast.AsyncWith)):
        targets = [item.optional_vars for item in statement.items]
        loops.extend(target for target in targets if target is not None)
    if walrus or loops:
        names = [n.id for t in loops for n in ast.walk(t) if isinstance(n, ast.Name)]
        return [*walrus, *((name, _UNKNOWN) for name in names)]
    if isinstance(statement, ast.AnnAssign) and isinstance(statement.target, ast.Name):
        return [(statement.target.id, statement.value)]
    if isinstance(statement, ast.AugAssign) and isinstance(statement.target, ast.Name):
        name = statement.target.id
        left = ast.Name(id=name)
        combined = ast.BinOp(left=left, op=statement.op, right=statement.value)
        return [(name, combined)]
    return []


def _changed_by_functions(tree: ast.Module) -> set[str]:
    """Module names a function changes in place or rebinds through ``global``.

    Such a name is never a safe constant: ``CACHE[0] = open(p).read()`` in
    one function would otherwise reach ``"\\n".join(CACHE)`` in another.
    """
    changed: set[str] = set()
    for func in (n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)):
        for node in ast.walk(func):
            if isinstance(node, ast.Global):
                changed.update(node.names)
            elif isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
                owner = node.func.value
                if isinstance(owner, ast.Name) and node.func.attr in CHANGERS:
                    changed.add(owner.id)
            elif isinstance(node, _ASSIGNING):
                changed.update(_subscripted(node))
    return changed


#: Statements that may assign into a subscript.
_ASSIGNING = (ast.Assign, ast.AugAssign, ast.AnnAssign, ast.Delete)


def _subscripted(node: ast.stmt) -> set[str]:
    """Names a statement assigns into or deletes from by subscript."""
    targets = getattr(node, "targets", None) or [getattr(node, "target", None)]
    return {
        target.value.id
        for target in targets
        if isinstance(target, ast.Subscript) and isinstance(target.value, ast.Name)
    }


def _module_constants(tree: ast.Module) -> set[str]:
    """Names the module binds, at top level, to constants only, never changed."""
    safe: set[str] = set()
    for statement in tree.body:
        for name, value in _python_binding(statement):
            if is_safe(value, safe):
                safe.add(name)
            else:
                safe.discard(name)
    return safe - _changed_by_functions(tree)


def _assigns_into_sections(statement: ast.stmt) -> bool:
    """Tell whether a statement assigns into ``sections[...]`` (never checked)."""
    if isinstance(statement, ast.Assign):
        targets = statement.targets
    elif isinstance(statement, (ast.AugAssign, ast.AnnAssign)):
        targets = [statement.target]
    else:
        return False
    return any(
        isinstance(target, ast.Subscript)
        and isinstance(target.value, ast.Name)
        and target.value.id == "sections"
        for target in targets
    )


def _adds_raw(statement: ast.stmt, safe: set[str], calls: frozenset[str]) -> bool:
    """Tell whether a statement adds an unsafe value to ``sections``."""
    for part in _own_expressions(statement):
        for node in ast.walk(part):
            if _sections_call(node):
                insert = getattr(node.func, "attr", "") == "insert"
                args = node.args[1:] if insert else node.args
                if not all(is_safe(arg, safe, calls) for arg in args):
                    return True
    return False


#: Modules a stream or ``print`` can be imported from.
_PRINT_MODULES = frozenset({"sys", "builtins"})


class _Streams:  # pylint: disable=too-few-public-methods
    """What a module can write the comment through, found once per module.

    ``stdout``: the text of every expression naming standard output (``sys``
    under any ``import sys as s`` name, ``from sys import stdout``, and any
    name bound to one of them, with ``.buffer``). ``stderr``: the same for
    standard error, the one stream ``print(file=...)`` may write raw text to.
    ``prints``: names bound to ``print``. ``handles``: names bound to an
    ``open(...)`` file, by assignment or ``with ... as``.
    """

    def __init__(self, tree: ast.Module) -> None:
        modules = {"sys"}
        self.prints = {"print"}
        self.handles: set[str] = set()
        names: dict[str, str] = {}
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                sys_names = (a.asname or a.name for a in node.names if a.name == "sys")
                modules.update(sys_names)
            elif isinstance(node, ast.ImportFrom) and node.module in _PRINT_MODULES:
                for alias in node.names:
                    if alias.name in {"stdout", "stderr"}:
                        names[alias.asname or alias.name] = f"sys.{alias.name}"
                    elif alias.name == "print":
                        self.prints.add(alias.asname or alias.name)
        self.stdout = {f"{m}.{s}" for m in modules for s in ("stdout", "__stdout__")}
        self.stderr = {f"{m}.{s}" for m in modules for s in ("stderr", "__stderr__")}
        self.stdout |= {n for n, kind in names.items() if kind == "sys.stdout"}
        self.stderr |= {n for n, kind in names.items() if kind == "sys.stderr"}
        for target, value in _bindings(tree):
            if _opens(value):
                self.handles.add(target)
            elif isinstance(value, ast.Name) and value.id in self.prints:
                self.prints.add(target)
            elif self.is_stdout(value):
                self.stdout.add(target)
        self.stdout |= {f"{name}.buffer" for name in self.stdout}
        self.stderr |= {f"{name}.buffer" for name in self.stderr}

    def is_stdout(self, node: ast.AST | None) -> bool:
        """Tell whether an expression names standard output."""
        return node is not None and ast.unparse(node) in self.stdout

    def is_file(self, node: ast.AST | None) -> bool:
        """Tell whether an expression is a file this module opened."""
        return node is not None and (_opens(node) or ast.unparse(node) in self.handles)


def _opens(node: ast.AST | None) -> bool:
    """Tell whether an expression opens a file: ``open(...)``, ``x.open(...)``."""
    if not isinstance(node, ast.Call):
        return False
    func = node.func
    return (isinstance(func, ast.Name) and func.id == "open") or (
        isinstance(func, ast.Attribute) and func.attr == "open"
    )


def _bindings(tree: ast.Module) -> list[tuple[str, ast.AST]]:
    """Every ``name = value`` and ``with value as name`` in the module."""
    found: list[tuple[str, ast.AST]] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            names = [t.id for t in node.targets if isinstance(t, ast.Name)]
            found.extend((name, node.value) for name in names)
        elif isinstance(node, ast.AnnAssign) and node.value is not None:
            if isinstance(node.target, ast.Name):
                found.append((node.target.id, node.value))
        elif isinstance(node, (ast.With, ast.AsyncWith)):
            for item in node.items:
                if isinstance(item.optional_vars, ast.Name):
                    found.append((item.optional_vars.id, item.context_expr))
    return found


# A dispatch on the kind of call: one return per kind reads best.
def _emitted(  # pylint: disable=too-many-return-statements
    call: ast.Call,
    streams: _Streams,
) -> list[ast.AST] | None:
    """Return what a call writes out, or ``None`` when it writes nowhere there.

    ``print`` and any name bound to it (values, ``sep`` and ``end``;
    ``**kwargs`` stands for a value the analysis cannot follow) unless its
    ``file`` is standard error; ``write``/``writelines`` on standard output
    or a file this module opened, also through ``getattr``; ``write_text``
    and ``write_bytes`` on any path; and ``os.write`` (any descriptor).
    """
    func = call.func
    if isinstance(func, ast.Name) and func.id in streams.prints:
        target = next((kw.value for kw in call.keywords if kw.arg == "file"), None)
        if target is not None and ast.unparse(target) in streams.stderr:
            return None
        shown = [kw.value for kw in call.keywords if kw.arg in {"sep", "end"}]
        unknown = [_UNKNOWN for kw in call.keywords if kw.arg is None]
        return [*call.args, *shown, *unknown]
    if ast.unparse(func) == "os.write":
        return list(call.args[1:])
    if isinstance(func, ast.Call) and isinstance(func.func, ast.Name):
        # getattr(sys.stdout, "write")(raw)
        owner = func.args[0] if func.func.id == "getattr" and func.args else None
        if streams.is_stdout(owner) or streams.is_file(owner):
            return list(call.args)
        return None
    if isinstance(func, ast.Attribute) and func.attr in FILE_WRITES:
        return list(call.args[:1])
    if isinstance(func, ast.Attribute) and func.attr in STREAM_WRITES:
        written = streams.is_stdout(func.value) or streams.is_file(func.value)
        return list(call.args) if written else None
    return None


def _prints_raw(
    statement: ast.stmt,
    safe: set[str],
    calls: frozenset[str],
    streams: _Streams,
) -> bool:
    """Tell whether a statement writes an unsafe value out (the comment)."""
    for part in _own_expressions(statement):
        for node in ast.walk(part):
            if not isinstance(node, ast.Call):
                continue
            emitted = _emitted(node, streams)
            unsafe = [v for v in emitted or [] if not is_safe(v, safe, calls)]
            if unsafe:
                return True
    return False


def _mutated(statement: ast.stmt, safe: set[str], calls: frozenset[str]) -> set[str]:
    """Names other than ``sections`` a statement puts an unsafe value into.

    ``extra.append(raw)`` or ``extra[0] = raw`` leaves ``extra`` unsafe, so a
    later ``sections.extend(extra)`` is caught.
    """
    found: set[str] = set()
    calls_made = (
        node
        for part in _own_expressions(statement)
        for node in ast.walk(part)
        if isinstance(node, ast.Call)
    )
    for call in calls_made:
        func = call.func
        if not isinstance(func, ast.Attribute) or not isinstance(func.value, ast.Name):
            continue
        values = [*call.args, *(keyword.value for keyword in call.keywords)]
        if func.attr in MUTATORS and not all(is_safe(v, safe, calls) for v in values):
            found.add(func.value.id)
    targets: list[ast.expr] = []
    if isinstance(statement, ast.Assign):
        targets = statement.targets
    elif isinstance(statement, (ast.AugAssign, ast.AnnAssign)):
        targets = [statement.target]
    value = getattr(statement, "value", None)
    for target in targets:
        owner = target.value if isinstance(target, ast.Subscript) else None
        if isinstance(owner, ast.Name) and not is_safe(value, safe, calls):
            found.add(owner.id)
    return found - {"sections"}


def _parameters(func: ast.FunctionDef) -> set[str]:
    """Names of a function's parameters (the caller's values)."""
    params = func.args
    return {
        arg.arg
        for arg in (
            *params.posonlyargs,
            *params.args,
            *params.kwonlyargs,
            *filter(None, (params.vararg, params.kwarg)),
        )
    }


def _reviewed_line(lines: list[str], lineno: int) -> bool:
    """Tell whether a reviewer marked a statement ``# comment-safe: <reason>``."""
    own = lines[lineno - 1] if 0 < lineno <= len(lines) else ""
    above = lines[lineno - 2] if 1 < lineno <= len(lines) + 1 else ""
    marked = REVIEWED.search(own) is not None
    return marked or REVIEWED_LINE.fullmatch(above) is not None


class _Walk:  # pylint: disable=too-few-public-methods
    """Follow one function's statements, merging control-flow paths.

    The safe set after an ``if`` is what is safe on every branch (and on the
    path with no branch taken); after a loop, what is safe both when the body
    ran and when it did not; after ``try``, what every handler and the body
    leave safe. A value made safe on one path only is not safe after it.
    """

    def __init__(
        self,
        calls: frozenset[str],
        streams: _Streams,
        lines: list[str],
    ) -> None:
        self.calls = calls
        self.streams = streams
        self.lines = lines
        self.bad_lines: list[int] = []
        self.returns_safe = True

    def body(self, statements: list[ast.stmt], safe: set[str]) -> set[str]:
        """Walk a statement list; return the safe set after it."""
        for statement in statements:
            safe = self.statement(statement, safe)
        return safe

    def statement(self, statement: ast.stmt, safe: set[str]) -> set[str]:
        """Check one statement and return the safe set after it."""
        if isinstance(statement, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            return safe
        safe = set(safe) - _mutated(statement, safe, self.calls)
        bad = _adds_raw(statement, safe, self.calls)
        bad = bad or _assigns_into_sections(statement)
        bad = bad or _prints_raw(statement, safe, self.calls, self.streams)
        for target, value in _python_binding(statement):
            if target == "sections":
                # A list this path created (``sections = []``) is tracked in
                # the safe set itself, so a branch that did not create it
                # leaves the caller's list after the merge.
                fresh = is_safe(value, safe - {"sections", OWN_SECTIONS}, self.calls)
                bad = bad or not is_safe(value, safe | {"sections"}, self.calls)
                if fresh and not bad:
                    safe.add(OWN_SECTIONS)
                else:
                    safe.discard(OWN_SECTIONS)
            elif is_safe(value, safe, self.calls):
                safe.add(target)
            else:
                safe.discard(target)
        if isinstance(statement, ast.Return):
            # Every addition to a list this function made is checked, so the
            # list itself is safe; a caller's list never is.
            checked = safe | ({"sections"} if OWN_SECTIONS in safe else set())
            ok = is_safe(statement.value, checked, self.calls)
            self.returns_safe = self.returns_safe and ok
        if bad and not _reviewed_line(self.lines, statement.lineno):
            self.bad_lines.append(statement.lineno)
        return self._nested(statement, safe)

    def _nested(self, statement: ast.stmt, safe: set[str]) -> set[str]:
        """Walk a compound statement's blocks and merge their safe sets."""
        if isinstance(statement, ast.If):
            return self.body(statement.body, safe) & self.body(statement.orelse, safe)
        if isinstance(statement, (ast.For, ast.AsyncFor, ast.While)):
            ran = self.body(statement.body, safe)
            return safe & ran & self.body(statement.orelse, safe & ran)
        if isinstance(statement, (ast.With, ast.AsyncWith)):
            return self.body(statement.body, safe)
        if isinstance(statement, ast.Try):
            done = self.body(statement.orelse, self.body(statement.body, safe))
            for handler in statement.handlers:
                done &= self.body(handler.body, safe)
            return self.body(statement.finalbody, done & safe)
        if isinstance(statement, ast.Match):
            merged = set(safe)
            for case in statement.cases:
                merged &= self.body(case.body, safe)
            return merged
        return safe


#: Statements that define a named function or class.
_DEFINITIONS = (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)


def _local_names(func: ast.FunctionDef) -> set[str]:
    """Names a function binds itself: parameters, assignments, loop and
    ``with`` targets, imports and nested definitions (a callable the caller
    or the function supplies, never the module's)."""
    names = set(_parameters(func))
    for node in ast.walk(func):
        if isinstance(node, ast.Name) and isinstance(node.ctx, (ast.Store, ast.Del)):
            names.add(node.id)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            names.update((a.asname or a.name).split(".")[0] for a in node.names)
        elif isinstance(node, _DEFINITIONS) and node is not func:
            names.add(node.name)
    return names


def _unshadowed(calls: frozenset[str], shadowing: set[str]) -> frozenset[str]:
    """Drop the safe calls a binding shadows (``comment_sanitize`` included)."""
    kept = calls - shadowing
    if "comment_sanitize" in shadowing:
        kept -= {SANITISER}
    return frozenset(kept)


def _check_function(
    func: ast.FunctionDef,
    constants: set[str],
    calls: frozenset[str],
    context: tuple[_Streams, list[str]] | None = None,
) -> tuple[list[int], bool]:
    """Read one function, merging control-flow paths.

    Returns:
        The lines that add an unsafe value to ``sections`` or write one out,
        and whether every value the function returns is safe.
    """
    streams, lines = context or (_Streams(ast.Module(body=[], type_ignores=[])), [])
    local = _local_names(func)
    # An argument that shadows a module constant is the caller's value, and
    # a local or parameter named like a safe function is not that function.
    walk = _Walk(_unshadowed(calls, local), streams, lines)
    walk.body(func.body, set(constants) - _parameters(func))
    return walk.bad_lines, walk.returns_safe


def _module_rebound(tree: ast.Module) -> set[str]:
    """Names the module binds other than by ``def`` (assignment, import)."""
    names: set[str] = set()
    for node in tree.body:
        targets: list[ast.expr] = []
        if isinstance(node, ast.Assign):
            targets = list(node.targets)
        elif isinstance(node, (ast.AnnAssign, ast.AugAssign)):
            targets = [node.target]
        elif isinstance(node, ast.ImportFrom) or (
            isinstance(node, ast.Import) and any(a.asname for a in node.names)
        ):
            names.update(a.asname or a.name for a in node.names)
        names.update(t.id for t in targets if isinstance(t, ast.Name))
    if _imports_sanitiser(tree):
        names.discard("comment_sanitize")
    return names


def _imports_sanitiser(tree: ast.Module) -> bool:
    """Tell whether the module binds ``comment_sanitize`` only by ``import``."""
    return any(
        isinstance(node, ast.Import)
        and any(a.name == "comment_sanitize" and not a.asname for a in node.names)
        for node in tree.body
    )


def python_offences(source: str, where: str) -> list[str]:
    """List the values a Python formatter adds to ``sections`` or writes raw.

    A module-level function whose every return is safe counts as a safe call
    (``print(format_comment(path))``); that set is grown until it holds. A
    method of the same name never does, and a name defined twice must be
    safe in both. A statement marked ``# comment-safe: <reason>`` (on its
    first line or the line above) is a reviewer's word.

    Args:
        source: The module source.
        where: Path prefix for the messages.

    Returns:
        ``<where>:<line> in <function>`` for each offence.
    """
    tree = ast.parse(source)
    constants = _module_constants(tree)
    context = (_Streams(tree), source.split("\n"))
    module_functions = [n for n in tree.body if isinstance(n, ast.FunctionDef)]
    # A module function rebound at module level is not that function.
    base = _unshadowed(SAFE_CALLS, _module_rebound(tree))
    calls = base
    while True:
        unsafe = {
            func.name
            for func in module_functions
            if not _check_function(func, constants, calls, context)[1]
        }
        named = {func.name for func in module_functions} - _module_rebound(tree)
        grown = base | (named - unsafe)
        if grown == calls:
            break
        calls = grown
    found: list[str] = []
    for func in (n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)):
        for line in _check_function(func, constants, calls, context)[0]:
            found.append(f"{where}:{line} in {func.name}")
    return found
