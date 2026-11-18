# SPDX-License-Identifier: MIT
"""What the inline-shell check accepts as a call to a script file (#1624).

A script call is one command and nothing else: no ``;``, ``&&``, ``||``, pipe,
redirection, second line or command substitution. It is
``[INTERPRETER [OPTION]] PATH [ARGUMENT...]``, where INTERPRETER is one of
``INTERPRETERS`` with only the options listed for it, and every argument is a
literal or a plain variable (``$NAME``, ``${NAME}``, ``${NAME:-word}``). PATH
is, in order of preference:

- a file of this repository under ``scripts/``, written relative to the
  repository (``scripts/...``), to a tooling checkout of it
  (``.lgtm-ci-tooling/scripts/...``, ``.lgtm-ci-readiness/scripts/...``), to
  ``$GITHUB_WORKSPACE``, to ``$SCRIPTS_DIR`` (the composite actions' name for
  ``scripts/``) or, in a composite action, to ``$GITHUB_ACTION_PATH``
  (``$GITHUB_ACTION_PATH/../../../scripts/...``);
- in a composite action, a file next to its ``action.yml``
  (``$GITHUB_ACTION_PATH/name.sh``);
- a path with one variable set in the step's own ``env:``, alone or after one
  of the prefixes above. The check reads the value: a literal must name a
  file by the rules above; ``${{ inputs.<name> }}`` alone is a script the
  caller chose, accepted only after an interpreter and alone or right after
  ``$GITHUB_WORKSPACE/``; ``${{ COND && 'a' || 'b' }}`` is accepted when
  each of ``a`` and ``b`` names a file. Anything else is rejected;
- a staged copy listed in ``STAGED_COPIES``, with its source.

A named file must exist, be a regular file, and no part of its path may be a
symbolic link. A relative path is read from ``working-directory`` when one is
set; an expression there leaves it unknown, so the path is rejected.
"""

from __future__ import annotations

import posixpath
import re
from dataclasses import dataclass
from pathlib import Path

from inline_shell_lexer import Kind, ShellSyntaxError, Word, tokenize
from inline_shell_rules import (
    INTERPRETERS,
    STAGED_COPIES,
    TOOLING_CHECKOUTS,
    StepContext,
)

INPUT_VALUE = re.compile(r"\$\{\{\s*inputs\.(?P<name>[A-Za-z_][A-Za-z0-9_-]*)\s*\}\}")
CHOICE_VALUE = re.compile(
    r"\$\{\{\s*(?P<cond>.+?)\s*&&\s*'(?P<a>[^'$`]+)'\s*\|\|\s*'(?P<b>[^'$`]+)'\s*\}\}",
    re.DOTALL,
)


@dataclass(frozen=True)
class CallVerdict:
    """Whether a step is a script call.

    Attributes:
        ok: True when the step is exactly one script call.
        reason: Why it is not, else what it calls.
        shaped: True when the step looks like a call (one command with an
            interpreter or a path), so ``reason`` is worth reporting.
    """

    ok: bool
    reason: str
    shaped: bool = False


def _reject(reason: str) -> CallVerdict:
    return CallVerdict(ok=False, reason=reason)


def script_call(script: str, context: StepContext, repo: Path) -> CallVerdict:
    """Tell whether a step is one call to a script file.

    Args:
        script: The text of a ``run:`` step.
        context: The step's YAML context.
        repo: The repository root, where a named script must exist.

    Returns:
        The verdict; ``reason`` names the script or what is not a call.
    """
    try:
        tokens = tokenize(script)
    except ShellSyntaxError as error:
        return _reject(str(error))
    while tokens and tokens[-1].kind is Kind.NEWLINE:
        tokens.pop()
    while tokens and tokens[0].kind is Kind.NEWLINE:
        tokens.pop(0)
    if not tokens or any(token.kind is not Kind.WORD for token in tokens):
        return _reject("not exactly one command")
    words = [token.word for token in tokens if token.word is not None]
    if any(word.substitution or word.expansion for word in words):
        return _reject("a word substitutes or expands")
    index = 0
    interpreter = words[0].literal()
    if interpreter in INTERPRETERS:
        index = 1
        while index < len(words) and (words[index].literal() or "").startswith("-"):
            if words[index].literal() not in INTERPRETERS[interpreter]:
                reason = f"{interpreter} option {words[index].literal()}"
                return CallVerdict(ok=False, reason=reason, shaped=True)
            index += 1
    if index >= len(words):
        return CallVerdict(ok=False, reason="no script path", shaped=True)
    path = words[index]
    verdict = script_path(path, context, repo, interpreted=index > 0)
    path_text = "".join(text for _, text in path.parts)
    shaped = index > 0 or "/" in path_text or bool(path.variables())
    return CallVerdict(ok=verdict.ok, reason=verdict.reason, shaped=shaped)


def _roots(context: StepContext) -> dict[str, str]:
    """Return the trusted root variables and the repository path each names."""
    roots = {"GITHUB_WORKSPACE": "", "SCRIPTS_DIR": "scripts/"}
    if context.action_dir is not None:
        roots["GITHUB_ACTION_PATH"] = f"{context.action_dir}/"
    return {name: path for name, path in roots.items() if name not in context.env}


@dataclass(frozen=True)
class _Split:
    """A path word split around its root and its one env: variable.

    Attributes:
        root: The root variable it starts with, else "".
        base: The repository path the root names.
        name: The env: variable in the rest, else "".
        prefix: Literal text between the root and the variable.
        suffix: Literal text after the variable.
    """

    root: str
    base: str
    name: str = ""
    prefix: str = ""
    suffix: str = ""


def _split(parts: list[tuple[str, str]], context: StepContext) -> _Split | CallVerdict:
    """Split a path word's parts, or say why the check cannot accept it."""
    root, base = "", ""
    roots = _roots(context)
    if parts and parts[0][0] == "var" and parts[0][1] in roots:
        root, rest = parts[0][1], parts[1:]
        if not rest or rest[0][0] != "lit" or not rest[0][1].startswith("/"):
            return _reject(f"${root} is not followed by /")
        base = roots[root]
        parts = [("lit", rest[0][1][1:]), *rest[1:]]
    names = [index for index, (kind, _) in enumerate(parts) if kind == "var"]
    if not names:
        return _Split(root, base, prefix="".join(text for _, text in parts))
    if len(names) > 1:
        return _reject("the path joins more than one variable")
    at = names[0]
    name = parts[at][1]
    if name not in context.env:
        if not root and at == 0:
            message = f"path starts with ${name}, not a known root or a step env: key"
            return _reject(message)
        return _reject(f"path uses ${name}, which the step's env: does not set")
    prefix = "".join(text for _, text in parts[:at])
    suffix = "".join(text for _, text in parts[at + 1 :])
    return _Split(root, base, name, prefix, suffix)


def script_path(
    word: Word,
    context: StepContext,
    repo: Path,
    *,
    interpreted: bool,
) -> CallVerdict:
    """Tell whether a word names a script file the rules accept.

    Args:
        word: The path word of the command.
        context: The step's YAML context.
        repo: The repository root.
        interpreted: True when an interpreter runs the path.

    Returns:
        The verdict for the path.
    """
    parts = list(word.parts)
    if word.defaulted:
        return _reject("the path has a default word, so it may be any file")
    if len(parts) == 2 and parts[0][0] == "var" and parts[1][0] == "lit":
        staged = STAGED_COPIES.get((parts[0][1], parts[1][1]))
        if staged is not None:
            return CallVerdict(ok=True, reason=f"staged copy of {staged}")
    split = _split(parts, context)
    if isinstance(split, CallVerdict):
        return split
    if not split.name:
        return _resolve(split.base + split.prefix, split.root, context, repo)
    return _env_selected(split, context, repo, interpreted=interpreted)


def _choices(cond: str) -> bool:
    """Tell whether ``COND && 'a' || 'b'`` can only yield ``a`` or ``b``.

    A top-level ``||`` in COND (``x || y && 'a' || 'b'``) would yield ``x``.
    """
    if "${{" in cond or "}}" in cond:
        return False
    depth, quoted = 0, False
    for index, char in enumerate(cond):
        if char == "'":
            quoted = not quoted
        elif not quoted and char in "()":
            depth += 1 if char == "(" else -1
        elif not quoted and depth == 0 and cond.startswith("||", index):
            return False
    return depth == 0 and not quoted


def _caller_script(split: _Split, input_name: str, *, interpreted: bool) -> CallVerdict:
    """Accept ``${{ inputs.<name> }}`` as a script the caller chose, used plainly."""
    if not interpreted:
        message = f"${split.name} is a caller's script; run it with bash, sh or python3"
        return _reject(message)
    if split.prefix or split.suffix or split.root not in {"", "GITHUB_WORKSPACE"}:
        where = "alone or after $GITHUB_WORKSPACE/"
        return _reject(f"${split.name} is a caller's script; use it {where}")
    reason = f"script chosen by the caller (inputs.{input_name})"
    return CallVerdict(ok=True, reason=reason)


def _candidates(name: str, value: str) -> list[str] | CallVerdict:
    """Return every value an env: entry can have, or why the check cannot list them."""
    if "${{" not in value:
        return [value]
    choice = CHOICE_VALUE.fullmatch(value.strip())
    if choice is None or not _choices(choice["cond"]):
        message = f"env: {name} is an expression whose value the check cannot list"
        return _reject(message)
    return [choice["a"], choice["b"]]


def _env_selected(
    split: _Split,
    context: StepContext,
    repo: Path,
    *,
    interpreted: bool,
) -> CallVerdict:
    """Accept a path whose variable's env: value names an accepted script."""
    value = context.env[split.name]
    if value is None:
        return _reject(f"env: {split.name} is not a plain string")
    caller = INPUT_VALUE.fullmatch(value.strip())
    if caller is not None:
        return _caller_script(split, caller["name"], interpreted=interpreted)
    candidates = _candidates(split.name, value)
    if isinstance(candidates, CallVerdict):
        return candidates
    resolved = ""
    for candidate in candidates:
        path = split.base + split.prefix + candidate + split.suffix
        verdict = _resolve(path, split.root, context, repo)
        if not verdict.ok:
            return _reject(f"${split.name} may be {candidate!r}: {verdict.reason}")
        resolved = verdict.reason
    return CallVerdict(ok=True, reason=f"script chosen through env: ({resolved})")


def _strip_checkout(path: str) -> str:
    """Return a path without a leading ``./`` or tooling checkout directory."""
    path = path.removeprefix("./")
    for checkout in TOOLING_CHECKOUTS:
        if path.startswith(checkout):
            return path[len(checkout) :]
    return path


def _resolve(path: str, root: str, context: StepContext, repo: Path) -> CallVerdict:
    """Read a relative path from ``working-directory``, then check the file."""
    directory = context.working_directory
    if not root and not path.startswith("/") and directory is not None:
        if "${{" in directory:
            message = f"{path} is relative to a working-directory set by an expression"
            return _reject(message)
        path = posixpath.join(directory, path)
    return _repository_file(path, action_dir=context.action_dir, repo=repo)


def _repository_file(path: str, *, action_dir: str | None, repo: Path) -> CallVerdict:
    """Accept a path to an existing regular script file under the allowed places."""
    relative = _strip_checkout(posixpath.normpath(path))
    if relative == ".." or relative.startswith(("../", "/")):
        return _reject(f"{path} leaves the repository")
    allowed = relative.startswith("scripts/") or (
        action_dir is not None and relative.startswith(f"{action_dir}/")
    )
    if not allowed:
        return _reject(f"{path} is not under scripts/")
    current = repo
    for part in relative.split("/"):
        current = current / part
        if current.is_symlink():
            linked = current.relative_to(repo).as_posix()
            return _reject(f"{relative} goes through the symbolic link {linked}")
    if not (repo / relative).is_file():
        return _reject(f"{relative} is not a file")
    return CallVerdict(ok=True, reason=relative)
