# SPDX-License-Identifier: MIT
"""Find the external programs the scripts under ``scripts/ci`` run (#1624).

``tests/python/test_inline_shell_tools.py`` holds every program this finds
to a table: covered by the inline-shell deny list, or free of environment
hooks. The extraction is static and deliberately simple:

Shell (``*.sh``, ``*.bash``)
    The first word of each command: at the start of a line, after ``|``,
    ``&&``, ``||``, ``;``, ``$(``, a backquote or ``(``, and after a prefix
    that runs the next word (``then``, ``do``, ``exec``, ``command``,
    ``sudo``, ``env`` with its assignments, ...). Heredoc bodies, comments,
    quoted text, assignments, shell builtins and keywords, and functions
    defined anywhere under ``scripts/ci`` are skipped. A word that names a
    path (``./x.sh``, ``"$DIR/x"``) is skipped too: that is a script, not a
    tool.
Python (``*.py``)
    The first element of a list or tuple literal passed as the first
    argument of a subprocess call (``subprocess.run(["git", ...])``) or
    assigned to a command-line variable (``args = ["gh", ...]``, a list of
    them too), and the argument of ``shutil.which("x")``.
Wrappers (both)
    A wrapper (``uv run``, ``npx``, ``bun x``, ``pnpm exec``, ``pm_exec``,
    ``python3 -m MODULE``, ...) counts with the program it runs:
    ``inline_shell_wrappers`` says which words are wrappers and how their
    options are skipped.

What it misses (a program named only through a variable) is what the
curated ``INDIRECT`` table of the test lists by hand.
"""

from __future__ import annotations

import ast
import re
from collections.abc import Iterator
from pathlib import Path

import inline_shell_wrappers

PROGRAM = re.compile(r"[a-z][a-z0-9_+.-]*")
# A heredoc start; a here-string (``<<<``) is not one.
HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
FUNCTION = re.compile(
    r"^\s*(?:function\s+([A-Za-z_][\w:-]*)|([A-Za-z_][\w:-]*)\s*\(\s*\))",
)
# A case pattern before its body: ``alpha | beta)`` or ``*.tar.gz)``.
CASE_PATTERN = re.compile(r"^\s*\(?[^\s();|&]+(\s*\|\s*[^\s();|&]+)*\)")
# Calls that run their first argument as a command line.
SUBPROCESS_CALLS = frozenset(
    {"run", "Popen", "call", "check_call", "check_output", "execv", "execvp"},
)
# Variables that hold a command line (``args = ["gh", "api", ...]``).
ARGV_NAME = re.compile(r"(?:^|_)(?:args|argv|cmd|command|commands)$")
# Where a new command starts inside a line.
SEPARATOR = re.compile(r"\|\||&&|;;|[|;&`)]|\$\(|(?<![$<>])\(")
# States of _blank in which a word can start a command.
COMMAND_STATES = frozenset({"code", "sub", "paren"})
# Words after which the next word is the command.
PREFIX_WORDS = frozenset(
    {
        "then",
        "do",
        "else",
        "elif",
        "if",
        "while",
        "until",
        "!",
        "time",
        "exec",
        "command",
        "builtin",
        "sudo",
        "nohup",
        "timeout",
        "xargs",
        "env",
        "{",
    },
)
SHELL_WORDS = frozenset(
    {
        # keywords
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "while",
        "until", "do", "done", "in", "function", "select", "time", "{", "}",
        "[[", "]]", "!",
        # builtins
        "alias", "bg", "bind", "break", "builtin", "caller", "cd", "command",
        "compgen", "complete", "continue", "declare", "dirs", "disown", "echo",
        "enable", "eval", "exec", "exit", "export", "false", "fc", "fg",
        "getopts", "hash", "help", "history", "jobs", "kill", "let", "local",
        "logout", "mapfile", "popd", "printf", "pushd", "pwd", "read",
        "readarray", "readonly", "return", "set", "shift", "shopt", "source",
        "suspend", "test", "times", "trap", "true", "type", "typeset",
        "ulimit", "umask", "unalias", "unset", "wait", "[", ".", ":",
    },
)  # fmt: skip


def shell_files(root: Path) -> list[Path]:
    """Return every shell script under a directory, sorted."""
    return sorted([*root.rglob("*.sh"), *root.rglob("*.bash")])


def python_files(root: Path) -> list[Path]:
    """Return every Python file under a directory, sorted."""
    paths = root.rglob("*.py")
    return sorted(path for path in paths if "__pycache__" not in path.parts)


def shell_functions(paths: list[Path]) -> frozenset[str]:
    """Return every function name the shell files define."""
    names: set[str] = set()
    for path in paths:
        for line in path.read_text(encoding="utf-8", errors="replace").split("\n"):
            match = FUNCTION.match(line)
            if match:
                names.add(match[1] or match[2])
    return frozenset(names)


def _without_heredocs(text: str) -> str:
    """Return a shell script with every heredoc body left out."""
    kept: list[str] = []
    ending: list[str] = []
    for line in text.split("\n"):
        if ending:
            if line.strip() == ending[0]:
                ending.pop(0)
            continue
        kept.append(line)
        ending.extend(match[2] for match in HEREDOC.finditer(line))
    return "\n".join(kept)


class _Blanker:  # pylint: disable=too-few-public-methods
    """Blank everything in a script that is not a command word.

    Command substitutions stay, in and out of double quotes, so the commands
    they run are read. Quoted text (an awk or jq program, a message), the
    inside of ``${...}``, arithmetic, ``[[ ]]`` tests, array values and
    comments are blanked; a backslash-newline joins two lines, and a quoted
    newline becomes a space, so neither starts a command. ``stack`` holds the
    open states: ``code``, ``sub`` (``$(``), ``paren``, ``sq``, ``dq``,
    ``arith``, ``brace``, ``test`` (``[[``) and ``array`` (``=(``).
    """

    def __init__(self, text: str) -> None:
        self.text = text
        self.index = 0
        self.stack = ["code"]
        self.out: list[str] = []

    def run(self) -> str:
        """Return the blanked script."""
        while self.index < len(self.text):
            self._step()
        return "".join(self.out)

    def _at(self, prefix: str) -> bool:
        return self.text.startswith(prefix, self.index)

    def _emit(self, text: str, width: int = 1) -> None:
        self.out.append(text)
        self.index += width

    def _blank(self) -> None:
        """Blank one character; a newline becomes a space."""
        self._emit(" " if self.text[self.index] == "\n" else "_")

    def _step(self) -> None:
        top = self.stack[-1]
        char = self.text[self.index]
        if top == "sq":
            self._close_if(char == "'")
        elif char == "\\":
            self._emit(" " if self.text.startswith("\n", self.index + 1) else "__", 2)
        elif top == "arith":
            self._arith()
        elif top == "brace":
            self._brace(char)
        elif not self._expansion(top):
            self._quoted_or_code(top, char)

    def _close_if(self, closing: bool) -> None:
        if closing:
            self.stack.pop()
        self._blank()

    def _arith(self) -> None:
        if self._at("))"):
            self.stack.pop()
            self._emit("__", 2)
        else:
            self._blank()

    def _brace(self, char: str) -> None:
        if self._at("${"):
            self.stack.append("brace")
        elif char in "'\"":
            self.stack.append("sq" if char == "'" else "dq")
        elif char == "}":
            self.stack.pop()
        self._blank()

    def _expansion(self, top: str) -> bool:
        """Open ``$((``, ``((``, ``${`` or ``$(`` at the index; True when one opened."""
        for prefix, state in (("$((", "arith"), ("${", "brace"), ("$(", "sub")):
            if self._at(prefix):
                self.stack.append(state)
                self._emit("$(" if state == "sub" else "_" * len(prefix), len(prefix))
                return True
        if self._at("((") and top in COMMAND_STATES:
            self.stack.append("arith")
            self._emit("__", 2)
            return True
        return False

    def _quoted_or_code(self, top: str, char: str) -> None:
        if top == "dq":
            self._close_if(char == '"')
        elif char in "'\"":
            self.stack.append("sq" if char == "'" else "dq")
            self._emit("_")
        elif top in {"test", "array"}:
            self._words(top)
        else:
            self._code(top, char)

    def _previous(self) -> str:
        return self.text[self.index - 1] if self.index else "\n"

    def _words(self, top: str) -> None:
        """Blank a ``[[ ]]`` test or an array value up to its closer."""
        # A test ends at a ``]]`` word, not inside ``[[:space:]]``.
        closer = "]]" if top == "test" else ")"
        if self._at(closer) and (top == "array" or self._previous().isspace()):
            self.stack.pop()
            self._emit("_" * len(closer), len(closer))
        else:
            self._blank()

    def _code(self, top: str, char: str) -> None:
        previous = self._previous()
        if self._at("[[") and self.text[self.index + 2 : self.index + 3].isspace():
            self.stack.append("test")
            self._emit("__", 2)
        elif char == "(":
            self.stack.append("array" if previous == "=" else "paren")
            self._emit("_" if previous == "=" else char)
        elif char == "#" and previous in " \t\n;(":
            end = self.text.find("\n", self.index)
            self.index = len(self.text) if end < 0 else end
        else:
            if char == ")" and top in {"sub", "paren"}:
                self.stack.pop()
            self._emit(char)


def _first_command(segment: str) -> list[str]:
    """Return the command word of one segment and what it wraps, else []."""
    words = segment.split()
    index = 0
    while index < len(words):
        word = words[index]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=", word):
            index += 1  # an assignment before the command
        elif word in PREFIX_WORDS:
            index += 1
            while index < len(words) and words[index].startswith("-"):
                index += 1  # options of the prefix (sudo -E, timeout -k 5)
            if word == "timeout" and index < len(words):
                index += 1  # the duration
        else:
            wrapped: list[str] = inline_shell_wrappers.programs(words, index)
            return wrapped
    return []


def shell_programs(path: Path, functions: frozenset[str]) -> set[str]:
    """Return the external programs one shell script runs."""
    found: set[str] = set()
    raw = path.read_text(encoding="utf-8", errors="replace")
    text = _Blanker(_without_heredocs(raw)).run()
    for line in text.split("\n"):
        for segment in SEPARATOR.split(CASE_PATTERN.sub("", line)):
            found.update(
                word
                for word in _first_command(segment)
                if PROGRAM.fullmatch(word)
                and word not in SHELL_WORDS
                and word not in functions
                and not word.endswith((".sh", ".py", ".bash"))
            )
    return found


def _call_name(node: ast.Call) -> str:
    """Return the last name of what a call calls (``subprocess.run`` -> ``run``)."""
    func = node.func
    if isinstance(func, ast.Attribute):
        return func.attr
    return func.id if isinstance(func, ast.Name) else ""


def _target_name(node: ast.expr) -> str:
    """Return the name an assignment target binds (``x``, ``self.x``), else ""."""
    if isinstance(node, ast.Attribute):
        return node.attr
    return node.id if isinstance(node, ast.Name) else ""


def _argv_heads(node: ast.expr | None) -> Iterator[str]:
    """Yield the program of an argv literal, and of each argv in a list of them."""
    if not isinstance(node, ast.List | ast.Tuple) or not node.elts:
        return
    head = node.elts[0]
    if isinstance(head, ast.Constant) and isinstance(head.value, str):
        words: list[str] = []
        for element in node.elts:
            if not isinstance(element, ast.Constant) or not isinstance(
                element.value,
                str,
            ):
                break
            words.append(element.value)
        yield from inline_shell_wrappers.programs(words)
    else:
        for element in node.elts:
            yield from _argv_heads(element)


def python_programs(path: Path) -> set[str]:
    """Return the external programs one Python file runs."""
    heads: list[str] = []
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and node.args:
            name = _call_name(node)
            first = node.args[0]
            if name == "which" and isinstance(first, ast.Constant):
                heads.append(str(first.value))
            elif name in SUBPROCESS_CALLS:
                heads.extend(_argv_heads(first))
        elif isinstance(node, ast.Assign | ast.AnnAssign):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            if any(ARGV_NAME.search(_target_name(t)) for t in targets):
                heads.extend(_argv_heads(node.value))
    names = {head.rsplit("/", 1)[-1] for head in heads}
    return {name for name in names if PROGRAM.fullmatch(name)}


def programs(root: Path) -> dict[str, list[str]]:
    """Return each external program the scripts under ``root`` run.

    Args:
        root: ``scripts/ci`` of a repository.

    Returns:
        Program name -> the files (relative to ``root``) that run it.
    """
    shells = shell_files(root)
    functions = shell_functions(shells)
    found: dict[str, list[str]] = {}
    for path in shells:
        for name in shell_programs(path, functions):
            found.setdefault(name, []).append(path.relative_to(root).as_posix())
    for path in python_files(root):
        for name in python_programs(path):
            found.setdefault(name, []).append(path.relative_to(root).as_posix())
    return found
