#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""The update record behind ``apt_helper.py install --no-update`` (#1664).

The Playwright runner runs the helper's ``update``, then ``install
--no-update``, as two calls. The install may skip its update only when the
indexes it is about to read are exactly the ones the update fetched. So a
good update writes a record, ``update-identity``, into the stable per-user
directory (``apt_failover.lists_dir``), with the same ownership, mode and
atomic-replace checks as the mirror lists, and the install compares it with
its own identity.

The identity (``source_identity``) is a sha256 over two things:

- every sources file apt reads in the call: the private ``.list`` and
  ``.sources`` copies by name and bytes, and the main list (its private copy,
  or ``/etc/apt/sources.list``);
- apt's effective index configuration, from ``apt-config dump`` of
  ``CONFIG_KEYS`` (``Dir``, which holds ``Dir::State`` and
  ``Dir::State::lists``, the architectures and the index targets), run with
  the same ``sudo`` prefix and ``-o`` options as the call's apt command. The
  two per-call paths, ``Dir::Etc::SourceParts`` and
  ``Dir::Etc::SourceList``, are left out; their files are hashed instead.
  ``apt-config`` runs with a deadline; when it fails or times out, the
  identity is unknown, no record is written and an install updates first.

apt-get reads its own ``Binary::apt-get::*`` overrides, which apt-config
does not apply: apt sets ``Binary`` from ``argv[0]`` and moves
``Binary::<name>`` into the root before it parses ``-o`` options
(``ParseCommandLine`` in ``apt-private/private-cmndline.cc``, apt 2.4.13,
2.8.4 and 3.2.1), so ``-o Binary=apt-get`` comes too late and apt-config has
no such switch. So the dump also covers the whole ``Binary`` tree, where
apt-config leaves ``Binary::apt-get`` untouched, and any change there
changes the identity. apt-config's own ``Binary::apt-config::*`` overrides
are moved into its root and could shadow a global value apt-get still
reads; ``MoveSubTree`` (``apt-pkg/contrib/configuration.cc``) leaves an
empty ``Binary::apt-config`` item behind, which the dump prints, so its
presence makes the identity unknown.

A record is written only after an ``update`` that exited 0 with no network
signature and printed no ``W:``, ``E:`` or ``Err:`` line (``incomplete``).
apt reports a partly failed update with exit 0 and such a line (``W: Failed
to fetch``, ``W: Some index files failed to download``) under its default
``APT::Update::Error-Mode``. Any warning counts, recognised or not: a
harmless one costs one more update. Every update removes the record before
it starts.

Loaded by ``apt_helper.py`` under ``python3 -I`` on any runner ``python3``
(3.10 on ``ubuntu-22.04``): standard library only.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
from collections.abc import Callable, Sequence
from pathlib import Path

try:
    import apt_failover
except ImportError:  # python3 -I leaves this lib/ directory off sys.path
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import apt_failover

RECORD = "update-identity"
# apt's effective index configuration: where the lists live and which
# indexes (architectures, targets, languages) an update fetches.
CONFIG_KEYS = (
    "Binary",
    "Dir",
    "APT::Architecture",
    "APT::Architectures",
    "Acquire::IndexTargets",
    "Acquire::Languages",
)
# apt-config's own binary-specific tree: present means apt-config's view
# may differ from apt-get's, so the configuration counts as unknown.
OWN_BINARY = "binary::apt-config"
# Per-call paths in the dump; the files behind them are hashed instead.
PER_CALL_KEYS = ("dir::etc::sourceparts", "dir::etc::sourcelist")
# Upper bound of one apt-config call, cut further to the run's budget.
CONFIG_TIMEOUT_SECONDS = 10.0
# apt's message prefixes for warnings, errors and failed items. Matched as
# output arrives too, so a line the capture cap evicted still counts.
INCOMPLETE_MARKERS = ("W:", "E:", "Err:")
# Runs a command with a deadline and returns its exit code and stdout.
Query = Callable[[Sequence[str], float], tuple[int, str]]


def incomplete(lines: Sequence[str]) -> bool:
    """Return whether apt printed a warning, an error or a failed item."""
    return any(line.lstrip().startswith(INCOMPLETE_MARKERS) for line in lines)


def quiet_run(argv: Sequence[str], timeout: float) -> tuple[int, str]:
    """Run ``argv`` without a terminal or echo; return its exit code and stdout.

    Raises:
        OSError: When it cannot start.
        subprocess.TimeoutExpired: When ``timeout`` passes (the child is
            killed first).
    """
    done = subprocess.run(  # noqa: S603 - a fixed apt-config command line
        list(argv),
        stdin=subprocess.DEVNULL,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    return done.returncode, done.stdout.decode("utf-8", errors="replace")


def apt_config(argv: Sequence[str], budget: float | None, run: Query) -> str | None:
    """Return apt's effective index configuration, or None when unknown.

    Args:
        argv: The ``apt-config`` command with the call's prefix and options.
        budget: Seconds left in the helper run (None: no budget).
        run: Runs the command (``quiet_run``, or a test's fake).

    Returns:
        The dump of ``CONFIG_KEYS`` without ``PER_CALL_KEYS``, or None when
        ``apt-config`` fails, times out, has no time left to run, or has a
        ``Binary::apt-config`` tree of its own.
    """
    timeout = CONFIG_TIMEOUT_SECONDS
    if budget is not None:
        timeout = min(timeout, budget)
    if timeout <= 0:
        return None
    try:
        code, out = run([*argv, "dump", *CONFIG_KEYS], timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if code != 0 or not out.strip():
        return None
    lines = out.splitlines()
    if any(line.lower().startswith(OWN_BINARY) for line in lines):
        return None
    return "\n".join(x for x in lines if not x.lower().startswith(PER_CALL_KEYS))


def source_identity(parts: Path, etc_dir: Path, config: str | None) -> str:
    """Return a sha256 of the call's sources and apt's index configuration.

    Args:
        parts: The helper's private ``Dir::Etc::SourceParts`` directory.
        etc_dir: ``/etc/apt`` (or the test root).
        config: ``apt_config`` of this call, or None when unknown.

    Returns:
        The hex digest, or "" when the configuration is unknown or a sources
        file cannot be read (``refresh_reason`` then asks for an update).
    """
    if config is None:
        return ""
    digest = hashlib.sha256()
    try:
        copies = [p for p in parts.iterdir() if p.suffix in (".list", ".sources")]
        private = parts / apt_failover.MAIN_DIR / apt_failover.MAIN_LIST
        entries = [(f"part:{p.name}", p) for p in sorted(copies) if p.is_file()]
        main = private if private.is_file() else etc_dir / apt_failover.MAIN_LIST
        entries.append(("main", main))
        for label, path in entries:
            data = path.read_bytes() if path.is_file() else b""
            digest.update(f"{label}\0{len(data)}\0".encode())
            digest.update(data)
    except OSError:
        return ""
    data = config.encode("utf-8")
    digest.update(f"config\0{len(data)}\0".encode())
    digest.update(data)
    return digest.hexdigest()


def forget_update(directory: Path) -> str:
    """Remove the update record before an update; return why it failed, or ""."""
    try:
        fd = apt_failover.open_existing(directory)
    except FileNotFoundError:
        return ""
    except (apt_failover.ListsRefused, OSError) as error:
        return str(error)
    try:
        os.unlink(RECORD, dir_fd=fd)
        os.fsync(fd)
    except FileNotFoundError:
        pass
    except OSError as error:
        return str(error)
    finally:
        os.close(fd)
    return ""


def record_update(directory: Path, identity: str) -> str:
    """Record ``identity`` after a complete update; return why it failed, or ""."""
    if not identity:
        return "this call's sources or apt configuration could not be read"
    try:
        fd = apt_failover.open_dir(directory)
    except (apt_failover.ListsRefused, OSError) as error:
        return str(error)
    try:
        apt_failover.replace_entry(fd, RECORD, f"{identity}\n".encode())
        os.fsync(fd)
    except OSError as error:
        return str(error)
    finally:
        os.close(fd)
    return ""


def refresh_reason(directory: Path, identity: str) -> str:
    """Return why ``install --no-update`` must update first, or "" when it may skip.

    It may skip only when a trusted record holds exactly ``identity``: in
    doubt, update.

    Args:
        directory: ``apt_failover.lists_dir(root)``, holding the record.
        identity: ``source_identity`` of this call ("" when unknown).

    Returns:
        The reason to update, or "".
    """
    if not identity:
        return "this call's sources or apt configuration could not be read"
    try:
        recorded = _recorded(directory)
    except (apt_failover.ListsRefused, OSError) as error:
        return f"the update record cannot be trusted ({error})"
    if recorded is None:
        return f"no update is recorded in {directory}"
    if recorded != f"{identity}\n".encode():
        return "the last recorded update used other sources or apt configuration"
    return ""


def _recorded(directory: Path) -> bytes | None:
    """Return the checked update record's bytes, or None when there is none."""
    try:
        fd = apt_failover.open_existing(directory)
    except FileNotFoundError:
        return None
    try:
        found = apt_failover.read_entry(fd, RECORD)
    finally:
        os.close(fd)
    return None if found is None else found[1]
