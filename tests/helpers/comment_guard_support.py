# SPDX-License-Identifier: MIT
"""Analysis behind ``tests/python/test_comment_renderer_guard.py`` (#1676).

Bash: a small quote-aware scanner splits a script into statements (at
newlines, ``;``, ``&&`` and ``||`` outside quotes, substitutions and
``[[ ... ]]``), keeps comments apart from code, keeps multi-line quoted
strings in one statement, and returns each unquoted heredoc body line as a
statement of its own. Untrusted values are followed in file order: an
assignment copies the taint of what it reads (a listed variable, a tainted
variable or file content from a reader), an assignment from the sanitiser or a
number check clears it, and any other statement that uses a tainted value
outside a sanitiser feed, a test, a default or a log annotation is an
offence.

Python: each function is read statement by statement, in order, so a raw
value assigned after a safe one is caught; every way of adding to the
comment's ``sections`` list is checked.
"""

from __future__ import annotations

import ast
import re
from dataclasses import dataclass
from typing import TypeGuard

#: Commands whose output a renderer may insert: the sanitiser, the chrome
#: helpers that call it, and the number checks.
SINK_COMMANDS = frozenset(
    {
        "comment_sanitize",
        "comment_chrome_heading",
        "comment_chrome_footer",
    },
)
#: Commands whose output is file content (untrusted until checked).
READERS = frozenset({"jq", "cat", "sed", "awk", "grep", "tail", "head", "cut"})
LOG_COMMANDS = frozenset({"log_info", "log_error", "log_warn"})
KEYWORDS = frozenset(
    {"if", "elif", "while", "until", "then", "else", "do", "!", "time"},
)
REVIEWED = re.compile(r"#\s*comment-safe:\s*\S")
REVIEWED_LINE = re.compile(r"\s*#\s*comment-safe:\s*\S.*")
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_]\w*)\1")
_DECLARE = r"(?:(?:local|declare|readonly|export)\s+(?:-\w+\s+)*)?"
ASSIGNED = re.compile(_DECLARE + r"([A-Za-z_]\w*)(\+?)=")
PRINTF_V = re.compile(r"printf\s+-v\s+([A-Za-z_]\w*)\s")
_MAPFILE_FLAGS = r"(?:\s+-\w+(?:\s+'[^']*'|\s+\"[^\"]*\")?)*"
MAPFILE = re.compile(r"(?:mapfile|readarray)\b" + _MAPFILE_FLAGS + r"\s+(\w+)")
ENV_WORD = re.compile(r"[A-Za-z_]\w*=\S*")
TESTED = re.compile(r"\[\[.*?\]\]|^\[\s.*\s\]$|^case\s+\S+\s+in", re.S)
WRITES = re.compile(r"(?<![<&0-9-])>(?!&)")
NUMBER_READ = re.compile(r"comment_read_(?:count|decimal)\s+([A-Za-z_]\w*)\s")
LOG_PRINT = re.compile(r"\S+\s+(?:--\s+)?['\"]::")
NEVER = re.compile(r"(?!)")
_BLOCKS = (ast.Try, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)


@dataclass(frozen=True)
class Statement:
    """One shell statement, or one unquoted heredoc body line.

    Attributes:
        line: Its first physical line number.
        code: The code, comments removed.
        comment: The comments written on its physical lines.
        above: The physical line before it.
        heredoc: True for a heredoc body line.
    """

    line: int
    code: str
    comment: str
    above: str
    heredoc: bool = False


# One small state machine: its state is its attributes.
class _Scanner:  # pylint: disable=too-few-public-methods,too-many-instance-attributes
    """Split a bash script into :class:`Statement` objects."""

    def __init__(self, text: str) -> None:
        self.text = text
        self.lines = text.split("\n")
        self.found: list[tuple[int, int, str, bool]] = []
        self.comments: dict[int, str] = {}
        self.buf: list[str] = []
        self.start = 1
        self.line = 1
        self.stack: list[str] = []
        self.pending: list[tuple[str, bool, bool]] = []

    def _flush(self) -> None:
        """Close the current statement."""
        code = "".join(self.buf).strip()
        if code:
            self.found.append((self.start, self.line, code, False))
        self.buf = []

    def _heredocs(self, index: int) -> int:
        """Read the bodies of pending heredocs after the newline at ``index``."""
        position = index + 1
        for delimiter, quoted, strip_tabs in self.pending:
            while position <= len(self.text):
                end = self.text.find("\n", position)
                end = len(self.text) if end < 0 else end
                body = self.text[position:end]
                position = end + 1
                check = body.lstrip("\t") if strip_tabs else body
                if check == delimiter:
                    self.line += 1
                    break
                if not quoted:
                    self.found.append((self.line, self.line, body, True))
                self.line += 1
        self.pending = []
        return position

    def _open_or_close(self, char: str, two: str, top: str) -> int:
        """Track quotes, substitutions and tests; return characters consumed."""
        if char == "'" and top != '"':
            self.stack.append("'")
        elif char == '"':
            if top == '"':
                self.stack.pop()
            else:
                self.stack.append('"')
        elif two in {"$(", "<(", ">(", "${"}:
            self.stack.append(two if two == "${" else "$(")
            return 2
        elif char == "}" and top == "${":
            self.stack.pop()
        elif two == "[[" and top in {"", "$(", "("}:
            self.stack.append("[[")
            return 2
        elif two == "]]" and top == "[[":
            self.stack.pop()
            return 2
        elif char == "(" and top in {"", "$(", "("}:
            self.stack.append("(")
        elif char == ")" and top in {"$(", "("}:
            self.stack.pop()
        return 1

    def run(self) -> list[Statement]:  # pylint: disable=too-many-branches
        """Scan the whole text."""
        text, i = self.text, 0
        while i < len(text):
            char, two = text[i], text[i : i + 2]
            top = self.stack[-1] if self.stack else ""
            if char not in " \t\n" and not "".join(self.buf).strip():
                self.start = self.line  # first non-blank character
            if top == "'":
                self.buf.append(char)
                if char == "'":
                    self.stack.pop()
                elif char == "\n":
                    self.line += 1
                i += 1
            elif char == "\\" and i + 1 < len(text):
                if text[i + 1] == "\n":
                    self.line += 1
                else:
                    self.buf.append(two)
                i += 2
            elif (
                char == "#"
                and top not in {'"', "${"}
                and (not self.buf or self.buf[-1][-1:] in {" ", "\t", "\n", ";", "("})
            ):
                end = text.find("\n", i)
                end = len(text) if end < 0 else end
                self.comments[self.line] = text[i:end]
                i = end
            elif char == "\n":
                if top == "":
                    self._flush()
                else:
                    self.buf.append("\n")
                self.line += 1
                i = self._heredocs(i) if self.pending else i + 1
            elif top == "" and (two in {"&&", "||", ";;"} or char == ";"):
                self._flush()
                i += 2 if two in {"&&", "||", ";;"} else 1
            else:
                heredoc = None
                if two == "<<" and text[i : i + 3] != "<<<" and top != '"':
                    heredoc = HEREDOC.match(text, i)
                if heredoc:
                    quoted = bool(heredoc.group(1))
                    self.pending.append((heredoc.group(2), quoted, text[i + 2] == "-"))
                    self.buf.append(heredoc.group(0))
                    i = heredoc.end()
                    continue
                used = self._open_or_close(char, two, top)
                self.buf.append(text[i : i + used])
                i += used
        self._flush()
        return [self._statement(*entry) for entry in self.found]

    def _statement(self, start: int, end: int, code: str, heredoc: bool) -> Statement:
        """Build a statement with the comments of its lines."""
        if heredoc:
            return Statement(start, code, "", "", heredoc=True)
        span = range(start, end + 1)
        notes = " ".join(self.comments[n] for n in span if n in self.comments)
        above = self.lines[start - 2] if start > 1 else ""
        return Statement(start, code, notes, above)


def statements(text: str) -> list[Statement]:
    """Split a bash script into statements; see the module docstring."""
    return _Scanner(text).run()


def _close(code: str, start: int) -> int:
    """Return the index after the ``)`` closing the substitution at ``start``."""
    depth, i, quote = 0, start, ""
    while i < len(code):
        char = code[i]
        if quote == "'":
            quote = "" if char == "'" else quote
        elif char == "\\":
            i += 1
        elif char == "'" and quote != '"':
            quote = "'"
        elif char == '"':
            quote = "" if quote == '"' else '"'
        elif code[i : i + 2] in {"$(", "<(", ">("}:
            depth += 1
            i += 1
        elif char == "(" and not quote:
            depth += 1
        elif char == ")" and (not quote or depth > 0):
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(code)


def _at_separator(code: str, index: int, separator: str) -> bool:
    """Tell whether ``separator`` starts at ``index`` (``|`` never inside ``||``)."""
    if not code.startswith(separator, index):
        return False
    return separator != "|" or code[index : index + 2] != "||"


def _split_top(code: str, separator: str) -> list[str]:
    """Split ``code`` at ``separator`` outside quotes, substitutions and tests."""
    parts, depth, quote, current, i = [], 0, "", [], 0
    while i < len(code):
        char = code[i]
        if quote == "'":
            quote = "" if char == "'" else quote
        elif char == "\\":
            current.append(code[i : i + 2])
            i += 2
            continue
        elif char in "'\"" and (not quote or quote == char):
            quote = "" if quote == char else char
        elif char in "([{" and not quote:
            depth += 1
        elif char in ")]}" and not quote:
            depth -= 1
        elif not quote and depth <= 0 and _at_separator(code, i, separator):
            parts.append("".join(current))
            current = []
            i += len(separator)
            continue
        current.append(char)
        i += 1
    parts.append("".join(current))
    return parts


def _strip_keywords(code: str) -> str:
    """Drop leading shell keywords from a statement."""
    words = code.split(" ")
    while words and words[0] in KEYWORDS:
        words.pop(0)
    return " ".join(words).strip()


def _first_word(code: str) -> str:
    """Return the command word of ``code``, after keywords and assignments."""
    words = code.split()
    while words and (words[0] in KEYWORDS or ENV_WORD.fullmatch(words[0])):
        words.pop(0)
    return words[0] if words else ""


def _command_lists(code: str) -> list[str]:
    """Split code into the commands joined by ``;``, ``&&``, ``||`` or newlines."""
    parts = [re.sub(r"(\|\|?|&&)[ \t]*\n", r"\1 ", code)]  # continued lines
    for separator in (";", "&&", "||", "\n"):
        parts = [piece for part in parts for piece in _split_top(part, separator)]
    return parts


def _blank_pipeline(code: str) -> str:
    """Blank the stages of one pipeline up to its last sanitiser stage.

    Nothing is blanked when a stage before the sanitiser writes a file
    (``tee`` or a ``>`` redirection): that copy of the value is raw.
    """
    stages = _split_top(code, "|")
    sinks = [n for n, stage in enumerate(stages) if _first_word(stage) in SINK_COMMANDS]
    if not sinks:
        return code
    feeding = stages[: sinks[-1]]
    if any(_first_word(stage) == "tee" or WRITES.search(stage) for stage in feeding):
        return code
    return "|".join(["SANITISED"] * (sinks[-1] + 1) + stages[sinks[-1] + 1 :])


def _reads(code: str) -> bool:
    """Tell whether any command in ``code`` starts with a reader of file content.

    ``cat <<EOF`` prints the renderer's own heredoc, so it is not a reader.
    """
    for part in _command_lists(code):
        first = _split_top(part, "|")[0]
        command = _first_word(first)
        own_heredoc = command == "cat" and "<<" in first and "<<<" not in first
        if command in READERS and not own_heredoc:
            return True
    return False


def blank_sanitised(code: str) -> str:
    """Remove the substitutions and pipeline stages that feed the sanitiser.

    Each ``;``, ``&&``, ``||`` or newline part of a substitution is judged on
    its own: a substitution becomes ``SANITISED`` only when every part ends in
    the sanitiser; otherwise the parts that do not stay visible.
    """
    out, i = [], 0
    while i < len(code):
        if code[i : i + 2] in {"$(", "<(", ">("}:
            end = _close(code, i)
            inner = _command_lists(code[i + 2 : end - 1])
            parts = [_blank_pipeline(blank_sanitised(part)) for part in inner]
            left = [part.replace("SANITISED", "").replace("|", "") for part in parts]
            whole = not "".join(left).strip()
            kept = code[i : i + 2] + " ; ".join(parts) + ")"
            out.append("SANITISED" if whole else kept)
            i = end
            continue
        out.append(code[i])
        i += 1
    return _blank_pipeline("".join(out))


def _inline_reader(code: str) -> bool:
    """Tell whether ``code`` has a substitution that reads file content."""
    for found in re.finditer(r"[$<>]\(", code):
        end = _close(code, found.start())
        if _reads(code[found.start() + 2 : end - 1]):
            return True
    return False


def _harmless(code: str, ref: re.Pattern[str], name: str) -> bool:
    """Tell whether a use of ``name`` in ``code`` never reaches the comment."""
    rest = _strip_keywords(code)
    first = rest.split()[0] if rest.split() else ""
    if first in {"[[", "[", "test"} or rest.startswith("case "):
        return ref.search(TESTED.sub("", rest)) is None
    printed = first in {"echo", "printf"} and LOG_PRINT.match(rest) is not None
    log = first in LOG_COMMANDS or rest.endswith(">&2") or printed
    defaults = (
        rf':\s+"\$\{{{name}:[=?][^}}]*\}}"',
        rf"export(?:\s+\w+)*\s+{name}(?:\s+\w+)*",
    )
    return log or any(re.fullmatch(pattern, rest) for pattern in defaults)


def _binding(code: str) -> tuple[str, str, bool] | None:
    """Return (name, value, appends) when a statement assigns a variable."""
    rest = _strip_keywords(code)
    printf_v = PRINTF_V.match(rest)
    if printf_v:
        return printf_v.group(1), rest[printf_v.end() :], False
    mapped = MAPFILE.match(rest)
    if mapped:
        return mapped.group(1), rest, False
    assigned = ASSIGNED.match(rest)
    if not assigned:
        return None
    value = rest[assigned.end() :]
    words = [part for part in _split_top(value, " ") if part.strip()]
    if len(words) > 1:  # NAME=value command ...: an environment prefix
        return None
    return assigned.group(1), value, assigned.group(2) == "+"


def _ref(name: str) -> re.Pattern[str]:
    """Match a use of ``$name``, ``${name...}`` or ``${!name}``."""
    return re.compile(rf"\$\{{?!?{name}\b")


def _reviewed(statement: Statement) -> bool:
    """Tell whether a reviewer marked the statement ``# comment-safe:``."""
    if statement.heredoc:
        return False
    on_line = REVIEWED.search(statement.comment) is not None
    return on_line or REVIEWED_LINE.fullmatch(statement.above) is not None


def _track(
    tainted: dict[str, str],
    bound: tuple[str, str, bool],
    statement: Statement,
) -> None:
    """Update the taint of the variable an assignment binds."""
    name, value, appends = bound
    uses = sorted(n for n in tainted if _ref(n).search(value))
    arithmetic = re.fullmatch(r'"?\$\(\(.*\)\)"?', value.strip(), re.S)
    # Only a value that references nothing (a constant, or sanitiser output
    # alone) clears taint: an earlier branch may have set it.
    constant = "$" not in value.replace("SANITISED", "") and "`" not in value
    if _reviewed(statement) or arithmetic:
        tainted.pop(name, None)  # a reviewer's word, or a number
    elif uses:
        tainted[name] = tainted[uses[0]]
    elif _inline_reader(value):
        tainted[name] = f"file content read at line {statement.line}"
    elif constant and not appends:
        tainted.pop(name, None)


def _judge(statement: Statement, code: str, tainted: dict[str, str]) -> str | None:
    """Return why a non-assignment statement is an offence, or ``None``."""
    if _reviewed(statement):
        return None
    if _inline_reader(code) and (statement.heredoc or not _harmless(code, NEVER, "_")):
        return f"file content read in: {statement.code}"
    for name in sorted(tainted):
        ref = _ref(name)
        harmless = not statement.heredoc and _harmless(code, ref, name)
        if ref.search(code) and not harmless:
            return f"${name} not sanitised ({tainted[name]}): {statement.code}"
    return None


class _Branches:  # pylint: disable=too-few-public-methods
    """Follow ``if``/``elif``/``else``/``fi`` so a branch cannot clear another's taint.

    Each branch starts from the taint before the ``if``; after ``fi`` a value is
    untrusted when any branch (or the path with no branch taken) left it so.
    """

    def __init__(self) -> None:
        self.frames: list[tuple[dict[str, str], list[dict[str, str]], bool]] = []

    def step(self, code: str, tainted: dict[str, str]) -> dict[str, str]:
        """Return the taint to use for the statement ``code`` starts with."""
        word = code.split(maxsplit=1)[0] if code.split() else ""
        if word == "if":
            self.frames.append((dict(tainted), [], False))
        elif word in {"elif", "else"} and self.frames:
            start, ends, has_else = self.frames.pop()
            ends.append(dict(tainted))
            self.frames.append((start, ends, has_else or word == "else"))
            return dict(start)
        elif word == "fi" and self.frames:
            start, ends, has_else = self.frames.pop()
            merged: dict[str, str] = {}
            for state in [*ends, tainted, *([] if has_else else [start])]:
                merged.update(state)
            return merged
        return tainted


#: Constructs the analysis cannot follow; a renderer may not use them.
UNCLASSIFIABLE = (
    (re.compile(r"(?<!\\)`"), "a backtick command substitution"),
    (re.compile(r"\b(?:declare|local|typeset)\s+-\w*n"), "a name reference"),
    (re.compile(r"\$\{!"), "an indirect expansion"),
    (re.compile(r"\b(?:envsubst|printenv)\b"), "an environment expansion"),
    (re.compile(r"(?:^|[\s;])[A-Za-z_]\w*\[[^\]]*\]\+?="), "a subscript assignment"),
)


def _unclassifiable(statement: Statement) -> str | None:
    """Name a construct in ``statement`` the analysis cannot follow, if any."""
    code = statement.code
    if not statement.heredoc:  # single quotes are literal text, not code
        code = re.sub(r"'[^']*'", "''", code)
    for pattern, what in UNCLASSIFIABLE:
        if pattern.search(code):
            return f"{what} the guard cannot follow: {statement.code}"
    return None


def offences(text: str, names: tuple[str, ...], where: str) -> list[str]:
    """List the uses of untrusted values that may reach the comment unsanitised.

    Args:
        text: The bash script.
        names: Variables that hold untrusted text throughout the script.
        where: Path prefix for the messages.

    Returns:
        ``<where>:<line>: <reason>: <statement>`` for each offence.
    """
    tainted = {name: f"${name}" for name in names}
    found: list[str] = []
    branches = _Branches()
    for statement in statements(text):
        unknown = _unclassifiable(statement)
        if unknown:
            found.append(f"{where}:{statement.line}: {unknown}")
            continue
        if not statement.heredoc:
            tainted = branches.step(statement.code, tainted)
        code = blank_sanitised(statement.code)
        number = NUMBER_READ.match(_strip_keywords(statement.code))
        if number and not statement.heredoc:
            # comment_read_count/decimal VAR ... sets VAR to a checked number.
            tainted.pop(number.group(1), None)
            continue
        bound = None if statement.heredoc else _binding(code)
        if bound:
            if bound[0] not in names:  # a listed variable stays untrusted
                _track(tainted, bound, statement)
            continue
        reason = _judge(statement, code, tainted)
        if reason:
            found.append(f"{where}:{statement.line}: {reason}")
    return found


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
SAFE_CALLS = frozenset({"_count"})


# A dispatch on node type: one return per kind of node reads best.
def is_safe(  # pylint: disable=too-many-return-statements
    node: ast.AST | None,
    safe: set[str],
) -> bool:
    """Tell whether a Python expression is sanitiser output or built from safe parts."""
    if node is None or isinstance(node, ast.Constant):
        return True
    if isinstance(node, ast.Name):
        return node.id in safe
    if isinstance(node, ast.Call):
        func = node.func
        if isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name):
            return func.value.id == "comment_sanitize" and func.attr in MODE_FUNCTIONS
        return isinstance(func, ast.Name) and func.id in SAFE_CALLS
    if isinstance(node, ast.JoinedStr):
        return all(is_safe(part, safe) for part in node.values)
    if isinstance(node, ast.FormattedValue):
        return is_safe(node.value, safe)
    if isinstance(node, ast.BinOp):
        return is_safe(node.left, safe) and is_safe(node.right, safe)
    if isinstance(node, ast.IfExp):
        return is_safe(node.body, safe) and is_safe(node.orelse, safe)
    if isinstance(node, ast.BoolOp):
        return all(is_safe(value, safe) for value in node.values)
    if isinstance(node, (ast.List, ast.Tuple)):
        return all(is_safe(element, safe) for element in node.elts)
    if isinstance(node, (ast.ListComp, ast.GeneratorExp, ast.SetComp)):
        # A comprehension variable is never safe, even if it shadows one that is.
        bound = {
            name.id
            for generator in node.generators
            for name in ast.walk(generator.target)
            if isinstance(name, ast.Name)
        }
        return is_safe(node.elt, safe - bound)
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
    if isinstance(statement, _BLOCKS):
        return []
    return [statement]


def _ordered(body: list[ast.stmt]) -> list[ast.stmt]:
    """Flatten a body in source order, nested blocks included, functions not."""
    flat: list[ast.stmt] = []
    for statement in body:
        flat.append(statement)
        if isinstance(statement, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            continue
        for field in ("body", "orelse", "finalbody"):
            flat.extend(_ordered(getattr(statement, field, []) or []))
        for handler in getattr(statement, "handlers", []) or []:
            flat.extend(_ordered(handler.body))
    return flat


#: Stands for a value the analysis cannot follow (tuple unpacking).
_UNKNOWN = ast.Name(id="<unknown>")


def _python_binding(statement: ast.stmt) -> list[tuple[str, ast.AST | None]]:
    """Return each name a statement binds with the value it binds.

    Chained assignment (``a = b = value``) binds every name to the value;
    unpacking binds each name to a value the analysis cannot follow.
    """
    if isinstance(statement, ast.Assign):
        bound: list[tuple[str, ast.AST | None]] = []
        for target in statement.targets:
            if isinstance(target, ast.Name):
                bound.append((target.id, statement.value))
            elif isinstance(target, (ast.Tuple, ast.List)):
                names = [n.id for n in ast.walk(target) if isinstance(n, ast.Name)]
                bound.extend((name, _UNKNOWN) for name in names)
        return bound
    walrus = [
        (node.target.id, node.value)
        for part in _own_expressions(statement)
        for node in ast.walk(part)
        if isinstance(node, ast.NamedExpr)
    ]
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


def _module_constants(tree: ast.Module) -> set[str]:
    """Names the module binds, at top level, to constants only."""
    safe: set[str] = set()
    for statement in tree.body:
        for name, value in _python_binding(statement):
            if is_safe(value, safe):
                safe.add(name)
            else:
                safe.discard(name)
    return safe


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


def _adds_raw(statement: ast.stmt, safe: set[str]) -> bool:
    """Tell whether a statement adds an unsafe value to ``sections``."""
    for part in _own_expressions(statement):
        for node in ast.walk(part):
            if _sections_call(node):
                insert = getattr(node.func, "attr", "") == "insert"
                args = node.args[1:] if insert else node.args
                if not all(is_safe(arg, safe) for arg in args):
                    return True
    return False


def python_offences(source: str, where: str) -> list[str]:
    """List the values a Python formatter adds to ``sections`` unsanitised.

    Args:
        source: The module source.
        where: Path prefix for the messages.

    Returns:
        ``<where>:<line> in <function>`` for each offence.
    """
    found: list[str] = []
    tree = ast.parse(source)
    constants = _module_constants(tree)
    for func in (n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)):
        # An argument that shadows a module constant is the caller's value.
        params = func.args
        shadowed = {
            arg.arg
            for arg in (
                *params.posonlyargs,
                *params.args,
                *params.kwonlyargs,
                *filter(None, (params.vararg, params.kwarg)),
            )
        }
        safe = set(constants) - shadowed
        for statement in _ordered(func.body):
            bad = _adds_raw(statement, safe) or _assigns_into_sections(statement)
            for target, value in _python_binding(statement):
                if target == "sections":
                    bad = bad or not is_safe(value, safe | {"sections"})
                elif is_safe(value, safe):
                    safe.add(target)
                else:
                    safe.discard(target)
            if bad:
                found.append(f"{where}:{statement.lineno} in {func.name}")
    return found
