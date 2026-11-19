#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Decide what a Playwright browser install still has to do (#1433).

``scripts/ci/lib/testing/playwright_runner.sh`` calls this before it runs
``playwright install`` or apt, from the ``run-playwright`` composite action and
from ``reusable-test-e2e-playwright.yml`` alike. Four subcommands:

``cache-key``
    Print the browser cache key: OS (with the distribution release on Linux),
    architecture, the exact installed Playwright version, the install mode
    and the browsers. Print nothing when any part is unknown (no exact
    version, an unknown distribution or architecture): the caller then skips
    the cache, so a key can never restore browsers built for something else.
``cache-path``
    Print the directory Playwright downloads browsers into, as Playwright
    resolves it (``PLAYWRIGHT_BROWSERS_PATH``, else the per-OS cache
    directory). Print nothing for ``PLAYWRIGHT_BROWSERS_PATH=0``, which keeps
    browsers inside ``node_modules``.
``present``
    Exit 0 when every requested browser has a complete install (Playwright's
    ``INSTALLATION_COMPLETE`` marker) in that directory, else 1.
``probe``
    On Linux, run ``ldd`` on every ELF file of the requested browsers and
    exit 0 when every shared library resolves, 1 when some are missing (they
    are printed one per line), 3 when it cannot decide. The caller installs
    the system packages unless the exit code is 0, so every doubt installs.
    ``ldd`` sees shared libraries only: fonts and ``xvfb`` are not checked.

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
from collections.abc import Callable, Iterable, Mapping, Sequence
from pathlib import Path

try:
    from playwright_ldd import Runner, Undecidable, missing_libraries, run_ldd
except ImportError:  # standalone execution: bootstrap this lib/ directory
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    sys.modules.pop("playwright_ldd", None)  # a failed attribute import stays cached
    from playwright_ldd import Runner, Undecidable, missing_libraries, run_ldd

MODES = ("full", "headless-shell")
ALL_BROWSERS = ("chromium", "firefox", "webkit")
MARKER = "INSTALLATION_COMPLETE"
EXACT_VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?")
KEY_UNSAFE = re.compile(r"[^0-9A-Za-z._-]+")
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


def dir_prefixes(names: Iterable[str], mode: str) -> list[str] | None:
    """Return the browser directory prefixes Playwright installs for ``names``.

    Args:
        names: Browser names from :func:`browser_names`.
        mode: ``full`` or ``headless-shell`` (``--only-shell`` for chromium).

    Returns:
        One prefix per browser, or None when a name is not a browser
        Playwright downloads into its cache (a channel such as ``chrome``).
    """
    prefixes: list[str] = []
    for name in names:
        if name == "chromium":
            shell = mode == "headless-shell"
            prefixes.append("chromium_headless_shell" if shell else "chromium")
        elif name in ALL_BROWSERS:
            prefixes.append(name)
        else:
            return None
    return prefixes


def browsers_path(env: Mapping[str, str], system: str, home: Path) -> Path | None:
    """Return the directory Playwright downloads browsers into.

    Args:
        env: The environment.
        system: ``Linux``, ``macOS`` or ``Windows`` (RUNNER_OS spelling).
        home: The user's home directory.

    Returns:
        The path, or None when browsers live inside ``node_modules``.
    """
    override = env.get("PLAYWRIGHT_BROWSERS_PATH", "")
    if override == "0":
        return None
    if override:
        return Path(override)
    if system == "macOS":
        return home / "Library" / "Caches" / "ms-playwright"
    if system == "Windows":
        local = env.get("LOCALAPPDATA") or str(home / "AppData" / "Local")
        return Path(local) / "ms-playwright"
    cache = env.get("XDG_CACHE_HOME") or str(home / ".cache")
    return Path(cache) / "ms-playwright"


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


def installed_dirs(root: Path, prefix: str) -> list[Path]:
    """Return the complete installs of one browser under ``root``.

    Args:
        root: The browsers directory.
        prefix: A prefix from :func:`dir_prefixes`.

    Returns:
        Directories named ``<prefix>-<revision>`` that hold the marker.
    """
    if not root.is_dir():
        return []
    found: list[Path] = []
    for path in root.glob(f"{prefix}-*"):
        if path.is_dir() and (path / MARKER).is_file():
            found.append(path)
    return sorted(found)


def present(root: Path | None, prefixes: Sequence[str] | None) -> bool:
    """Return True when every browser has a complete install under ``root``.

    Args:
        root: The browsers directory (None: unknown).
        prefixes: From :func:`dir_prefixes` (None: an unknown browser).

    Returns:
        False whenever in doubt.
    """
    if root is None or not prefixes:
        return False
    return all(installed_dirs(root, prefix) for prefix in prefixes)


def probe(
    *,
    root: Path | None,
    prefixes: Sequence[str] | None,
    env: Mapping[str, str],
    which: Callable[[str], str | None] = shutil.which,
    run: Runner = run_ldd,
) -> list[str]:
    """Return the missing shared libraries of the requested browsers.

    Args:
        root: The browsers directory.
        prefixes: From :func:`dir_prefixes`.
        env: The environment.
        which: Finds ``ldd`` (injected in tests).
        run: Runs one ``ldd`` call (injected in tests).

    Returns:
        The missing library names; empty when every library resolves.

    Raises:
        Undecidable: Whenever the answer is not certain.
    """
    if root is None or prefixes is None:
        raise Undecidable("unknown browser directory or browser name")
    ldd = which("ldd")
    if ldd is None:
        raise Undecidable("ldd is not on PATH")
    dirs: list[Path] = []
    for prefix in prefixes:
        found = installed_dirs(root, prefix)
        if not found:
            raise Undecidable(f"no complete {prefix} install under {root}")
        dirs.extend(found)
    missing: list[str] = missing_libraries(dirs, ldd=ldd, env=env, run=run)
    return missing


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
    for name in ("cache-key", "present", "probe"):
        command = sub.add_parser(name)
        command.add_argument("--browsers", default="chromium")
        command.add_argument("--mode", choices=MODES, default="full")
        if name == "cache-key":
            command.add_argument("--version", required=True)
    sub.add_parser("cache-path")
    return parser


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
    root = browsers_path(env, system, Path.home())
    if args.command == "cache-path":
        print(root or "")
        return 0
    if args.command == "cache-key":
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
    prefixes = dir_prefixes(browser_names(args.browsers), args.mode)
    if args.command == "present":
        return 0 if present(root, prefixes) else EXIT_MISSING
    try:
        missing = probe(root=root, prefixes=prefixes, env=env)
    except Undecidable as error:
        print(f"[playwright-browsers] probe undecided: {error}", file=sys.stderr)
        return EXIT_UNDECIDABLE
    for name in missing:
        print(name)
    return EXIT_MISSING if missing else 0


if __name__ == "__main__":
    sys.exit(main())
