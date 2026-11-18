# SPDX-License-Identifier: MIT
"""Read the program a wrapper command runs (#1624).

``inline_shell_tools`` reads the first word of a command. A wrapper hides
the program behind it: ``uv run --frozen pytest``, ``npx --no-install
playwright``, ``pm_exec vitest`` and ``python3 -I -m build`` run pytest,
playwright, vitest and the ``build`` module. :func:`programs` returns the
wrapper and the program it wraps, each of which reads its own environment.

Wrappers
    ``uv run``, ``uv tool run``, ``uvx``, ``npx``, ``npm exec``, ``bunx``,
    ``bun x``, ``pnpm exec``, ``pnpm dlx``, and the ``scripts/ci/lib/node/
    pm.sh`` helpers ``pm_exec`` and ``pm_exec_argv``. Their options are
    skipped: a word starting with ``-``, the value after an option in
    :data:`VALUE_OPTIONS`, and ``--``.
Python
    ``python``, ``python3`` and the ``scripts/ci`` helpers that run python3
    (``run_python``, ``python3_outside_workspace``): with ``-m MODULE``
    (after any options, ``-Im`` too) the module is the program; otherwise
    the interpreter is.
"""

from __future__ import annotations

from collections.abc import Sequence

# Options of the wrappers that take the next word as their value.
VALUE_OPTIONS = frozenset(
    {
        # uv run, uv tool run, uvx
        "--with",
        "--with-editable",
        "--with-requirements",
        "--from",
        "--project",
        "--directory",
        "--python",
        "-p",
        "--package",
        "--extra",
        "--group",
        "--only-group",
        "--no-group",
        "--env-file",
        "--index",
        "--default-index",
        "--index-url",
        "--extra-index-url",
        "--find-links",
        "-f",
        "--config-file",
        "--cache-dir",
        # npx, npm exec, pnpm exec and dlx
        "--workspace",
        "-w",
        "--filter",
        "-F",
        "--dir",
        "-C",
    },
)
WRAPPERS = (
    ("uv", "run"),
    ("uv", "tool", "run"),
    ("uvx",),
    ("npx",),
    ("npm", "exec"),
    ("bunx",),
    ("bun", "x"),
    ("pnpm", "exec"),
    ("pnpm", "dlx"),
    ("pm_exec",),
    ("pm_exec_argv",),
)
# Commands that run python3, mapped to the interpreter they run.
PYTHONS = {
    "python": "python",
    "python3": "python3",
    "run_python": "python3",
    "python3_outside_workspace": "python3",
}
# Interpreter options that take the next word as their value.
PYTHON_VALUE_OPTIONS = frozenset({"-W", "-X"})


def _skip_options(words: Sequence[str], index: int) -> int:
    """Return the index of the first word after a wrapper's options."""
    while index < len(words) and words[index].startswith("-"):
        word = words[index]
        index += 1
        if word == "--":
            break
        if word in VALUE_OPTIONS:
            index += 1
    return index


def _wrapped(words: Sequence[str], index: int) -> int | None:
    """Return the index of the program a wrapper at ``index`` runs, else None."""
    for head in WRAPPERS:
        if tuple(words[index : index + len(head)]) == head:
            return _skip_options(words, index + len(head))
    return None


def _python_module(words: Sequence[str], index: int) -> str:
    """Return MODULE of ``python [options] -m MODULE`` at ``index``, else ""."""
    index += 1
    while index < len(words) and words[index].startswith("-"):
        word = words[index]
        if word == "-c" or word.startswith("--"):
            return ""
        if word.endswith("m") and word[1:].isalpha():
            return words[index + 1] if index + 1 < len(words) else ""
        index += 2 if word in PYTHON_VALUE_OPTIONS else 1
    return ""


def programs(words: Sequence[str], index: int = 0) -> list[str]:
    """Return the command at ``index`` and each program it wraps.

    Args:
        words: The words of one command.
        index: Where the command word is.

    Returns:
        ``["uv", "pytest"]`` for ``uv run --frozen pytest``; ``["python3",
        "build"]`` for ``python3 -I -m build``; ``["git"]`` for ``git log``.
    """
    found: list[str] = []
    while index < len(words):
        word = words[index]
        found.append(PYTHONS.get(word, word))
        if word in PYTHONS:
            module = _python_module(words, index)
            return [*found, module] if module else found
        wrapped = _wrapped(words, index)
        if wrapped is None:
            return found
        index = wrapped
    return found
