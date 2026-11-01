# SPDX-License-Identifier: MIT
"""Conservative source normalization and in-memory local dependency resolution."""

from __future__ import annotations

import hashlib
import io
import json
import posixpath
import re
import tokenize
from dataclasses import dataclass
from typing import Any

import yaml
from duplication_python import (
    python_path_parameters,
    runner_file_reference,
    uninspected_python_imports,
)

SCRIPT_CALL = re.compile(
    r"(?:\.?/?[\w.${}-]+/)*(?:scripts|\.github/scripts)/[\w./-]+"
    r"|(?:[\w.${}/-]+/)?[\w.-]+\.(?:sh|bash|py|js|mjs|cjs|ts|rb|pl|ps1)\b"
)

# This is a bounded set of recognizable command positions, not a shell parser.
# The same positions/wrappers must guard directory changes and executable paths.
SHELL_POSITION = r"(?:^|[;&|\n(){}])\s*(?:(?:if|then|else|elif|do|while|until|!)\s+)*"
COMMAND_START = (
    SHELL_POSITION + r"(?:(?:sudo|nohup|command|builtin|env|exec|time)\s+"
    r"|[A-Za-z_]\w*=[^\s;&|]+\s+)*"
)
RUNNER = r"(?:(?P<runner>uv|bun)\s+run\s+|timeout\s+\d+(?:\.\d+)?[smhd]?\s+)?"
INTERPRETER = r"(?:bash|sh|zsh|python[\d.]*|node|ruby|perl|pwsh|source|\.)\s+"
INTERPRETER_FLAGS = (
    r"(?:(?:-[efuvxn]*o\s+(?:pipefail|errexit|nounset)"
    r"|-[efuvxnBIESO]+|--(?:noprofile|norc))\s+)*"
)
# Only recognize bounded file-execution templates; other custom shells stay
# opaque. The full declaration is retained separately, including paths/flags.
SHELL_TEMPLATE = re.compile(
    r"(?:(?:/usr)?/bin/)?(?:bash|sh)\s+" + INTERPRETER_FLAGS + r"\{0\}",
)
PYTHON_TEMPLATE = re.compile(
    r"(?:(?:/usr)?/bin/)?python(?:\d+(?:\.\d+)*)?(?:\s+-[BIESOus]+)*\s+\{0\}"
)
COMMAND_PREFIX = "".join(
    (
        r"(?P<prefix>",
        COMMAND_START,
        RUNNER,
        r"(?:",
        INTERPRETER,
        INTERPRETER_FLAGS,
        r")?)",
    )
)
LOCAL_PROGRAM = re.compile(
    COMMAND_PREFIX + r"(?P<quote>['\"])?(?P<path>"
    r"(?(quote)[^'\"\n]+/[^'\"\n]+|[\w.${}/-]+/[\w.${}/-]+))"
    r"(?(quote)(?P=quote))"
)
DYNAMIC_PROGRAM = re.compile(
    COMMAND_PREFIX + r"(?P<quote>['\"])?(?P<path>"
    r"(?:\$\{\{.*?\}\}|\$\{[^}\n]+\}|\$\w+|\$[@*])(?:/[^\s'\";&|]+)*)"
    r"(?(quote)(?P=quote))"
)

INTERPRETED_PROGRAM = re.compile(
    r"(?P<prefix>" + COMMAND_START + RUNNER + INTERPRETER + INTERPRETER_FLAGS + r")"
    r"(?P<quote>['\"])?(?P<path>"
    r"(?(quote)[^'\"\n]+|[\w./][\w./-]*))(?(quote)(?P=quote))"
)
SCRIPT_PROGRAM = re.compile(
    "".join(
        (
            COMMAND_PREFIX,
            r"(?P<quote>['\"])?(?P<path>",
            SCRIPT_CALL.pattern,
            r")(?(quote)(?P=quote))",
        )
    )
)
DIRECTORY_CHANGE = re.compile(
    COMMAND_START + r"(?:!\s*)?" r"['\"]?(?:cd|pushd|popd)['\"]?(?=\s|$|[;&|)])"
)
# PATH selects executable implementations, including when changed on a prior
# line. Only command positions count; quoted echo/printf arguments are data.
PATH_CHANGE = re.compile(
    COMMAND_START + r"(?:(?:export|readonly|local|declare|typeset|unset)\s+"
    r"(?:(?:-[A-Za-z]+|[A-Za-z_]\w*(?:=[^\s;&|]+)?)\s+)*"
    r"['\"]?PATH(?=\+?=|['\"]?(?:\s|$|[;&|()]))|['\"]?PATH\+?=)"
)
# These builtins assign variables rather than merely consume data. Do not
# infer their destinations (which can be dynamic, arrays or namerefs): PATH
# may remain exported after a write. In particular printf's leading -v option
# must be guarded before DATA_COMMAND can hide it and its path arguments.
VARIABLE_WRITE = re.compile(
    COMMAND_START
    + r"""(?:printf\s+(?:\\?-\\?v[^\s;&|]*|'-v[^']*'|"-v[^"]*")"""
    + r"(?=\s|$|[;&|()])|(?:read|mapfile|readarray|getopts|let)(?=\s|$|[;&|()]))"
)
# Runner-file references can mutate executable selection in later steps or
# transfer the filename through aliases, pipes and unknown programs. Inspect
# every active reference before data-command exemptions, without modeling flow.
RUNNER_PATH_REFERENCE = re.compile(
    r"\$(?:GITHUB_(?:PATH|ENV)\b|\{GITHUB_(?:PATH|ENV)(?!\w)[^}\n]*\})"
)
INDIRECT_REFERENCE = re.compile(r"\$\{!")
FORWARDED_ARGUMENT = re.compile(r"\$(?:\w+|[@*]|\{[^{}\n]+\})")
INLINE_PROGRAM = re.compile(
    COMMAND_START + RUNNER + r"(?:(?:bash|sh|zsh|python[\d.]*|node|ruby|perl|pwsh)\s+"
    r"(?:-\w+\s+)*-\w*[ce]\b|eval\b)"
)
# Only bounded, data-only parameter expansions can be skipped as literals.
# Nested syntax, escapes, quotes and substitutions require shell parsing.
SHELL_PARAMETER = r"""\$\{[^{}<>\n\\'"`$]*\}"""
# // and /* are ordinary shell words. Only $(( proves arithmetic under both
# sh and bash: bare (( may instead open two POSIX subshells with a heredoc.
# Escaped-quote desync is also guarded by concatenated_shell_word below.
HEREDOC = re.compile(
    r"(?P<literal>" + SHELL_PARAMETER + r"|\$\(\([\w \t+*/%<>=!&|^~?:.-]*\)\)|"
    r""""(?:\\.|[^"\\])*"|"""
    r"""'[^']*'|(?<!\\\s)(?<!\S)\#[^\n]*)|<<""",
    re.S,
)

# Ignore proven data arguments only when checking for unresolved executables.
# Quoted separators remain part of the argument, never new command positions.
# Python -m executes uninspected modules and must reach the wrapper guard.
ARGUMENTS = "".join(
    (
        r"(?:",
        SHELL_PARAMETER,
        r"""|[^\n;&|(){}'"#]|"(?:\\.|[^"\\])*"|'[^']*')*""",
    )
)
DATA_COMMAND_NAME = r"(?:echo|cat|printf|ls|test|\[)"
DATA_COMMAND = re.compile(
    "".join(
        (
            COMMAND_START,
            DATA_COMMAND_NAME,
            r"(?=\s|$)",
            ARGUMENTS,
        )
    )
)
# tee copies stdin; true/false ignore it. Runner files have a separate guard.
PIPE_CONSUMER = re.compile(
    COMMAND_START + r"(?:" + DATA_COMMAND_NAME + r"|tee|true|false)(?=\s|$)" + ARGUMENTS
)
PIPE_OPERATOR = re.compile(r"\|")
PROCESS_SUBSTITUTION = re.compile(r"[<>]\(")
QUOTED_COMMAND = re.compile(
    COMMAND_START + RUNNER + r"""(?:'[^']*'|"(?:\\.|[^"\\])*")(?=\s|$|[;&|()<>])"""
)
GH_API = re.compile(COMMAND_START + r"""(?:gh|'gh'|"gh")\s+api(?=\s|$|[;&|()<>])""")
HTTP_CLIENT = re.compile(
    COMMAND_START
    + r"""(?P<quote>['"])?(?:curl|wget|http|https)(?(quote)(?P=quote))"""
    + r"(?=\s|$|[;&|()<>])"
)
RESOLVED_COMMAND = re.compile(
    COMMAND_PREFIX + r"<(?:script|unresolved-script):[a-f0-9]+>" + ARGUMENTS
)
UNSUPPORTED_WRAPPER = re.compile(
    SHELL_POSITION + r"(?:[A-Za-z_]\w*=[^\s;&|]+\s+)*"
    r"(?:sudo|nohup|command|builtin|env|exec|time|uv|bun|timeout|xargs|"
    r"bash|sh|zsh|python[\d.]*|node|ruby|perl|pwsh|source)(?=\s|$)"
)
UNRESOLVED_PATH = re.compile(SCRIPT_CALL.pattern + r"|[\w.${}/-]+/[\w.${}/-]+")
EXPRESSION = re.compile(r"\$\{\{.*?\}\}", re.S)
# Expression identifiers are case insensitive. Skip literal expression strings,
# but recognize both dot and literal-index access before shell quoting applies.
RUNNER_CONTEXT = re.compile(
    r"'(?:''|[^'])*'|(?P<reference>\bgithub\s*"
    r"(?:\.\s*(?:path|env)\b|\[\s*'(?:path|env)'\s*\]))",
    re.I,
)
SHELL_EXPRESSION = re.compile(r"\$\{[^{}]*\}|\$\(\(.*?\)\)", re.S)
PYTHON_FSTRING = re.compile(r"(?i)(?:f|fr|rf)['\"]")
SAFE_INPUTS = {
    "actions/setup-python": {"python-version"},
    "actions/setup-node": {"node-version"},
    "astral-sh/setup-uv": {"version", "python-version"},
}
LEXEME = re.compile(
    r""""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|(?P<comment>(?<!\S)\#[^\n]*|"""
    r"""//[^\n]*|/\*.*?\*/)|[^\S\n]+|\n|[^\s'"]+""",
    re.S,
)
# Keep non-shell comment semantics above. Shell expansions must start a token
# even inside an assignment; otherwise its whitespace-# could start a comment.
# Unsupported expansions fail closed before any shell source is transformed.
SHELL_LEXEME = re.compile(
    r"(?P<parameter>" + EXPRESSION.pattern + "|" + SHELL_PARAMETER + r")|"
    r"""(?P<quoted>"(?:\\.|[^"\\])*"|'[^']*')|"""
    r"(?P<comment>(?<!\\\s)(?<!\S)\#[^\n]*)|(?P<unsupported>\$\{)|"
    r"""[^\S\n]+|\n|(?:(?!\$\{)[^\s'"])+""",
    re.S,
)


def runner_context_reference(value: Any) -> bool:
    """Find runner-file expressions in execution metadata without evaluating it."""
    if isinstance(value, dict):
        return any(runner_context_reference(item) for item in value.values())
    if isinstance(value, list):
        return any(runner_context_reference(item) for item in value)
    return isinstance(value, str) and any(
        marker["reference"]
        for expression in EXPRESSION.finditer(value)
        for marker in RUNNER_CONTEXT.finditer(expression.group()[3:-2])
    )


def executable_matches(pattern: re.Pattern[str], source: str) -> list[re.Match[str]]:
    """Exclude command-like text inside quoted arguments and comments."""
    literals = []
    characters = list(source)
    for lexeme in SHELL_LEXEME.finditer(source):
        if lexeme.lastgroup in {"quoted", "parameter"}:
            literals.append((lexeme.start(), lexeme.end()))
        elif lexeme.lastgroup == "comment":
            # A comment's trailing operator must not consume the next command
            # boundary. Mask only its span so offsets into source stay intact,
            # including characters the bounded lexer does not recognize.
            characters[lexeme.start() : lexeme.end()] = " " * len(lexeme.group())
    source = "".join(characters)
    return [
        match
        for match in pattern.finditer(source)
        if not any(start < match.start() < end for start, end in literals)
    ]


def ambiguous_executable(source: str) -> bool:
    """Fail closed when bounded recognition leaves a possible executable path."""
    lexemes = SHELL_LEXEME.finditer(source)
    source = "".join(match.group() for match in lexemes if match.lastgroup != "comment")
    for pattern in (DATA_COMMAND, RESOLVED_COMMAND):
        for match in reversed(executable_matches(pattern, source)):
            source = source[: match.start()] + "\n" + source[match.end() :]
    wrappers = executable_matches(UNSUPPORTED_WRAPPER, source)
    return bool(wrappers or UNRESOLVED_PATH.search(source))


def shell_escaped(source: str, start: int) -> bool:
    """Count escapes against original offsets, including lexeme boundaries."""
    offset = start
    while offset > 0 and source[offset - 1] == "\\":
        offset -= 1
    return (start - offset) % 2 != 0


def active_shell_reference(pattern: re.Pattern[str], source: str) -> bool:
    """Find expanded references, including inside double-quoted arguments."""
    for lexeme in SHELL_LEXEME.finditer(source):
        text = lexeme.group()
        if lexeme.lastgroup == "comment" or text.startswith("'"):
            continue
        for marker in pattern.finditer(text):
            # Parameters can start a separate lexeme after an escape. Count
            # backslashes in the original source, retaining that boundary.
            if not shell_escaped(source, lexeme.start() + marker.start()):
                return True
    return False


def unproven_pipeline(source: str) -> bool:
    """Only proven data consumers may receive a pipeline's output.

    Unknown stdin consumers may execute data, regardless of their command name.
    Grouped consumers stay opaque: their input/control flow is not modeled.
    """
    pipes = {
        match.start()
        for match in executable_matches(PIPE_OPERATOR, source)
        if not shell_escaped(source, match.start())
    }
    for start in pipes:
        # >| is a redirection, unless its > was escaped into ordinary data.
        if source[start - 1 : start] == ">" and not shell_escaped(source, start - 1):
            continue
        # || joins commands without forwarding stdin. Escaped/quoted pipes
        # are absent from the set, so cannot conceal an adjacent active pipe.
        if start - 1 in pipes or start + 1 in pipes:
            continue
        end = start + (2 if source[start + 1 : start + 2] == "&" else 1)
        if not PIPE_CONSUMER.match(source[end:]):
            return True
    return False


def unproven_forwarding(source: str) -> bool:
    """Only proven data commands may consume expanded argument lists or scalars.

    Unknown programs can execute their arguments regardless of their names or
    options. Check before script replacement: RESOLVED_COMMAND masks arguments
    for path checks but cannot prove that forwarded inputs are inert.
    """
    for match in reversed(executable_matches(DATA_COMMAND, source)):
        source = source[: match.start()] + "\n" + source[match.end() :]
    return active_shell_reference(FORWARDED_ARGUMENT, source)


def concatenated_shell_word(source: str) -> bool:
    """Keep adjacent quoted/unquoted fragments opaque without interpreting them."""
    for match in SHELL_LEXEME.finditer(source):
        if match.lastgroup != "quoted":
            continue
        # Whitespace and shell operators delimit words. Quotes next to any
        # other character may concatenate, including empty quoted fragments.
        neighbors = source[max(0, match.start() - 1) : match.start()]
        neighbors += source[match.end() : match.end() + 1]
        if any(not char.isspace() and char not in ";&|()<>" for char in neighbors):
            return True
    return False


def unsupported_shell_expansion(lexeme: re.Match[str]) -> bool:
    """Quoted tokens cannot conceal an expansion beyond the bounded form."""
    if lexeme.lastgroup == "unsupported":
        return True
    text = lexeme.group()
    if lexeme.lastgroup != "quoted" or not text.startswith('"'):
        return False
    return any(
        not shell_escaped(text, marker.start())
        and not re.match(SHELL_PARAMETER, text[marker.start() :])
        and not EXPRESSION.match(text, marker.start())
        for marker in re.finditer(r"\$\{", text)
    )


def shell_opacity(source: str) -> str | None:
    """Identify unsupported syntax before transforming shell source."""
    # Continuation removal depends on quote/comment context. Until that is
    # parsed, no guard or dependency lookup may use the physical lines.
    if "\\\n" in source:
        return "shell-continuation"
    lexemes = SHELL_LEXEME.finditer(source)
    if any(unsupported_shell_expansion(match) for match in lexemes):
        return "shell-expansion"
    # Heredoc payloads are literal data, even when they look like comments
    # or script calls. Delimiter parsing is outside this bounded scanner.
    if any(match["literal"] is None for match in HEREDOC.finditer(source)):
        return "heredoc"
    # Modified PATH lookup and API endpoints/payloads are executable behavior,
    # not filesystem inputs. Keep the whole block opaque before dependency
    # resolution can assume the usual executable selection or mask path inputs.
    for matches, kind in (
        (executable_matches(PATH_CHANGE, source), "path"),
        (
            any(
                not shell_escaped(source, match.start())
                for match in executable_matches(VARIABLE_WRITE, source)
            ),
            "path",
        ),
        (active_shell_reference(RUNNER_PATH_REFERENCE, source), "path"),
        (runner_context_reference(source), "path"),
        (active_shell_reference(INDIRECT_REFERENCE, source), "indirection"),
        (executable_matches(GH_API, source), "gh-api"),
        (
            any(
                not shell_escaped(source, match.start())
                for match in executable_matches(PROCESS_SUBSTITUTION, source)
            ),
            "process-substitution",
        ),
    ):
        if matches:
            return kind
    opacity = "forwarding" if unproven_forwarding(source) else None
    # HTTP clients may receive dynamic endpoints or payloads. URL arguments
    # can also reach them through local scripts. Until request semantics are
    # modeled, retain the entire source before resolving scripts or masking
    # filesystem paths; URL paths, queries and payloads are not path inputs.
    if executable_matches(HTTP_CLIENT, source) or any(
        re.search(r"[a-z][a-z0-9+.-]*://", match.group(), re.I)
        for match in SHELL_LEXEME.finditer(source)
        if match.lastgroup != "comment"
    ):
        return "http"
    return "pipeline" if unproven_pipeline(source) else opacity


def shell_words(source: str) -> tuple[str, ...]:
    """Rejoin adjacent lexemes when tokenizing an already normalized script."""
    # The guard lexer isolates parameters so their whitespace-# stays literal.
    # Those lexical boundaries are not shell word boundaries: ${dir}/* and
    # ${a}${b} each remain one word. Only intervening spacing separates words.
    words: list[str] = []
    previous_end = -1
    for match in SHELL_LEXEME.finditer(source):
        if match.group().isspace():
            continue
        if match.start() == previous_end:
            words[-1] += match.group()
        else:
            words.append(match.group())
        previous_end = match.end()
    return tuple(words)


def normalize(
    source: str,
    repository: str,
    *,
    version_parameter: bool = False,
    shell_source: bool = False,
) -> str:
    """Remove comments/spacing and mask repository, image, path and version literals.

    Keep command names, flags, operators, conditions and string contents unless
    they are recognizable parameters. Version masking requires an explicit
    parameter context; decimal command arguments, including quoted ones, are
    executable behavior. Quoted shell programs are not collapsed.
    """
    lexer = SHELL_LEXEME if shell_source else LEXEME
    lexemes = lexer.finditer(source)
    source = "".join(match.group() for match in lexemes if match.lastgroup != "comment")
    # A direct value is a parameter. Embedded selectors/conditions are logic;
    # masking the whole expression would hide different command branches.
    source = EXPRESSION.sub(
        lambda match: (
            "<input>"
            if re.fullmatch(
                r"\$\{\{\s*[\w.-]+\s*\}\}",
                match.group(),
            )
            else match.group()
        ),
        source,
    )
    # Slash operators inside shell expansions and GitHub expressions are logic.
    expressions: list[str] = []

    def protect(match: re.Match[str]) -> str:
        expressions.append(match.group())
        return f"LGTMEXPRESSION{len(expressions) - 1}TOKEN"

    source = EXPRESSION.sub(protect, source)
    source = SHELL_EXPRESSION.sub(protect, source)
    # Mask image tags before repository placeholders break their literal syntax.
    source = re.sub(r"\b(?:ghcr\.io|docker\.io)/[\w./:@-]+", "<image>", source)
    source = source.replace(repository, "<repository>")
    source = re.sub(r"([\w.-]+/[\w./-]+)@[a-fA-F0-9]{40}\b", r"\1", source)
    source = re.sub(r"(?<![\w])(?:\./|\.\./|/)[\w./${}-]+", "<path>", source)
    source = re.sub(r"\b[\w.-]+/[\w./-]+(?:\.[\w-]+)?\b", "<path>", source)
    if version_parameter:
        source = re.sub(r"\b\d+(?:\.\d+)+(?:[\w.+-]*)\b", "<version>", source)
    tokens: list[str] = []
    for match in lexer.finditer(source):
        lexeme = match.group()
        if lexeme == "\n":
            if tokens and tokens[-1] != "<newline>":
                tokens.append("<newline>")
            continue
        if lexeme.isspace() or match.lastgroup == "comment":
            continue
        tokens.append(lexeme)
    if tokens and tokens[-1] == "<newline>":
        tokens.pop()
    result = " ".join(tokens)
    for index, expression in enumerate(expressions):
        result = result.replace(f"LGTMEXPRESSION{index}TOKEN", expression)
    return result


def command_shape(
    source: str,
    repository: str,
    files: dict[str, str],
    visited: frozenset[str] = frozenset(),
) -> str:
    """Compare called script bodies, never collapse executable paths to inputs.

    Two jobs that both run ``bash scripts/check.sh`` may do entirely different
    work. Resolve exact repository-relative paths without executing scripts;
    bare names have no known working directory, so retain their identity.
    """

    return SourceResolver(repository, files).command(source, visited=visited)


def script_shape(
    path: str,
    source: str,
    repository: str,
    files: dict[str, str],
    visited: frozenset[str] = frozenset(),
) -> tuple[str, ...]:
    """Retain Python indentation and shell command boundaries as control flow."""
    return SourceResolver(repository, {**files, path: source}).script(
        path,
        visited=visited,
    )


@dataclass(frozen=True)
class ScriptExecution:
    """Keep direct, interpreter and runner identity together for script caching."""

    direct: bool = True
    interpreter: str | None = None
    runner: str | None = None


class SourceResolver:
    """Resolve local dependencies in memory, with per-inventory memoization."""

    def __init__(self, repository: str, files: dict[str, str]) -> None:
        self.repository = repository
        self.files = files
        self.scripts: dict[
            tuple[str, str, ScriptExecution],
            tuple[str, ...],
        ] = {}
        self.actions: dict[str, Any] = {}

    def unknown(self, kind: str, path: str) -> str:
        """Uninspected logic must never establish equality across repositories."""
        digest = hashlib.sha256(
            json.dumps([self.repository, path]).encode(),
        ).hexdigest()
        return f"<unresolved-{kind}:{digest}>"

    def run(
        self,
        source: str,
        shell: Any,
        directory: str,
        visited: frozenset[str],
    ) -> str | tuple[str, ...]:
        """Choose normalization from the effective shell without executing it."""
        if isinstance(shell, str):
            shell_template = SHELL_TEMPLATE.fullmatch(shell)
            if shell in {"<implicit-shell>", "bash", "sh"} or shell_template:
                return self.command(source, directory, visited)
            if shell == "python" or PYTHON_TEMPLATE.fullmatch(shell):
                return self.python(source)
        # Dynamic expressions and unsupported languages cannot establish
        # equivalence, even when their source happens to look like shell code.
        return self.unknown("run-shell", str((shell, source)))

    def command(
        self, source: str, directory: str = "", visited: frozenset[str] = frozenset()
    ) -> str:
        """Resolve explicit executable paths before masking literal path inputs."""
        opacity = shell_opacity(source)
        if opacity is not None:
            return self.unknown(opacity, source)
        if concatenated_shell_word(source):
            return self.unknown("shell-word", source)
        # Directory-changing shell control flow is not modeled. Keep the whole
        # block opaque rather than inspecting a script from the wrong directory.
        if executable_matches(DIRECTORY_CHANGE, source):
            return self.unknown("directory", source)
        # Quoted arguments can contain executable substitutions or programs
        # passed to an interpreter. Their command positions need a shell parser.
        substitutions = any(
            re.search(r"\$\((?!\()|`", match.group())
            for match in SHELL_LEXEME.finditer(source)
            if match.lastgroup != "comment" and not match.group().startswith("'")
        )
        if (
            substitutions
            or executable_matches(INLINE_PROGRAM, source)
            or executable_matches(QUOTED_COMMAND, source)
        ):
            return self.unknown("shell-command", source)

        def replace(match: re.Match[str]) -> str:
            name = match["path"]
            workspace = ("${GITHUB_WORKSPACE}/", "$GITHUB_WORKSPACE/")
            rooted = name.startswith(workspace)
            for prefix in workspace:
                name = name.removeprefix(prefix)
            path = posixpath.normpath(posixpath.join("" if rooted else directory, name))
            if path not in self.files or path in visited:
                return self.unknown("script", path)
            # An explicit interpreter (including source/.) ignores a shebang.
            # Runner dispatch is distinct from direct kernel/shell execution.
            # Do not mistake an assignment suffix for an interpreter word.
            interpreter = re.search(
                r"(?:^|\s)(?P<interpreter>" + INTERPRETER + INTERPRETER_FLAGS + r")$",
                match["prefix"],
            )
            effective = "<implicit-shell>"
            if interpreter:
                effective = interpreter["interpreter"].strip()
            body = self.script(
                path,
                directory,
                visited,
                execution=ScriptExecution(
                    direct=interpreter is None and match["runner"] is None,
                    interpreter=effective,
                    runner=match["runner"],
                ),
            )
            digest = hashlib.sha256(str(body).encode()).hexdigest()
            return f"<script:{digest}>"

        patterns = (DYNAMIC_PROGRAM, LOCAL_PROGRAM, INTERPRETED_PROGRAM, SCRIPT_PROGRAM)
        for pattern in patterns:
            for match in reversed(executable_matches(pattern, source)):
                source = (
                    source[: match.start()]
                    + match["prefix"]
                    + replace(match)
                    + source[match.end() :]
                )
        if ambiguous_executable(source):
            return self.unknown("shell-command", source)
        return normalize(source, self.repository, shell_source=True)

    def python(self, source: str, path: str = "<inline>") -> tuple[str, ...]:
        """Retain Python tokens and reuse bounded dependency guards for run blocks."""
        ignored = {
            tokenize.COMMENT,
            tokenize.NL,
            tokenize.ENCODING,
            tokenize.ENDMARKER,
        }
        try:
            tokens = [
                item
                for item in tokenize.generate_tokens(io.StringIO(source).readline)
                if item.type not in ignored
            ]
            # Python 3.11 hides replacement fields in a single STRING token;
            # newer tokenizers expose FSTRING_START and expression tokens.
            # Until replacement fields/format specs share a modeled grammar,
            # neither family may normalize f-string code as path parameters.
            if any(
                tokenize.tok_name[item.type] == "FSTRING_START"
                or (item.type == tokenize.STRING and PYTHON_FSTRING.match(item.string))
                for item in tokens
            ):
                return (self.unknown("python-fstring", source),)
            # Runner filenames may escape through aliases or arbitrary writers.
            # Inspect decoded literals as well as names, ignoring comments;
            # no Python data flow or writer implementation is evaluated.
            if runner_file_reference(tokens):
                return (self.unknown("python-runner-file", source),)
            path_parameters = python_path_parameters(source, tokens)
            # Strings, constants and operators are logic by default. Only a
            # narrowly recognized literal filesystem argument is a parameter.
            shape = tuple(
                (
                    f"{item.type}:{item.string}"
                    if item.type in {tokenize.STRING, tokenize.NUMBER, tokenize.OP}
                    and item.start not in path_parameters
                    else f"{item.type}:{normalize(item.string, self.repository)}"
                )
                for item in tokens
            )
            if uninspected_python_imports(source, self.files):
                shape += (self.unknown("python-import", path),)
            # Python strings are not shell command positions.
            # Keep launchers, executable selection and runpy opaque until their
            # dependencies can be resolved, including aliases/computed targets.
            # Treat any runpy reference conservatively: indirect attribute
            # access and imported aliases need no separate data-flow parser.
            # Dynamic imports may load runpy under a computed name as well.
            # Dynamic evaluation also treats normalized strings as code.
            names = {
                item.string  # Inspect code names, never string contents.
                for item in tokens
                if item.type == tokenize.NAME
            }
            # Reflective lookup can hide launcher names behind strings,
            # expressions, namespaces or aliases. Co-occurring code names
            # suffice to fail closed; this bounded guard does not attempt
            # arbitrary Python data-flow resolution.
            if (
                (
                    names
                    & {
                        "os",
                        "posix",
                        "nt",
                        "asyncio",
                        "multiprocessing",
                        "pty",
                        "sys",
                        "modules",
                        "builtins",
                        "__builtins__",
                    }
                    and names
                    & {
                        "getattr",
                        "__getattribute__",
                        "vars",
                        "__dict__",
                        "attrgetter",
                        "methodcaller",
                        "globals",
                        "locals",
                    }
                )
                or names & {"__builtins__", "ctypes", "webbrowser"}
                or any(
                    re.fullmatch(
                        r"\w*subprocess\w*|system|popen|startfile|exec\w*|"
                        r"eval|compile|spawn\w*|set_executable|"
                        r"posix_spawn\w*|"
                        r"runpy|run_path|run_module|"
                        r"__import__|importlib|import_module",
                        name,
                    )
                    for name in names
                )
            ):
                shape += (self.unknown("python-command", source),)
        except (SyntaxError, tokenize.TokenError):
            raise ValueError(f"invalid Python source: {path}") from None
        return shape

    def script(
        self,
        path: str,
        directory: str = "",
        visited: frozenset[str] = frozenset(),
        *,
        execution: ScriptExecution | None = None,
    ) -> tuple[str, ...]:
        """Keep quoted whitespace, Python indentation and shell boundaries."""
        execution = execution or ScriptExecution()
        key = (path, directory, execution)
        if key in self.scripts:
            return self.scripts[key]
        direct = execution.direct
        interpreter = execution.interpreter
        runner = execution.runner
        # A bare runner can dispatch by suffix, shebang or package metadata;
        # none establishes shell execution. Bun can also select package scripts
        # ahead of an explicit interpreter word. Keep these contexts opaque.
        # uv with an explicit interpreter uses the existing bounded templates.
        if runner and (runner != "uv" or interpreter in {None, "<implicit-shell>"}):
            shape: tuple[str, ...] = (
                self.unknown("script-runner", str((path, runner, interpreter))),
            )
            self.scripts[key] = shape
            return shape
        source = self.files[path]
        visited = visited | {path}
        shebang = source.split("\n", 1)[0] if direct and source.startswith("#!") else ""
        if shebang:
            interpreter = shebang[2:].strip()
            # env receives a single kernel argument. Options or multiple words
            # require semantics outside our bounded file-execution templates.
            env = re.fullmatch(r"/(?:usr/)?bin/env\s+(\w[\w.]*)", interpreter)
            if env:
                interpreter = env[1]
            elif not re.fullmatch(r"/(?:usr/)?bin/\w[\w.]*(?:\s+\S+)?", interpreter):
                interpreter = "<unknown-shebang>"
        elif interpreter is None:
            # Standalone inventory units have no invocation. Preserve their
            # conventional suffix inference only when no shebang overrides it;
            # command() always supplies the actual execution context instead.
            interpreter = "python" if path.endswith(".py") else "sh"
        if interpreter and PYTHON_TEMPLATE.fullmatch(interpreter + " {0}"):
            shape = self.python(source, path)
        elif interpreter in {"<implicit-shell>", "source", "."} or (
            interpreter and SHELL_TEMPLATE.fullmatch(interpreter + " {0}")
        ):
            normalized = self.command(source, directory, visited)
            shape = shell_words(normalized)
        else:
            shape = (self.unknown("script-interpreter", str((path, interpreter))),)
        if shebang:
            # Preserve the declaration literally; do not resolve env or execute
            # an interpreter to infer its behavior. It is not a path parameter.
            shape = (shebang, *shape)
        self.scripts[key] = shape
        return shape

    def action(self, target: str, visited: frozenset[str]) -> Any:
        """Expand composite local actions; opaque implementations stay unknown."""
        path = posixpath.normpath(target)
        if path in visited:
            return self.unknown("action", path)
        if path in self.actions:
            return self.actions[path]
        for extension in ("yml", "yaml"):
            source = self.files.get(f"{path}/action.{extension}")
            if source is None:
                continue
            data = yaml.safe_load(source)
            if not isinstance(data, dict):
                break
            runs = data.get("runs")
            if not isinstance(runs, dict) or runs.get("using") != "composite":
                break
            shape = {
                "inputs": data.get("inputs", {}),
                "outputs": data.get("outputs", {}),
                "runs": operation_shape(
                    runs,
                    self.repository,
                    self.files,
                    resolver=self,
                    visited=visited | {path},
                    context="action",
                ),
            }
            self.actions[path] = shape
            return shape
        return self.unknown("action", path)


def dependency_names(files: dict[str, str]) -> set[str]:
    """Identify additional blobs to read; suffix lookup only expands inventory."""
    names: set[str] = set()

    def commands(value: Any) -> list[str]:
        if isinstance(value, dict):
            result: list[str] = []
            for key, item in value.items():
                if key == "run" and isinstance(item, str):
                    result.append(item)
                else:
                    result.extend(commands(item))
            return result
        if isinstance(value, list):
            return [part for item in value for part in commands(item)]
        return []

    sources = list(files.values())
    for path, source in files.items():
        if path.endswith((".yml", ".yaml")):
            try:
                sources.extend(commands(yaml.safe_load(source)))
            except yaml.YAMLError:
                continue
    for source in sources:
        names.update(match.group() for match in SCRIPT_CALL.finditer(source))
        for pattern in (DYNAMIC_PROGRAM, LOCAL_PROGRAM, INTERPRETED_PROGRAM):
            names.update(match["path"] for match in pattern.finditer(source))
        for match in re.finditer(r"uses:\s*['\"]?(\./[\w./-]+)", source):
            names.update(f"{match[1]}/action.{ext}" for ext in ("yml", "yaml"))
    result: set[str] = set()
    for name in names:
        for prefix in ("${GITHUB_WORKSPACE}/", "$GITHUB_WORKSPACE/"):
            name = name.removeprefix(prefix)
        if any(character in name for character in "[*?"):
            continue
        parts = posixpath.normpath(name).split("/")
        while parts and parts[0] in {"", ".", ".."}:
            parts.pop(0)
        if parts:
            result.add("/".join(parts))
    return result


# Recursive YAML context keeps display scope, defaults, environment and cycles.
# pylint: disable-next=too-many-arguments,too-many-branches,too-many-locals
def operation_shape(
    value: Any,
    repository: str,
    files: dict[str, str],
    *,
    resolver: SourceResolver | None = None,
    defaults: dict[str, Any] | None = None,
    environment: dict[str, Any] | None = None,
    visited: frozenset[str] = frozenset(),
    context: str = "execution",
    opaque_context: bool = False,
) -> Any:
    """Keep execution metadata and unknown inputs; mask only known parameters."""
    # Output names and arbitrary user mappings are data. Never interpret their
    # reserved-looking keys as steps, action inputs, environments or defaults.
    if context == "data":
        return value
    resolver = resolver or SourceResolver(repository, files)

    def recurse(item: Any, child_context: str = "mapping") -> Any:
        return operation_shape(
            item,
            repository,
            files,
            resolver=resolver,
            defaults=defaults,
            environment=environment,
            visited=visited,
            context=child_context,
            opaque_context=opaque_context,
        )

    if isinstance(value, list):
        return [recurse(item, context) for item in value]
    if not isinstance(value, dict):
        if context == "mapping" and isinstance(value, str) and EXPRESSION.search(value):
            return value
        return normalize(str(value), repository)
    if context == "mapping":
        return {key: recurse(item) for key, item in value.items()}
    defaults = {**(defaults or {}), **run_defaults(value)}
    if "env" in value and not isinstance(value["env"], dict):
        raise ValueError("invalid environment mapping")
    environment = {**(environment or {}), **value.get("env", {})}
    # Env/input aliases can carry runner filenames to programs or later steps.
    # Outputs and names are data; nested steps inherit job opacity as well as
    # inspecting their own scope, including strategy/container/service context.
    opaque_context = (
        opaque_context
        or runner_context_reference(environment)
        or any(
            runner_context_reference(item)
            for key, item in value.items()
            if key not in {"name", "outputs", "steps"}
        )
    )
    result: dict[str, Any] = {}
    for key, item in value.items():
        if key == "name" or (key == "using" and context == "action"):
            continue
        if key == "steps":
            result[key] = recurse(item, "execution")
        elif key == "outputs":
            result[key] = recurse(item, "data")
        elif key in {"with", "env"}:
            if not isinstance(item, dict):
                raise ValueError("invalid action input or environment mapping")
            action = str(value.get("uses", "")).split("@", 1)[0].lower()
            result[key] = {
                str(name): (
                    "<parameter>"
                    if key == "with" and name in SAFE_INPUTS.get(action, set())
                    else parameter
                )
                for name, parameter in item.items()
            }
        elif key in {"uses", "run"} and opaque_context:
            result[key] = resolver.unknown("execution-context", str(value))
        elif key == "uses":
            # Retain action identity and subpath, discard mutable or SHA refs.
            target = str(item).split("@", 1)[0]
            if target.startswith("./"):
                result[key] = resolver.action(target, visited)
            else:
                result[key] = "/".join(
                    part.lower() if index < 2 else part
                    for index, part in enumerate(target.split("/", 2))
                )
        elif key == "run":
            directory = str(
                value.get(
                    "working-directory",
                    defaults.get("working-directory", ""),
                ),
            )
            shell = value.get("shell", defaults.get("shell", "<implicit-shell>"))
            result[key] = resolver.run(str(item), shell, directory, visited)
        elif key in {
            "if",
            "strategy",
            "continue-on-error",
            "needs",
            "permissions",
            "runs-on",
            "timeout-minutes",
            "defaults",
            "working-directory",
            "shell",
        }:
            # Conditional expressions are logic, not ordinary input values.
            result[key] = item
        else:
            result[key] = recurse(item)
    if "run" in value:
        result.setdefault("shell", defaults.get("shell", "<implicit-shell>"))
        if "working-directory" in defaults:
            result.setdefault("working-directory", defaults["working-directory"])
    if ("run" in value or "uses" in value) and environment:
        result["env"] = environment
    return result


def run_defaults(value: dict[str, Any]) -> dict[str, Any]:
    """Validate inherited run settings before following executable paths."""
    defaults = value.get("defaults", {})
    if not isinstance(defaults, dict):
        raise ValueError("invalid defaults.run mapping")
    settings = defaults.get("run", {})
    if not isinstance(settings, dict):
        raise ValueError("invalid defaults.run mapping")
    return settings
