# SPDX-License-Identifier: MIT
"""Analysis behind ``tests/python/test_comment_renderer_guard.py`` (#1676).

Bash: a small quote-aware scanner splits a script into statements (at
newlines, ``;``, ``&&`` and ``||`` outside quotes, substitutions and
``[[ ... ]]``), keeps comments apart from code, keeps multi-line quoted
strings in one statement, and returns each unquoted heredoc body line as a
statement of its own. Untrusted values are followed in file order: an
assignment copies the taint of what it reads (a listed variable, a tainted
variable or file content from a reader), an assignment from the sanitiser or a
number check clears it, ``read``/``mapfile`` taint what they set with their
input, and any other statement that uses a tainted value outside a sanitiser
feed, a test, a default or a log annotation (not written into a file) is an
offence, as is a reader whose output is written into a file. A write is any
output redirection with or without a descriptor, ``tee FILE``, or ``>&N``
onto a descriptor ``exec`` opened on a file; substitutions are looked into
before quoted text is set aside.

Python formatters are analysed in ``comment_guard_python.py``.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

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
ENV_WORD = re.compile(r"[A-Za-z_]\w*=\S*")
TESTED = re.compile(r"\[\[.*?\]\]|^\[\s.*\s\]$|^case\s+\S+\s+in", re.S)
#: An output redirection: >, >>, >| with or without a file descriptor (1>,
#: 2>, &>, &>>), and the read-write <> (1<>file writes into the file), never
#: a duplication such as >&2 or 2>&1.
WRITES = re.compile(r"(?<!-)>(?!&)")
DEV_NULL = re.compile(r"(?:[0-9]+|&)?>>?\|?\s*/dev/null\b")
#: A duplication onto a descriptor: >&3, 1>&3, 2>&3, >&$fd, and the quoted
#: >&"$fd" that shellcheck asks for.
DUPLICATES = re.compile(r""">&\s*["']?([0-9]+|\$\{?[A-Za-z_]\w*\}?)""")
#: exec N>file (or exec >file): every later >&N writes into that file.
#: One output redirection of an exec: N>file, {name}>file, >file, or the
#: read-write N<>file. Every redirection of the statement is scanned, not
#: only the first.
EXEC_OPENS = re.compile(r"(?:^|\s)([0-9]*|\{[A-Za-z_]\w*\})(<?)>>?\|?(?!&)\s*(\S+)")
QUOTED = re.compile(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"", re.S)
IDENTIFIER = re.compile(r"[A-Za-z_]\w*")
#: ``read`` options that take an argument (``-a`` names the array it sets).
READ_FLAGS_WITH_ARGUMENT = frozenset("adminNptu")
NUMBER_READ = re.compile(r"comment_read_(?:count|decimal)\s+([A-Za-z_]\w*)\s")
LOG_PRINT = re.compile(r"\S+\s+(?:--\s+)?['\"]::")
NEVER = re.compile(r"(?!)")


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
    if any(_first_word(stage) == "tee" or _writes(stage) for stage in feeding):
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


def _substitutions(code: str) -> tuple[str, list[str]]:
    """Return ``code`` with each ``$(...)``/``<(...)``/``>(...)`` replaced by
    ``SUB``, and the bodies it took out (so quote stripping keeps them)."""
    out, bodies, i = [], [], 0
    while i < len(code):
        if code[i : i + 2] in {"$(", "<(", ">("}:
            end = _close(code, i)
            bodies.append(code[i + 2 : end - 1])
            out.append("SUB")
            i = end
            continue
        out.append(code[i])
        i += 1
    return "".join(out), bodies


def _tees(code: str) -> bool:
    """Tell whether a pipeline stage is ``tee`` with a file argument."""
    for part in _command_lists(code):
        for stage in _split_top(part, "|"):
            words = _command_words(stage)
            if words and words[0] == "tee":
                files = [w for w in words[1:] if not w.startswith("-")]
                if any(w != "/dev/null" for w in files):
                    return True
    return False


def _writes(code: str, fds: frozenset[str] = frozenset()) -> bool:
    """Tell whether ``code`` writes output into a file (``/dev/null`` aside).

    A redirection with any descriptor (``1>``, ``2>``, ``&>``, ``>|`` and the
    appending forms), ``tee FILE``, and ``>&N`` onto a descriptor ``exec``
    opened on a file (``fds``) all write; ``>&2`` and ``2>&1`` alone do not.
    A ``>`` inside quotes (``"<unset>"``) is text, but a command substitution
    inside quotes is code and is looked into.
    """
    outer, bodies = _substitutions(code)
    if any(_writes(body, fds) for body in bodies):
        return True
    unquoted = QUOTED.sub("''", outer)
    if WRITES.search(DEV_NULL.sub("", unquoted)) or _tees(unquoted):
        return True
    return any(_descriptor(fd) in fds for fd in DUPLICATES.findall(code))


def _hidden_write(code: str) -> bool:
    """Tell whether a substitution in ``code`` reads file content into a file."""
    _, bodies = _substitutions(code)
    return any(_reads(body) and _writes(body) or _hidden_write(body) for body in bodies)


def _descriptor(word: str) -> str:
    """Normalise a descriptor: ``3``, ``{fd}``, ``$fd`` and ``${fd}`` alike."""
    name = word.strip("{}$")
    return name if name.isdigit() else f"${name}"


def _exec_opens(code: str) -> set[str]:
    """Descriptors an ``exec`` statement opens on a file (1 for ``exec >f``).

    Every redirection of the statement is scanned (``exec 3>a 4>b`` opens
    both), ``exec 3<>file`` opens 3 for writing too, and ``exec {fd}>file``
    opens the descriptor ``$fd`` names.
    """
    unquoted = QUOTED.sub("''", code)
    words = _strip_keywords(unquoted).split(maxsplit=1)
    if words[:1] != ["exec"] or len(words) < 2:
        return set()
    found = set()
    for fd, read_write, target in EXEC_OPENS.findall(DEV_NULL.sub("", words[1])):
        if target:
            # <> without a descriptor opens standard input, > standard output.
            found.add(_descriptor(fd) if fd else ("0" if read_write else "1"))
    return found


def _command_words(stage: str) -> list[str]:
    """Return the words of one pipeline stage, keywords and assignments dropped."""
    words = [w for w in _split_top(_strip_keywords(stage.strip()), " ") if w.strip()]
    while words and ENV_WORD.fullmatch(words[0]):
        words.pop(0)
    return words


#: A word that cannot name a variable the guard can follow.
UNFOLLOWED = "<unfollowed>"


def _literal(word: str) -> str:
    """Return a quoted literal word unquoted (``"value"``, ``'value'``).

    A word that still holds an expansion (``"$name"``) is left as it is, so
    it is no identifier and the caller rejects it as unfollowed.
    """
    quoted = re.fullmatch(r"'([^']*)'|\"([^\"$`\\]*)\"", word)
    if not quoted:
        return word
    return quoted.group(1) if quoted.group(1) is not None else quoted.group(2)


def _target(word: str) -> str:
    """A ``read``/``mapfile`` target name, or UNFOLLOWED when it is not one."""
    name = _literal(word)
    return name if IDENTIFIER.fullmatch(name) else UNFOLLOWED


def _names_read(arguments: list[str]) -> list[str]:
    """Return the variables ``read ARGUMENTS`` sets (``-a NAME`` included).

    Quoted literal names count as names; any other target is UNFOLLOWED.
    """
    names: list[str] = []
    rest = iter(arguments)
    for word in rest:
        if word.startswith(("<", ">")):
            break
        if word.startswith("-") and word[-1] in READ_FLAGS_WITH_ARGUMENT:
            argument = next(rest, "")
            if word[-1] == "a":
                names.append(_target(argument))
        elif not word.startswith("-"):
            names.append(_target(word))
    return names


#: ``mapfile``/``readarray`` options that take an argument.
MAPFILE_FLAGS_WITH_ARGUMENT = frozenset("dnOsuCc")


def _names_mapped(arguments: list[str]) -> list[str]:
    """Return the array ``mapfile ARGUMENTS`` sets (MAPFILE by default)."""
    rest = iter(arguments)
    for word in rest:
        if word.startswith(("<", ">")):
            break
        if word.startswith("-") and word[-1] in MAPFILE_FLAGS_WITH_ARGUMENT:
            next(rest, "")
        elif not word.startswith("-"):
            return [_target(word)]
    return ["MAPFILE"]


def _read_site(code: str) -> tuple[list[str], list[str], str] | None:
    """Find a ``read``, ``mapfile`` or ``readarray`` in ``code``.

    Every pipeline stage of every command is looked at, so ``jq ... | while
    IFS= read -r line`` counts; ``read -a NAME`` and ``mapfile NAME`` name the
    array they set.

    Returns:
        ``(names set, pipeline stages before it, its own stage)``, or ``None``.
    """
    for part in _command_lists(code):
        stages = _split_top(part, "|")
        for index, stage in enumerate(stages):
            words = _command_words(stage)
            if words and words[0] == "read":
                return _names_read(words[1:]), stages[:index], stage
            if words and words[0] in {"mapfile", "readarray"}:
                return _names_mapped(words[1:]), stages[:index], stage
    return None


def _read_names(code: str) -> list[str] | None:
    """Return the variables a ``read`` or ``mapfile`` in ``code`` sets, if any."""
    site = _read_site(code)
    return None if site is None else site[0]


def _read_taint(code: str, tainted: dict[str, str], line: int) -> str | None:
    """Return where a ``read``/``mapfile`` in ``code`` takes its input, or ``None``.

    Trusted input: a here-string of values that are not untrusted, a process
    substitution or pipe that is all sanitiser output (``SANITISED`` after
    blanking). A file, any other pipe or process substitution, or the
    script's own stdin is file content.
    """
    uses = sorted(name for name in tainted if _ref(name).search(code))
    if uses:
        return tainted[uses[0]]
    site = _read_site(code)
    before, own = (site[1], site[2]) if site else ([], code)
    if before:
        sanitised = all(stage.strip() == "SANITISED" for stage in before)
        return None if sanitised else f"input read at line {line}"
    unquoted = QUOTED.sub("''", own)
    if re.search(r"(?<!<)<\s*SANITISED\b", unquoted) and not _reads(own):
        return None
    if "<<<" in own and not _reads(own) and not _inline_reader(own):
        return None
    return f"input read at line {line}"


def _harmless(
    code: str,
    ref: re.Pattern[str],
    name: str,
    fds: frozenset[str] = frozenset(),
) -> bool:
    """Tell whether a use of ``name`` in ``code`` never reaches the comment."""
    rest = _strip_keywords(code)
    first = rest.split()[0] if rest.split() else ""
    if first in {"[[", "[", "test"} or rest.startswith("case "):
        return ref.search(TESTED.sub("", rest)) is None
    printed = first in {"echo", "printf"} and LOG_PRINT.match(rest) is not None
    # A log line redirected into a file (the comment file, say) is no log line.
    logged = first in LOG_COMMANDS or rest.endswith(">&2") or printed
    # After exec >file every print without >&2 goes to the file too.
    to_stdout = "1" in fds and not rest.endswith(">&2")
    log = logged and not _writes(rest, fds) and not to_stdout
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


def _judge(
    statement: Statement,
    code: str,
    tainted: dict[str, str],
    fds: frozenset[str] = frozenset(),
) -> str | None:
    """Return why a non-assignment statement is an offence, or ``None``."""
    if _reviewed(statement):
        return None
    inline = _inline_reader(code)
    if inline and (statement.heredoc or not _harmless(code, NEVER, "_", fds)):
        return f"file content read in: {statement.code}"
    if not statement.heredoc and _reads(code) and _writes(code, fds):
        return f"file content written to a file: {statement.code}"
    for name in sorted(tainted):
        ref = _ref(name)
        harmless = not statement.heredoc and _harmless(code, ref, name, fds)
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


class _Unfollowed(Exception):
    """A statement the analysis cannot follow; reported as an offence."""


def _bind_read(
    statement: Statement,
    code: str,
    tainted: dict[str, str],
    names: tuple[str, ...],
) -> bool:
    """Taint what a ``read``/``mapfile`` statement sets; tell whether it was one.

    Each name is bound to the statement's input, never to a constant; a
    listed variable stays untrusted whatever it reads.
    """
    read = _read_names(code)
    if read is None:
        return False
    if UNFOLLOWED in read:
        what = "a read or mapfile target the guard cannot follow"
        raise _Unfollowed(f"{what}: {statement.code}")
    source = None
    if not _reviewed(statement):
        source = _read_taint(code, tainted, statement.line)
    for name in sorted(set(read) - set(names)):
        if source is None:
            tainted.pop(name, None)
        else:
            tainted[name] = source
    return True


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
    fds: set[str] = set()  # descriptors exec opened on a file
    for statement in statements(text):
        unknown = _unclassifiable(statement)
        if unknown:
            found.append(f"{where}:{statement.line}: {unknown}")
            continue
        if not statement.heredoc:
            tainted = branches.step(statement.code, tainted)
            fds |= _exec_opens(statement.code)
        code = blank_sanitised(statement.code)
        if not statement.heredoc and not _reviewed(statement) and _hidden_write(code):
            why = f"file content written to a file: {statement.code}"
            found.append(f"{where}:{statement.line}: {why}")
            continue
        number = NUMBER_READ.match(_strip_keywords(statement.code))
        if number and not statement.heredoc:
            # comment_read_count/decimal VAR ... sets VAR to a checked number.
            tainted.pop(number.group(1), None)
            continue
        try:
            if not statement.heredoc and _bind_read(statement, code, tainted, names):
                continue
        except _Unfollowed as unfollowed:
            found.append(f"{where}:{statement.line}: {unfollowed}")
            continue
        bound = None if statement.heredoc else _binding(code)
        if bound:
            if bound[0] not in names:  # a listed variable stays untrusted
                _track(tainted, bound, statement)
            continue
        reason = _judge(statement, code, tainted, frozenset(fds))
        if reason:
            found.append(f"{where}:{statement.line}: {reason}")
    return found
