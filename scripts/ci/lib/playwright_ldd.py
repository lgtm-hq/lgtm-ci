#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Find the shared libraries a Playwright browser install cannot load (#1433).

Loaded by ``playwright_browsers.py`` (its ``probe`` subcommand). Runs ``ldd``
on every ELF file of a browser install, with ``LD_LIBRARY_PATH`` set to the
install's own library directories so bundled libraries resolve, and reports
each ``<name> => not found`` line. Anything it cannot be sure of raises
:class:`Undecidable`; the caller then installs the system packages.

Standard library only and Python 3.10 compatible (``python3 -I`` on the
runner's own interpreter).
"""

from __future__ import annotations

import os
import re
import subprocess
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

ELF_MAGIC = b"\x7fELF"
NOT_FOUND = re.compile(r"^\s*(\S+) => not found\s*$")
NOT_DYNAMIC = "not a dynamic executable"
LDD_TIMEOUT_SECONDS = 30
# Wall-clock budget of one probe: no ldd call starts after it, so a probe
# ends within LDD_BUDGET_SECONDS + LDD_TIMEOUT_SECONDS (90s) and stays inside
# the install step's backstop (tests/python/test_playwright_install_bound.py).
LDD_BUDGET_SECONDS = 60

Runner = Callable[[Sequence[str], Mapping[str, str]], subprocess.CompletedProcess[str]]


class Undecidable(Exception):
    """Raised when the probe cannot tell whether a library is missing."""


@dataclass(frozen=True)
class Budget:
    """When a probe stops starting ldd calls.

    Attributes:
        seconds: The caller's budget; it only ever lowers LDD_BUDGET_SECONDS,
            to fit what is left of the caller's own deadline.
        clock: Monotonic clock (injected in tests).
    """

    seconds: float = LDD_BUDGET_SECONDS
    clock: Callable[[], float] = time.monotonic


def _is_elf(path: Path) -> bool:
    """Return True when ``path`` is a regular file starting with the ELF magic.

    Args:
        path: The file.

    Returns:
        Whether it is an ELF file (unreadable files are not).
    """
    if path.is_symlink() or not path.is_file():
        return False
    try:
        with path.open("rb") as handle:
            return handle.read(len(ELF_MAGIC)) == ELF_MAGIC
    except OSError:
        return False


def run_ldd(
    argv: Sequence[str],
    env: Mapping[str, str],
) -> subprocess.CompletedProcess[str]:
    """Run ``ldd`` with a timeout.

    Args:
        argv: The command.
        env: Its environment.

    Returns:
        The completed process.
    """
    return subprocess.run(
        list(argv),
        env=dict(env),
        capture_output=True,
        text=True,
        timeout=LDD_TIMEOUT_SECONDS,
        check=False,
    )


def _search_env(files: Sequence[Path], env: Mapping[str, str]) -> dict[str, str]:
    """Return ``env`` with every directory of ``files`` first on LD_LIBRARY_PATH.

    Args:
        files: The ELF files of one browser install.
        env: The base environment.

    Returns:
        The environment for that install's ``ldd`` calls.
    """
    search = sorted({str(path.parent) for path in files})
    extra = env.get("LD_LIBRARY_PATH", "")
    if extra:
        search.append(extra)
    call_env = dict(env)
    call_env["LD_LIBRARY_PATH"] = os.pathsep.join(search)
    return call_env


def _not_found(path: Path, result: subprocess.CompletedProcess[str]) -> set[str]:
    """Return the libraries one ``ldd`` result reports as not found.

    Args:
        path: The file ``ldd`` ran on.
        result: Its completed process.

    Returns:
        The library names on ``<name> => not found`` lines.

    Raises:
        Undecidable: When ``ldd`` failed for another reason than a static file.
    """
    output = f"{result.stdout}\n{result.stderr}"
    if result.returncode != 0 and NOT_DYNAMIC not in output:
        raise Undecidable(f"ldd {path} exited {result.returncode}")
    matches = [NOT_FOUND.match(line) for line in output.splitlines()]
    return {match.group(1) for match in matches if match is not None}


def missing_libraries(
    dirs: Sequence[Path],
    *,
    ldd: str,
    env: Mapping[str, str],
    run: Runner = run_ldd,
    budget: Budget | None = None,
) -> list[str]:
    """Return the shared libraries the browsers in ``dirs`` cannot load.

    Libraries bundled with a browser resolve through ``LD_LIBRARY_PATH`` set to
    every directory of that browser that holds an ELF file, as Playwright's own
    dependency check does.

    Args:
        dirs: Browser install directories.
        ldd: The ``ldd`` binary.
        env: The base environment.
        run: Runs one ``ldd`` call (injected in tests).
        budget: When no further ldd call starts (None: LDD_BUDGET_SECONDS).

    Returns:
        The missing library names, sorted.

    Raises:
        Undecidable: When no ELF file is found, ``ldd`` fails or hangs, or
            the probe runs past its budget.
    """
    budget = budget or Budget()
    limit = min(budget.seconds, LDD_BUDGET_SECONDS)
    deadline = budget.clock() + limit
    missing: set[str] = set()
    for browser in dirs:
        files = [path for path in sorted(browser.rglob("*")) if _is_elf(path)]
        if not files:
            raise Undecidable(f"no ELF file under {browser}")
        call_env = _search_env(files, env)
        for path in files:
            if budget.clock() > deadline:
                raise Undecidable(f"probe ran past its {limit:g}s budget")
            try:
                result = run([ldd, str(path)], call_env)
            except (OSError, subprocess.SubprocessError) as error:
                raise Undecidable(f"ldd {path}: {error}") from error
            missing |= _not_found(path, result)
    return sorted(missing)
