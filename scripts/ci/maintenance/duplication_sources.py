# SPDX-License-Identifier: MIT
"""Conservative source normalization and in-memory local dependency resolution."""

from __future__ import annotations

import ast
import hashlib
import io
import json
import posixpath
import re
import sys
import tokenize
from typing import Any

import yaml

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
RUNNER = r"(?:(?:uv|bun)\s+run\s+|timeout\s+\d+(?:\.\d+)?[smhd]?\s+)?"
INTERPRETER = r"(?:bash|sh|zsh|python[\d.]*|node|ruby|perl|pwsh|source|\.)\s+"
INTERPRETER_FLAGS = (
    r"(?:(?:-[efuvxn]*o\s+(?:pipefail|errexit|nounset)"
    r"|-[efuvxnBIESO]+|--(?:noprofile|norc))\s+)*"
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
    r"(?:\$\{\{.*?\}\}|\$\{[^}\n]+\}|\$\w+)(?:/[^\s'\";&|]+)*)"
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
INLINE_PROGRAM = re.compile(
    COMMAND_START + RUNNER + r"(?:(?:bash|sh|zsh|python[\d.]*|node|ruby|perl|pwsh)\s+"
    r"(?:-\w+\s+)*-\w*[ce]\b|eval\b)"
)

# Ignore proven data arguments only when checking for unresolved executables.
# Quoted separators remain part of the argument, never new command positions.
# Python -m executes uninspected modules and must reach the wrapper guard.
ARGUMENTS = r"""(?:[^\n;&|(){}'"#]|"(?:\\.|[^"\\])*"|'[^']*')*"""
DATA_COMMAND = re.compile(
    "".join(
        (
            COMMAND_START,
            r"(?:echo|cat|printf|ls|test|\[|gh\s+api)",
            r"(?=\s|$)",
            ARGUMENTS,
        )
    )
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


SHELL_EXPRESSION = re.compile(r"\$\{[^{}]*\}|\$\(\(.*?\)\)", re.S)


SAFE_INPUTS = {
    "actions/setup-python": {"python-version"},
    "actions/setup-node": {"node-version"},
    "astral-sh/setup-uv": {"version", "python-version"},
}


LEXEME = re.compile(
    r"""("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|(?<!\S)\#[^\n]*|"""
    r"""//[^\n]*|/\*.*?\*/|[^\S\n]+|\n|[^\s'"]+)""",
    re.S,
)


def executable_matches(pattern: re.Pattern[str], source: str) -> list[re.Match[str]]:
    """Exclude command-like text inside quoted arguments and comments."""
    literals = [
        (match.start(), match.end())
        for match in LEXEME.finditer(source)
        if match.group().startswith(("'", '"', "#", "/*", "//"))
    ]
    return [
        match
        for match in pattern.finditer(source)
        if not any(start < match.start() < end for start, end in literals)
    ]


def ambiguous_executable(source: str) -> bool:
    """Fail closed when bounded recognition leaves a possible executable path."""
    source = "".join(
        match.group()
        for match in LEXEME.finditer(source)
        if not match.group().startswith(("#", "/*", "//"))
    )
    for pattern in (DATA_COMMAND, RESOLVED_COMMAND):
        for match in reversed(executable_matches(pattern, source)):
            source = source[: match.start()] + "\n" + source[match.end() :]
    wrappers = executable_matches(UNSUPPORTED_WRAPPER, source)
    return bool(wrappers or UNRESOLVED_PATH.search(source))


def normalize(source: str, repository: str, *, version_parameter: bool = False) -> str:
    """Remove comments/spacing and mask repository, image, path and version literals.

    Keep command names, flags, operators, conditions and string contents unless
    they are recognizable parameters. Version masking requires an explicit
    parameter context; decimal command arguments, including quoted ones, are
    executable behavior. Quoted shell programs are not collapsed.
    """
    source = "".join(
        match.group()
        for match in LEXEME.finditer(source)
        if not match.group().startswith(("#", "/*", "//"))
    )
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
    for match in LEXEME.finditer(source):
        lexeme = match.group()
        if lexeme == "\n":
            if tokens and tokens[-1] != "<newline>":
                tokens.append("<newline>")
            continue
        if lexeme.isspace() or lexeme.startswith(("#", "/*", "//")):
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


class SourceResolver:
    """Resolve local dependencies in memory, with per-inventory memoization."""

    def __init__(self, repository: str, files: dict[str, str]) -> None:
        self.repository = repository
        self.files = files
        self.scripts: dict[tuple[str, str], tuple[str, ...]] = {}
        self.actions: dict[str, Any] = {}

    def unknown(self, kind: str, path: str) -> str:
        """Uninspected logic must never establish equality across repositories."""
        digest = hashlib.sha256(
            json.dumps([self.repository, path]).encode(),
        ).hexdigest()
        return f"<unresolved-{kind}:{digest}>"

    def uninspected_python_imports(self, source: str) -> bool:
        """Only unshadowed stdlib imports have known external implementations.

        Local and third-party modules are not expanded. Even if their source
        is in the inventory, tokenizing the entrypoint alone cannot establish
        their behavior. Relative imports always depend on repository code.
        """
        try:
            tree = ast.parse(source)
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
            for path in self.files
            if path.endswith(".py")
            for part in path.removesuffix(".py").split("/")
        }
        return bool(modules - sys.stdlib_module_names or modules & local_names)

    def command(
        self, source: str, directory: str = "", visited: frozenset[str] = frozenset()
    ) -> str:
        """Resolve explicit executable paths before masking literal path inputs."""
        # Directory-changing shell control flow is not modeled. Keep the whole
        # block opaque rather than inspecting a script from the wrong directory.
        if executable_matches(DIRECTORY_CHANGE, source):
            return self.unknown("directory", source)
        # Quoted arguments can contain executable substitutions or programs
        # passed to an interpreter. Their command positions need a shell parser.
        substitutions = any(
            re.search(r"\$\((?!\()|`", match.group())
            for match in LEXEME.finditer(source)
            if not match.group().startswith(("'", "#", "/*", "//"))
        )
        if substitutions or executable_matches(INLINE_PROGRAM, source):
            return self.unknown("shell-command", source)

        def replace(name: str) -> str:
            workspace = ("${GITHUB_WORKSPACE}/", "$GITHUB_WORKSPACE/")
            rooted = name.startswith(workspace)
            for prefix in workspace:
                name = name.removeprefix(prefix)
            path = posixpath.normpath(posixpath.join("" if rooted else directory, name))
            if path not in self.files or path in visited:
                return self.unknown("script", path)
            body = self.script(path, directory, visited)
            digest = hashlib.sha256(str(body).encode()).hexdigest()
            return f"<script:{digest}>"

        patterns = (DYNAMIC_PROGRAM, LOCAL_PROGRAM, INTERPRETED_PROGRAM, SCRIPT_PROGRAM)
        for pattern in patterns:
            for match in reversed(executable_matches(pattern, source)):
                source = (
                    source[: match.start()]
                    + match["prefix"]
                    + replace(match["path"])
                    + source[match.end() :]
                )
        if ambiguous_executable(source):
            return self.unknown("shell-command", source)
        return normalize(source, self.repository)

    def script(
        self, path: str, directory: str = "", visited: frozenset[str] = frozenset()
    ) -> tuple[str, ...]:
        """Keep quoted whitespace, Python indentation and shell boundaries."""
        key = (path, directory)
        if key in self.scripts:
            return self.scripts[key]
        source = self.files[path]
        visited = visited | {path}
        if path.endswith(".py"):
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
                # Constants and operators are logic, not parameters or comments.
                shape = tuple(
                    ":".join(
                        (
                            str(item.type),
                            (
                                item.string
                                if item.type in {tokenize.NUMBER, tokenize.OP}
                                else normalize(item.string, self.repository)
                            ),
                        )
                    )
                    for item in tokens
                )
                if self.uninspected_python_imports(source):
                    shape += (self.unknown("python-import", path),)
                # Python strings are not shell command positions.
                # Keep process launchers and runpy execution opaque until their
                # dependencies can be resolved, including aliases/computed targets.
                # Treat any runpy reference conservatively: indirect attribute
                # access and imported aliases need no separate data-flow parser.
                # Dynamic imports may load runpy under a computed name as well.
                names = (
                    item.string  # Inspect code names, never string contents.
                    for item in tokens
                    if item.type == tokenize.NAME
                )
                if any(
                    re.fullmatch(
                        r"subprocess|system|popen|exec\w*|spawn\w*|"
                        r"posix_spawn\w*|create_subprocess_\w+|"
                        r"runpy|run_path|run_module|"
                        r"__import__|importlib|import_module",
                        name,
                    )
                    for name in names
                ):
                    shape += (self.unknown("python-command", source),)
            except (SyntaxError, tokenize.TokenError):
                raise ValueError(f"invalid Python source: {path}") from None
        else:
            normalized = self.command(source, directory, visited)
            shape = tuple(
                match.group()
                for match in LEXEME.finditer(normalized)
                if not match.group().isspace()
            )
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


# Recursive YAML context needs defaults, environment and cycle state separately.
# pylint: disable-next=too-many-arguments,too-many-branches
def operation_shape(
    value: Any,
    repository: str,
    files: dict[str, str],
    *,
    resolver: SourceResolver | None = None,
    defaults: dict[str, Any] | None = None,
    environment: dict[str, Any] | None = None,
    visited: frozenset[str] = frozenset(),
) -> Any:
    """Keep execution metadata and unknown inputs; mask only known parameters."""
    resolver = resolver or SourceResolver(repository, files)

    def recurse(item: Any) -> Any:
        return operation_shape(
            item,
            repository,
            files,
            resolver=resolver,
            defaults=defaults,
            environment=environment,
            visited=visited,
        )

    if isinstance(value, list):
        return [recurse(item) for item in value]
    if not isinstance(value, dict):
        return normalize(str(value), repository)
    defaults = {**(defaults or {}), **run_defaults(value)}
    if "env" in value and not isinstance(value["env"], dict):
        raise ValueError("invalid environment mapping")
    environment = {**(environment or {}), **value.get("env", {})}
    result: dict[str, Any] = {}
    for key, item in value.items():
        if key in {"name", "using"}:
            continue
        if key in {"with", "env"}:
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
        elif key == "uses":
            # Retain action identity and subpath, discard mutable or SHA refs.
            target = str(item).split("@", 1)[0]
            if target.startswith("./"):
                result[key] = resolver.action(target, visited)
            else:
                result[key] = target.lower()
        elif key == "run":
            directory = str(
                value.get(
                    "working-directory",
                    defaults.get("working-directory", ""),
                ),
            )
            result[key] = resolver.command(str(item), directory, visited)
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
