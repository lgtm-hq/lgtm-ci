#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Decide what a Playwright browser install still has to do (#1433).

``scripts/ci/lib/testing/playwright_runner.sh`` and both entry points (the
``run-playwright`` action, ``reusable-test-e2e-playwright.yml``) call it:

``cache-key``
    Print the browser cache key (OS and Linux release, architecture, exact
    installed Playwright version, install mode, browsers), or nothing when a
    part is unknown: the cache is then skipped, never shared across builds.
``cache-path``
    Print the absolute directory Playwright downloads browsers into, resolved
    as Playwright resolves it: ``PLAYWRIGHT_BROWSERS_PATH``, else the per-OS
    cache directory, and a relative result against ``INIT_CWD``, else the
    current directory (run it in the install's working directory). Print
    nothing for ``PLAYWRIGHT_BROWSERS_PATH=0`` (browsers in ``node_modules``).
``present``
    Read the output of ``playwright install --dry-run <same arguments>`` on
    stdin: one ``Install location:`` per artifact the real install puts down
    (the full browser, chromium's headless shell, FFmpeg and so on, at the
    exact revision the installed Playwright expects for this host). Exit 0
    when every location holds Playwright's ``INSTALLATION_COMPLETE`` marker,
    else 1. Unrecognised output, or a ``<system>`` location (a channel such as
    ``chrome``), is 1: the caller then installs.
``probe``
    Read the same dry-run output and run ``ldd`` on every ELF file of every
    location (``playwright_ldd.py``). Exit 0 when every shared library
    resolves, 1 when some are missing (printed one per line), 3 when it cannot
    decide. WebKit is always 3: it loads system libraries with ``dlopen``,
    which ``ldd`` cannot see (Playwright's own host check adds
    ``libGLESv2.so.2`` and ``libx264.so`` for it). Chromium and Firefox are
    checked with ``ldd`` alone, as Playwright's own host check does. ``ldd``
    sees shared libraries only: fonts and ``xvfb`` are not checked.

Standard library only and Python 3.10 compatible: it runs as ``python3 -I`` on
the runner's own interpreter (3.10 on ``ubuntu-22.04``).

Exit codes: 0 and 1 as above, 2 usage error, 3 undecidable probe.
"""

from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import sys
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path

try:
    from playwright_ldd import Budget, Runner, Undecidable, missing_libraries, run_ldd
except ImportError:  # standalone execution: bootstrap this lib/ directory
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    sys.modules.pop("playwright_ldd", None)  # a failed attribute import stays cached
    from playwright_ldd import Budget, Runner, Undecidable, missing_libraries, run_ldd

MODES = ("full", "headless-shell")
ALL_BROWSERS = ("chromium", "firefox", "webkit")
MARKER = "INSTALLATION_COMPLETE"
EXACT_VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?")
KEY_UNSAFE = re.compile(r"[^0-9A-Za-z._-]+")
DRY_RUN_BROWSER = re.compile(r"browser: (\S+)(?: version \S+)?")
DRY_RUN_LOCATION = re.compile(r"\s+Install location:\s+(\S.*)")
# Browsers that load system libraries with dlopen, which ldd cannot see.
DLOPEN_BROWSERS = ("webkit",)
EXIT_MISSING = 1
EXIT_UNDECIDABLE = 3
ARCHES = {
    "x86_64": "x64",
    "amd64": "x64",
    "x64": "x64",
    "aarch64": "arm64",
    "arm64": "arm64",
}


def browser_names(browsers: str) -> list[str]:
    """Return the requested browser names, sorted and de-duplicated.

    Args:
        browsers: Space- or comma-separated names, or ``all``.

    Returns:
        The names; ``all`` expands to chromium, firefox and webkit.
    """
    names = [name for name in re.split(r"[\s,]+", browsers.strip()) if name]
    if not names or names == ["all"]:
        return list(ALL_BROWSERS)
    return sorted(set(names))


def browsers_path(
    env: Mapping[str, str],
    system: str,
    home: Path,
    cwd: Path,
) -> Path | None:
    """Return the absolute directory Playwright downloads browsers into.

    Args:
        env: The environment.
        system: ``Linux``, ``macOS`` or ``Windows`` (RUNNER_OS spelling).
        home: The user's home directory.
        cwd: The install's working directory.

    Returns:
        The path, or None when browsers live inside ``node_modules``.
    """
    override = env.get("PLAYWRIGHT_BROWSERS_PATH", "")
    if override == "0":
        return None
    if override:
        result = Path(override)
    elif system == "macOS":
        result = home / "Library" / "Caches" / "ms-playwright"
    elif system == "Windows":
        local = env.get("LOCALAPPDATA") or home / "AppData" / "Local"
        result = Path(local) / "ms-playwright"
    else:
        result = Path(env.get("XDG_CACHE_HOME") or home / ".cache") / "ms-playwright"
    if not result.is_absolute():
        # Playwright: path.resolve(INIT_CWD || process.cwd(), result).
        result = Path(env.get("INIT_CWD") or cwd) / result
    return Path(os.path.normpath(result))


def _os_release(path: Path) -> dict[str, str]:
    """Return the key/value pairs of an os-release file (empty when unreadable).

    Args:
        path: The os-release file.

    Returns:
        The parsed pairs, quotes removed.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return {}
    pairs: dict[str, str] = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            pairs[key.strip()] = value.strip().strip("\"'")
    return pairs


def os_fragment(system: str, os_release: Path, mac_release: str) -> str | None:
    """Return the OS part of the cache key, or None when it is unknown.

    Playwright downloads a different build per Linux distribution release
    (ubuntu22.04 and ubuntu24.04 differ), so Linux keys carry the release.

    Args:
        system: ``Linux``, ``macOS`` or ``Windows``.
        os_release: The os-release file to read on Linux.
        mac_release: ``platform.mac_ver()[0]`` on macOS.

    Returns:
        For example ``linux-ubuntu24.04``, ``macos-15`` or ``windows``.
    """
    if system == "Linux":
        release = _os_release(os_release)
        distro, version = release.get("ID", ""), release.get("VERSION_ID", "")
        return f"linux-{distro}{version}" if distro and version else None
    if system == "macOS":
        major = mac_release.split(".", 1)[0]
        return f"macos-{major}" if major else None
    if system == "Windows":
        return "windows"
    return None


def arch_fragment(env: Mapping[str, str], machine: str) -> str | None:
    """Return the architecture part of the cache key, or None when unknown.

    Args:
        env: The environment (RUNNER_ARCH wins).
        machine: ``platform.machine()``.

    Returns:
        ``x64`` or ``arm64``.
    """
    raw = env.get("RUNNER_ARCH") or machine
    return ARCHES.get(raw.lower())


def cache_key(
    *,
    version: str,
    browsers: str,
    mode: str,
    os_part: str | None,
    arch_part: str | None,
) -> str:
    """Compose the browser cache key; empty when it would not be exact.

    Args:
        version: The installed Playwright version (``1.56.1``).
        browsers: The browsers input.
        mode: ``full`` or ``headless-shell``.
        os_part: From :func:`os_fragment`.
        arch_part: From :func:`arch_fragment`.

    Returns:
        The key, or ``""`` when the version, OS or architecture is unknown.
    """
    if not EXACT_VERSION.fullmatch(version) or not os_part or not arch_part:
        return ""
    parts = ["playwright-browsers", os_part, arch_part, version, mode]
    parts.extend(browser_names(browsers))
    return KEY_UNSAFE.sub("-", "-".join(parts))


def install_locations(dry_run: str) -> list[tuple[str, Path]] | None:
    """Return each artifact ``playwright install --dry-run`` would install.

    Args:
        dry_run: Its output: per artifact a ``browser: <name> [version <v>]``
            line followed by an indented ``Install location: <dir>`` line.

    Returns:
        ``(name, directory)`` pairs in output order, or None when the output
        lists none, an artifact has no location, a location is not absolute,
        or one is ``<system>`` (a channel installed outside the cache).
    """
    found: list[tuple[str, Path]] = []
    name: str | None = None
    for line in dry_run.splitlines():
        line = line.rstrip("\r")
        browser = DRY_RUN_BROWSER.fullmatch(line)
        if browser:
            if name is not None:
                return None
            name = browser.group(1)
            continue
        location = DRY_RUN_LOCATION.fullmatch(line)
        if location and name is not None:
            path = location.group(1).strip()
            if path == "<system>" or not Path(path).is_absolute():
                return None
            found.append((name, Path(path)))
            name = None
    if name is not None or not found:
        return None
    return found


def present(locations: Sequence[tuple[str, Path]] | None) -> bool:
    """Return True when every artifact is installed completely.

    Args:
        locations: From :func:`install_locations` (None: unknown).

    Returns:
        False whenever in doubt.
    """
    if not locations:
        return False
    return all((path / MARKER).is_file() for _, path in locations)


def probe(
    *,
    locations: Sequence[tuple[str, Path]] | None,
    env: Mapping[str, str],
    budget: float | None = None,
    which: Callable[[str], str | None] = shutil.which,
    run: Runner = run_ldd,
) -> list[str]:
    """Return the missing shared libraries of the listed artifacts.

    Args:
        locations: From :func:`install_locations`.
        env: The environment.
        budget: Seconds after which no ldd call starts (None: the default).
        which: Finds ``ldd`` (injected in tests).
        run: Runs one ``ldd`` call (injected in tests).

    Returns:
        The missing library names; empty when every library resolves.

    Raises:
        Undecidable: Whenever the answer is not certain.
    """
    if not locations:
        raise Undecidable("the install dry run listed no artifact")
    dlopen = sorted({name for name, _ in locations if name in DLOPEN_BROWSERS})
    if dlopen:
        raise Undecidable(f"{', '.join(dlopen)} loads system libraries with dlopen")
    if not present(locations):
        raise Undecidable("not every listed artifact is installed completely")
    ldd = which("ldd")
    if ldd is None:
        raise Undecidable("ldd is not on PATH")
    dirs = [path for _, path in locations]
    limit = None if budget is None else Budget(seconds=budget)
    return list(missing_libraries(dirs, ldd=ldd, env=env, run=run, budget=limit))


def _runner_os(env: Mapping[str, str]) -> str:
    """Return RUNNER_OS, else the platform name in its spelling.

    Args:
        env: The environment.

    Returns:
        ``Linux``, ``macOS``, ``Windows`` or the raw platform name.
    """
    names = {"Linux": "Linux", "Darwin": "macOS", "Windows": "Windows"}
    system = platform.system()
    return env.get("RUNNER_OS") or names.get(system, system)


def _parser() -> argparse.ArgumentParser:
    """Build the command-line parser.

    Returns:
        The parser.
    """
    parser = argparse.ArgumentParser(prog="playwright_browsers.py", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    key = sub.add_parser("cache-key")
    key.add_argument("--browsers", default="chromium")
    key.add_argument("--mode", choices=MODES, default="full")
    key.add_argument("--version", required=True)
    sub.add_parser("cache-path")
    sub.add_parser("present")
    check = sub.add_parser("probe")
    check.add_argument("--budget-seconds", type=float, default=None)
    return parser


def _cache_key(args: argparse.Namespace, env: Mapping[str, str], system: str) -> int:
    """Print the cache key (empty, with the reason on stderr, when inexact).

    Args:
        args: The parsed ``cache-key`` arguments.
        env: The environment.
        system: The runner OS.

    Returns:
        0.
    """
    os_release = Path(env.get("OS_RELEASE_FILE", "/etc/os-release"))
    os_part = os_fragment(system, os_release, platform.mac_ver()[0])
    arch_part = arch_fragment(env, platform.machine())
    key = cache_key(
        version=args.version.strip(),
        browsers=args.browsers,
        mode=args.mode,
        os_part=os_part,
        arch_part=arch_part,
    )
    if not key:
        print(
            f"[playwright-browsers] no exact cache key (version={args.version!r},"
            f" os={os_part}, arch={arch_part}); the browser cache is skipped",
            file=sys.stderr,
        )
    print(key)
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    """Run one subcommand.

    Args:
        argv: Arguments (defaults to ``sys.argv[1:]``).

    Returns:
        The process exit code.
    """
    args = _parser().parse_args(argv)
    env = os.environ
    system = _runner_os(env)
    if args.command == "cache-path":
        print(browsers_path(env, system, Path.home(), Path.cwd()) or "")
        return 0
    if args.command == "cache-key":
        return _cache_key(args, env, system)
    locations = install_locations(sys.stdin.read())
    if args.command == "present":
        return 0 if present(locations) else EXIT_MISSING
    try:
        missing = probe(locations=locations, env=env, budget=args.budget_seconds)
    except Undecidable as error:
        print(f"[playwright-browsers] probe undecided: {error}", file=sys.stderr)
        return EXIT_UNDECIDABLE
    for name in missing:
        print(name)
    return EXIT_MISSING if missing else 0


if __name__ == "__main__":
    sys.exit(main())
