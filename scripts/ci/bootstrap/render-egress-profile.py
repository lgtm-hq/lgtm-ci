#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Write a copy of the workflow tree under one egress profile, or check one (#1597).

This repository's workflows run harden-runner with ``egress-policy: block``
and fail every job whose agent cannot prove it enforces that policy. A copy of
these workflows under another namespace that runs on private repositories
without a StepSecurity subscription can never pass that check: the agent turns
``block`` into audit there. Such a copy is generated once, with a profile:

``block`` (the default)
    Every file is written unchanged, byte for byte.

``none``
    harden-runner is not run. Nothing is sent to StepSecurity, and nothing is
    claimed: each hardened job reports that it has no egress control.

``audit``
    harden-runner runs in audit mode: it logs, and reports resolved DNS names
    and connections to StepSecurity, but enforces nothing.

The rewrites themselves live in ``egress_profile_rewrite.py``; docs/
workflow-contract.md describes each profile. The profile is chosen here, when
the copy is generated; nothing in a workflow can select it at run time.

The output holds every file a copy runs from (:data:`SURFACE`) and a marker
file, :data:`MARKER`, naming the profile, the source commit and this
generator. ``--out`` must be outside the source tree, and either empty or a
copy this generator wrote (it carries the marker). Generating again removes
files of the surface that are no longer produced; nothing outside the surface
is touched. Every destination is checked before anything is written: no
symlink, no path outside ``--out``, nothing inside the source tree.

Usage:
    uv run python scripts/ci/bootstrap/render-egress-profile.py \\
        --profile none --out ../copy            # write the copy
    uv run python scripts/ci/bootstrap/render-egress-profile.py \\
        --profile none --out ../copy --check    # exit 1 if it is stale
"""

# pylint: disable=invalid-name  # hyphenated CLI filename is the invocation contract

from __future__ import annotations

import argparse
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from collections.abc import Callable, Sequence
from pathlib import Path, PurePosixPath
from types import ModuleType

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
GENERATOR = "lgtm-ci scripts/ci/bootstrap/render-egress-profile.py"
MARKER = ".lgtm-ci-egress-profile.json"
# What a copy runs from: workflows, the actionlint configuration they are
# linted with, the composite actions, scripts and schemas they check out from
# the tooling repository, and the caller-owned examples. Files or directories.
SURFACE: tuple[str, ...] = (
    ".github/workflows",
    ".github/actionlint.yaml",
    ".github/actions",
    "examples",
    "schemas",
    "scripts",
)
# Rewritten under a non-block profile, at any depth; the rest is copied.
REWRITTEN_DIRS: tuple[str, ...] = (".github/workflows/", "examples/")
YAML_SUFFIXES = (".yml", ".yaml")
SKIPPED_PARTS = frozenset(
    {"__pycache__", ".pytest_cache", ".ruff_cache", ".mypy_cache"},
)
SKIPPED_SUFFIXES = frozenset({".pyc"})
TELEMETRY = """\
render-egress-profile: the audit profile keeps harden-runner, which sends data
to StepSecurity (prod.app-api.stepsecurity.io) even with telemetry disabled:
  - each DNS name the job resolves, with its IP address and a timestamp;
  - outbound connections: destination IP, port, domain, timestamp, status and
    the executable or container tool that made them, with hashes;
  - at start-up: repository owner and name, run identifiers and the job name.
No harden-runner input turns this off while the agent runs. If this data may
not go to a third party, generate with --profile none instead.
(Attempted transmission as read from harden-runner v2.22.3 and agent v0.18.0;
not measured on a live run. See docs/workflow-contract.md.)"""


def _load(name: str) -> ModuleType:
    """Load a sibling module of this script by name, once per process.

    Args:
        name: Module name; the file is ``<name>.py`` next to this script.

    Returns:
        The executed module, registered in ``sys.modules``.

    Raises:
        ImportError: When the file cannot be loaded.
    """
    if name in sys.modules:
        return sys.modules[name]
    loader = importlib.machinery.SourceFileLoader(name, str(HERE / f"{name}.py"))
    spec = importlib.util.spec_from_loader(name, loader)
    if spec is None:  # pragma: no cover - a source loader always yields a spec
        raise ImportError(f"no module spec for {name}")
    module = importlib.util.module_from_spec(spec)
    # dataclasses resolves the module through sys.modules while it executes.
    sys.modules[name] = module
    loader.exec_module(module)
    return module


# The rewrite module reads sync_inline_blocks from sys.modules: load it first.
_load("sync_inline_blocks")
REWRITE = _load("egress_profile_rewrite")
# The rewrite module is loaded by path, so these are typed as plain str here.
Profile = REWRITE.Profile
ProfileError = REWRITE.ProfileError


class UnsafeOutputError(ValueError):
    """A destination under ``--out`` is not safe to write or remove."""


def _inside(path: Path, parent: Path) -> bool:
    """Tell whether ``path`` is ``parent`` or below it.

    Spelling is compared first, then file identity: on a case-insensitive
    volume ``/x/SOURCE`` and ``/x/source`` are one directory with two
    spellings, and a hard-linked or bind-mounted directory has two paths.
    """
    if path == parent or parent in path.parents:
        return True
    if not parent.exists():
        return False
    for candidate in (path, *path.parents):
        try:
            if candidate.exists() and os.path.samefile(candidate, parent):
                return True
        except OSError:
            continue
    return False


def _walk(top: Path) -> list[Path]:
    """Return every file and symlink below ``top`` without following links."""
    if top.is_symlink() or top.is_file():
        return [top]
    found: list[Path] = []
    for directory, dirs, files in os.walk(top, followlinks=False):
        base = Path(directory)
        found.extend(base / name for name in files)
        # os.walk lists a symlink to a directory under dirs and skips it.
        found.extend(base / name for name in dirs if (base / name).is_symlink())
    return found


def surface_files(root: Path, *, links_ok: bool = False) -> list[str]:
    """Return the surface files under ``root`` as sorted POSIX paths.

    Args:
        root: Source tree or output directory.
        links_ok: Return symlinks as entries instead of failing on them.

    Returns:
        Every file in :data:`SURFACE`, minus caches.

    Raises:
        UnsafeOutputError: On a symlink, unless ``links_ok``.
    """
    found: list[str] = []
    for entry in SURFACE:
        top = root / entry
        if not top.exists() and not top.is_symlink():
            continue
        for path in _walk(top):
            relative = path.relative_to(root)
            skipped = SKIPPED_PARTS.intersection(relative.parts)
            if skipped or path.suffix in SKIPPED_SUFFIXES:
                continue
            if path.is_symlink() and not links_ok:
                raise UnsafeOutputError(f"{relative.as_posix()}: is a symlink")
            found.append(relative.as_posix())
    return sorted(found)


def rewritten(relative: str) -> bool:
    """Return whether a non-block profile rewrites this file."""
    return relative.startswith(REWRITTEN_DIRS) and relative.endswith(YAML_SUFFIXES)


def source_commit(root: Path) -> str:
    """Return the source tree's commit, or ``unknown`` outside a git checkout."""
    git = shutil.which("git")
    if git is None:
        return "unknown"
    result = subprocess.run(  # noqa: S603 - fixed argv, no shell
        [git, "-C", str(root), "rev-parse", "--verify", "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    )
    commit = result.stdout.strip()
    return commit if result.returncode == 0 and commit else "unknown"


def marker_bytes(profile: str, root: Path) -> bytes:
    """Return the marker file's contents: no timestamp, so output is stable."""
    data = {
        "generator": GENERATOR,
        "profile": str(profile),
        "source-commit": source_commit(root),
    }
    return (json.dumps(data, indent=2, sort_keys=True) + "\n").encode("utf-8")


def read_marker(directory: Path) -> dict[str, str] | None:
    """Return a directory's marker, or ``None`` when it has none.

    Raises:
        UnsafeOutputError: When the marker is a symlink, unreadable or not
            this generator's.
    """
    path = directory / MARKER
    if path.is_symlink():
        raise UnsafeOutputError(f"{path}: the marker is a symlink")
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise UnsafeOutputError(f"{path}: unreadable marker: {error}") from error
    if not isinstance(data, dict) or data.get("generator") != GENERATOR:
        raise UnsafeOutputError(f"{path}: not a marker of {GENERATOR}")
    return {str(key): str(value) for key, value in data.items()}


def render_tree(
    profile: str,
    root: Path = ROOT,
    log: Callable[[str], None] | None = None,
) -> dict[str, bytes]:
    """Render every surface file, and the marker, under one profile.

    Args:
        profile: Egress profile to generate (a :class:`Profile` value).
        root: Source tree to read.
        log: Receives one line per rewritten file with what changed.

    Returns:
        File contents keyed by POSIX path relative to the output root.

    Raises:
        ProfileError: When a step the profile removes by name is found
            nowhere in the tree (it was renamed, so it would be kept).
    """
    profile = Profile(profile)
    totals: dict[str, int] = {}
    bodies = REWRITE.inline_bodies(root) if profile is not Profile.BLOCK else {}
    tree: dict[str, bytes] = {}
    for relative in surface_files(root):
        data = (root / relative).read_bytes()
        if rewritten(relative):
            text, counts = REWRITE.rewrite(
                data.decode("utf-8"),
                profile,
                bodies,
                relative,
            )
            data = text.encode("utf-8")
            for why, n in (counts.removed or {}).items():
                totals[why] = totals.get(why, 0) + n
            if log is not None and (counts.notices or counts.removed):
                removed = ", ".join(
                    f"{n} {why}" for why, n in sorted((counts.removed or {}).items())
                )
                log(
                    f"{relative}: {counts.notices} notice steps;"
                    f" removed {removed or 'nothing'}",
                )
        tree[relative] = data
    missing = REWRITE.unused_removals(profile, totals)
    if missing:
        raise ProfileError(
            f"the {profile} profile removes these steps by name, but no step"
            f" has the name: {', '.join(sorted(missing))}",
        )
    tree[MARKER] = marker_bytes(profile, root)
    return tree


def check_destination(out: Path, relative: str, source: Path) -> None:
    """Refuse a destination that a write or removal could misdirect.

    Args:
        out: Resolved output root.
        relative: POSIX path below it.
        source: Resolved source tree.

    Raises:
        UnsafeOutputError: On a symlink at or above the destination (below
            ``out``), a path resolving outside ``out`` or inside the source
            tree, or an existing destination that is not a regular file.
    """
    parts = PurePosixPath(relative).parts
    if not parts or PurePosixPath(relative).is_absolute() or ".." in parts:
        raise UnsafeOutputError(f"{relative}: not a plain relative path")
    current = out
    for part in parts:
        current = current / part
        if current.is_symlink():
            raise UnsafeOutputError(f"{relative}: {current} is a symlink")
        if not current.exists():
            break
        if current != out / relative and not current.is_dir():
            raise UnsafeOutputError(f"{relative}: {current} is not a directory")
    target = (out / relative).resolve()
    if not _inside(target, out):
        raise UnsafeOutputError(f"{relative}: resolves outside {out}")
    if _inside(target, source):
        raise UnsafeOutputError(f"{relative}: resolves inside the source tree {source}")
    if (out / relative).exists() and not (out / relative).is_file():
        raise UnsafeOutputError(f"{relative}: exists and is not a regular file")
    if (out / relative).exists() and (out / relative).stat().st_nlink > 1:
        raise UnsafeOutputError(
            f"{relative}: has more than one hard link, so writing it would"
            " change a file outside the output directory",
        )


def write_file(path: Path, data: bytes, mode: int) -> None:
    """Write a file as a new inode, then move it into place.

    An existing destination is replaced, never opened: a symlink or a hard
    link there cannot redirect the write to another file.
    """
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(temporary, flags, mode)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
        temporary.chmod(mode)
        os.replace(temporary, path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def plan_write(tree: dict[str, bytes], out: Path, source: Path) -> list[str]:
    """Validate a write before it starts and return the files it removes.

    Args:
        tree: Rendered files keyed by relative path.
        out: Resolved output root.
        source: Resolved source tree.

    Returns:
        Surface files under ``out`` that are no longer generated.

    Raises:
        UnsafeOutputError: When ``out`` is not empty and carries no marker,
            or any destination fails :func:`check_destination`.
    """
    if out.is_dir() and any(out.iterdir()) and read_marker(out) is None:
        raise UnsafeOutputError(
            f"{out} is not empty and has no {MARKER}: write a copy into an empty"
            " directory or one this generator wrote (if an earlier run was"
            " interrupted, delete the directory and run again)",
        )
    if out.exists() and not out.is_dir():
        raise UnsafeOutputError(f"{out} is not a directory")
    existing = surface_files(out, links_ok=True) if out.is_dir() else []
    stale = [relative for relative in existing if relative not in tree]
    for relative in [*tree, *stale]:
        check_destination(out, relative, source)
    return stale


def write_tree(
    tree: dict[str, bytes],
    out: Path,
    root: Path = ROOT,
) -> list[str]:
    """Write a rendered tree and remove what it no longer holds.

    Every destination is validated first; nothing is written when one fails.

    Args:
        tree: Rendered files keyed by relative path.
        out: Resolved output directory; created when missing.
        root: Source tree whose file modes the copies keep.

    Returns:
        The stale files removed.
    """
    stale = plan_write(tree, out, root.resolve())
    for relative, data in tree.items():
        target = out / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        source = root / relative
        mode = source.stat().st_mode & 0o777 if source.is_file() else 0o644
        write_file(target, data, mode)
    for relative in stale:
        (out / relative).unlink()
        parent = (out / relative).parent
        while parent != out and parent.is_dir() and not any(parent.iterdir()):
            parent.rmdir()
            parent = parent.parent
    return stale


def check_tree(
    tree: dict[str, bytes],
    out: Path,
    source: Path = ROOT,
) -> list[str]:
    """Return the differences between a rendered tree and an output directory.

    A file reached through a symlink is reported, never read, so a copy that
    links back to the source cannot pass.

    Args:
        tree: Rendered files keyed by relative path, the marker included.
        out: Output directory to compare.
        source: Source tree, which no compared path may resolve into.

    Returns:
        One message per missing, differing, linked or stale file.
    """
    out = out.resolve()
    problems: list[str] = []
    for relative, data in tree.items():
        path = out / relative
        try:
            check_destination(out, relative, source.resolve())
        except UnsafeOutputError as error:
            problems.append(str(error))
            continue
        if not path.is_file():
            problems.append(f"{relative}: missing")
        elif path.read_bytes() != data:
            problems.append(f"{relative}: differs")
    if out.is_dir():
        problems.extend(
            f"{relative}: not generated (stale file)"
            for relative in surface_files(out, links_ok=True)
            if relative not in tree
        )
    return problems


def _refuse_source(root: Path) -> str | None:
    """Return why ``root`` cannot be a source, or ``None`` when it can."""
    try:
        marker = read_marker(root)
    except UnsafeOutputError as error:
        return str(error)
    if marker is not None and marker.get("profile") != str(Profile.BLOCK):
        return (
            f"{root} is a copy generated with the {marker.get('profile')} profile;"
            " generate from a block source (this repository or a release of it)"
        )
    return None


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument(
        "--profile",
        type=Profile,
        choices=list(Profile),
        default=Profile.BLOCK,
        help="egress profile to generate (default: block)",
    )
    parser.add_argument("--out", type=Path, required=True, help="output directory")
    parser.add_argument(
        "--check",
        action="store_true",
        help="compare --out with the rendered tree; exit 1 on drift",
    )
    return parser


def main(argv: Sequence[str] | None = None, root: Path = ROOT) -> int:
    """Parse arguments, then write or check the copy.

    Args:
        argv: Command-line arguments, defaulting to ``sys.argv[1:]``.
        root: Source tree to read (tests pass a scratch tree).

    Returns:
        Process exit code: 0 on success, 1 on drift or a source the profile
        cannot rewrite, 2 on a usage error or an unsafe source or output.
    """
    args = _parser().parse_args(argv)
    out = args.out.resolve()
    source = root.resolve()

    def fail(message: str, code: int) -> int:
        print(f"render-egress-profile: {message}", file=sys.stderr)
        return code

    if _inside(out, source) or _inside(source, out):
        return fail(
            f"--out {out} overlaps the source tree {root}; write the copy outside it",
            2,
        )
    refused = _refuse_source(source)
    if refused:
        return fail(refused, 2)
    try:
        tree = render_tree(args.profile, source, log=None if args.check else print)
    except (ProfileError, UnsafeOutputError) as error:
        # An unsafe source (a symlink) is 2; a shape the profile cannot
        # rewrite is 1.
        return fail(str(error), 1 if isinstance(error, ProfileError) else 2)
    if args.check:
        problems = check_tree(tree, out, source)
        for problem in problems:
            print(f"render-egress-profile: {problem}", file=sys.stderr)
        if problems:
            print(
                "run: uv run python scripts/ci/bootstrap/render-egress-profile.py"
                f" --profile {args.profile} --out {args.out}",
                file=sys.stderr,
            )
        return 1 if problems else 0
    try:
        stale = write_tree(tree, out, source)
    except UnsafeOutputError as error:
        return fail(f"{error}; nothing was written", 2)
    if args.profile is Profile.AUDIT:
        print(TELEMETRY, file=sys.stderr)
    print(
        f"wrote {len(tree)} files under {out} (profile {args.profile});"
        f" removed {len(stale)} stale files",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
