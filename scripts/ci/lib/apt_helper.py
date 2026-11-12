#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Run apt with bounded timeouts, bounded retries and a stable failure message.

Every ``apt-get`` call under ``scripts/ci`` goes through this helper (#1432),
so a dead mirror costs seconds instead of minutes. In run 42736549231 a shard
spent 292s in ``apt-get install`` after ``packages.microsoft.com`` failed to
connect; fixture runs 43037513862, 43038650658 and 43039395926 failed on
``Temporary failure resolving`` with no annotation the canary could read.

Commands:

- ``update``: ``apt-get update``.
- ``install [--no-install-recommends] PACKAGE...``: ``apt-get update`` then
  ``apt-get install -y`` (with ``--no-install-recommends`` when given).

Package names must pass ``is_package_name``: a plain Debian name with no
version (``=``), release (``/``) or architecture (``:``) qualifier and no
trailing ``-``, which apt reads as "remove". A trailing ``+`` (``g++``) is a
real name and allowed.

Nothing global is written. Every ``apt-get`` call carries its own settings as
``-o`` options:

- ``Acquire::Retries`` and ``Acquire::http(s)::Timeout``, so one unreachable
  host costs at most the timeout per retry, never the kernel's TCP timeout.
- ``APT::Get::List-Cleanup=0`` on ``update``, so the package lists of the
  sources left out below survive and a later plain ``apt-get`` in the same
  job still finds their packages.
- ``Dir::Etc::SourceParts``: a temporary directory, private to this
  invocation, holding copies of the ``sources.list.d`` files to use. A file
  is left out only when every URI of its enabled entries points at
  ``THIRD_PARTY_HOSTS`` (``packages.microsoft.com``, the only add-on
  repository on GitHub's Ubuntu images, and Launchpad PPAs). Hostless URIs
  (``file:``, ``cdrom:``, ``mirror+file:``) and any other host keep the file,
  and ``/etc/apt/sources.list`` and the distribution's own
  ``ubuntu.sources`` / ``debian.sources`` are always used. Set
  ``LGTM_CI_APT_KEEP_THIRD_PARTY_SOURCES=true`` to keep every file.

apt runs as root (through ``sudo`` unless already root); root reads the
user-owned temporary directory, and the helper removes it without ``sudo``
because apt never writes into it.

Retries and classification:

- Each apt call is retried with capped exponential backoff, but only when its
  output carries a DNS or network signature (``NETWORK_SIGNATURES``). Any
  other failure, such as ``Unable to locate package``, fails on its first
  attempt.
- A failure is classified from the output of its terminal attempt (for
  ``install``, also from the terminal ``update`` attempt when that never
  recovered). For a network failure exactly one annotation is printed:
  ``::error::`` followed by ``NETWORK_ERROR_MESSAGE``. The text is a contract
  with the external consumer canary (``infra_canary_signatures`` in
  ``scripts/ci/lib/infra-signatures.sh``); change it only together with that
  list.

Cancellation: each apt call runs in its own session (process group). The
handled signals are blocked while the call is started and registered, so a
signal never finds an unregistered child. On SIGTERM, SIGHUP or SIGINT the
helper ignores further signals, sends the signal to the call's process group
and waits up to ``CHILD_GRACE_SECONDS`` for the whole group to exit. If any
member is left (even after the group leader exited) the group gets SIGKILL.
It then removes the temporary directory and exits with 128 + the signal
number.

Limit: under ``sudo``, apt runs in sudo's own pty session, outside the
helper's process group. sudo relays SIGTERM, SIGHUP and SIGINT to apt, so
the normal path stops apt; but SIGKILL kills sudo, not apt. When escalation
to SIGKILL was needed, the helper prints a ``::warning::`` that apt may still
be running and holding the dpkg lock. It does not try to find apt itself.

Environment variables:
    LGTM_CI_APT_ATTEMPTS: Attempts per apt call (default 3, 1 to 5).
    LGTM_CI_APT_BACKOFF_SECONDS: First retry delay, doubled per retry
        (default 5, 0 to 30). Each delay is capped at 30s and all delays of
        one call at 60s.
    LGTM_CI_APT_TIMEOUT_SECONDS: ``Acquire::http(s)::Timeout`` (default 15,
        1 to 120).
    LGTM_CI_APT_ACQUIRE_RETRIES: ``Acquire::Retries`` (default 3, 0 to 5).
    LGTM_CI_APT_KEEP_THIRD_PARTY_SOURCES: ``true``, ``yes`` or ``1`` keeps every
        ``sources.list.d`` file.
    LGTM_CI_APT_ETC_DIR: apt configuration root (default ``/etc/apt``).
    LGTM_CI_APT_SUDO: Command prefix for apt. Unset: ``sudo`` unless already
        root. Empty: no prefix (tests).
    TMPDIR: Where the temporary directory is created. Its path must match
        ``SAFE_VALUE`` because it is passed to apt as an option value.

Usage:
    python3 -I scripts/ci/lib/apt_helper.py install musl-tools

Exit codes:
    0 - success
    2 - usage error (unknown command, invalid package name or environment
        value, unsafe temporary directory)
    128 + N - interrupted by signal N
    otherwise - the exit code of the failed apt call (never 0)
"""

from __future__ import annotations

import argparse
import io
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Iterator, Sequence
from contextlib import contextmanager, suppress
from dataclasses import dataclass
from functools import partial
from pathlib import Path
from types import FrameType
from urllib.parse import urlsplit

# Stable annotation text for a DNS or network failure. The canary matches it
# as the whole message, so it carries no host, count or exit code.
NETWORK_ERROR_MESSAGE = (
    "apt could not reach a package mirror (DNS or network failure) after all retries"
)

# Fixed strings apt prints when a mirror cannot be reached. "Could not
# resolve" (NXDOMAIN) is deliberately absent: it is what a host missing from
# the harden-runner allowlist looks like, and a retry never helps there.
NETWORK_SIGNATURES = (
    "Temporary failure resolving",
    "Could not connect",
    "Connection timed out",
    "Unable to connect",
)

# Known add-on repositories a job never needs. packages.microsoft.com is the
# only one on GitHub's Ubuntu 24.04 and 26.04 images (runs 42736549231 and
# 43039395926 fetch nothing else besides the Ubuntu archives).
THIRD_PARTY_HOSTS = frozenset(
    {"packages.microsoft.com", "ppa.launchpadcontent.net", "ppa.launchpad.net"},
)
# The distribution's own deb822 sources, kept whatever host they point at.
DISTRIBUTION_SOURCES = frozenset({"ubuntu.sources", "debian.sources"})

# Characters allowed in a path passed to apt as an option value.
SAFE_VALUE = re.compile(r"[A-Za-z0-9/._-]+")
# Debian policy package name with no version (=), release (/) or
# architecture (:) qualifier. A trailing "-" is refused: apt-get install
# reads "curl-" as "remove curl". A trailing "+" ("g++") is a real name.
PACKAGE_NAME = re.compile(r"[a-z0-9][a-z0-9+.-]*[a-z0-9+.]")
DIGITS = re.compile(r"[0-9]+")

SOURCES_PREFIX = "lgtm-ci-apt-sources-"
MAX_ATTEMPTS = 5
MAX_DELAY_SECONDS = 30.0
MAX_TOTAL_BACKOFF_SECONDS = 60.0
CHILD_GRACE_SECONDS = 10.0
HANDLED_SIGNALS = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)
EXIT_USAGE = 2
TRUE_VALUES = ("1", "true", "yes")
# Exit codes above this mean the child died by signal N (128+N).
SIGNAL_EXIT_BASE = 128
# apt's boolean parser (StringToBool) reads these words as false.
DISABLED_VALUES = frozenset({"no", "false", "0", "off", "without", "disable"})
# StringToBool first tries strtol(value, &end, 0) and uses it only when the
# whole value is that number (leading whitespace allowed): 0 or 1 decides, in
# decimal, octal or hex, with an optional sign. apt-pkg/contrib/strutl.cc.
_STRTOL_PREFIX = re.compile(r"\s*([+-]?)(0[xX][0-9a-fA-F]+|0[0-7]*|[1-9][0-9]*)")


def apt_false(value: str) -> bool:
    """Tell whether apt's StringToBool reads ``value`` as false.

    Args:
        value: A deb822 field value, such as ``Enabled``.

    Returns:
        True for a value that is wholly a number equal to 0, or a false word.
    """
    match = _STRTOL_PREFIX.fullmatch(value)
    if match:
        digits = match.group(2)
        if digits[:2].lower() == "0x":
            base = 16
        elif len(digits) > 1 and digits.startswith("0"):
            base = 8
        else:
            base = 10
        number = int(digits, base)
        if match.group(1) == "-":
            number = -number
        # strtol saturates at the 64-bit long range, and apt keeps the result
        # in a 32-bit int, so the value wraps: 4294967296 reads as 0.
        number = max(-(2**63), min(number, 2**63 - 1))
        number = (number + 2**31) % 2**32 - 2**31
        if number in (0, 1):
            return number == 0
    return value.strip().lower() in DISABLED_VALUES


_LIST_URI = re.compile(r"^\s*deb(?:-src)?\s+(?:\[[^\]]*\]\s+)?(\S+)")

# The apt call currently running, for the signal handler to signal.
_CHILDREN: list[subprocess.Popen[bytes]] = []


class UsageError(Exception):
    """Raised for an invalid command line or environment value."""


class Interrupted(Exception):
    """Raised by the signal handler once the apt call has exited.

    Attributes:
        signum: The signal received.
    """

    def __init__(self, signum: int) -> None:
        super().__init__(f"signal {signum}")
        self.signum = signum


@dataclass(frozen=True)
class Settings:  # pylint: disable=too-many-instance-attributes  # one per setting
    """Retry, timeout and source settings read from the environment.

    Attributes:
        attempts: Attempts per apt call.
        backoff_seconds: Delay before the first retry; doubled per retry.
        timeout_seconds: ``Acquire::http(s)::Timeout``.
        acquire_retries: ``Acquire::Retries``.
        keep_third_party: Keep every ``sources.list.d`` file.
        etc_dir: apt configuration root.
        tmp_dir: Directory for the filtered sources.
        sudo: Prefix for apt commands.
    """

    attempts: int = 3
    backoff_seconds: float = 5.0
    timeout_seconds: int = 15
    acquire_retries: int = 3
    keep_third_party: bool = False
    etc_dir: Path = Path("/etc/apt")
    tmp_dir: Path = Path("/tmp")
    sudo: tuple[str, ...] = ()


@dataclass
class Outcome:
    """Result of one apt call after its retries.

    Attributes:
        returncode: Exit code of the terminal attempt.
        network: Whether the terminal attempt's output had a network signature.
    """

    returncode: int
    network: bool


Runner = Callable[[Sequence[str]], tuple[int, list[str]]]
Sleeper = Callable[[float], None]


@dataclass
class Session:
    """Process hooks for one helper invocation.

    Attributes:
        runner: Executes a command and returns its exit code and output lines.
        sleeper: Sleeps between attempts.
    """

    runner: Runner
    sleeper: Sleeper


def _env_int(env: dict[str, str], name: str, default: int, low: int, high: int) -> int:
    """Read a bounded integer from the environment.

    Args:
        env: Environment mapping.
        name: Variable name.
        default: Value when unset or empty.
        low: Smallest accepted value.
        high: Largest accepted value.

    Returns:
        The parsed value.

    Raises:
        UsageError: When the value is not an integer in range.
    """
    raw = env.get(name, "").strip()
    if not raw:
        return default
    if not DIGITS.fullmatch(raw) or not low <= int(raw) <= high:
        raise UsageError(f"{name} must be an integer from {low} to {high}, got {raw!r}")
    return int(raw)


def is_package_name(name: str) -> bool:
    """Return whether ``name`` may be passed to ``apt-get install``.

    Args:
        name: A candidate package name.

    Returns:
        True for a plain package name (see ``PACKAGE_NAME``).
    """
    return PACKAGE_NAME.fullmatch(name) is not None


def require_safe(value: str, what: str) -> str:
    """Return ``value`` when it may be passed to apt as an option value.

    Args:
        value: The value.
        what: Its description, for the error.

    Returns:
        The value unchanged.

    Raises:
        UsageError: When it holds a character outside ``SAFE_VALUE``.
    """
    if not SAFE_VALUE.fullmatch(value):
        raise UsageError(
            f"{what} {value!r} may only contain A-Z a-z 0-9 / . _ -"
            " (it is passed to apt as an option value)",
        )
    return value


def load_settings(env: dict[str, str] | None = None) -> Settings:
    """Build the settings from the environment.

    Args:
        env: Environment mapping (defaults to ``os.environ``).

    Returns:
        The validated settings.
    """
    env = dict(os.environ if env is None else env)
    if "LGTM_CI_APT_SUDO" in env:
        sudo = tuple(shlex.split(env["LGTM_CI_APT_SUDO"]))
    else:
        sudo = () if os.geteuid() == 0 else ("sudo",)
    keep = env.get("LGTM_CI_APT_KEEP_THIRD_PARTY_SOURCES", "").strip().lower()
    tmp_dir = require_safe(tempfile.gettempdir(), "temporary directory")
    return Settings(
        attempts=_env_int(env, "LGTM_CI_APT_ATTEMPTS", 3, 1, MAX_ATTEMPTS),
        backoff_seconds=float(_env_int(env, "LGTM_CI_APT_BACKOFF_SECONDS", 5, 0, 30)),
        timeout_seconds=_env_int(env, "LGTM_CI_APT_TIMEOUT_SECONDS", 15, 1, 120),
        acquire_retries=_env_int(env, "LGTM_CI_APT_ACQUIRE_RETRIES", 3, 0, 5),
        keep_third_party=keep in TRUE_VALUES,
        etc_dir=Path(env.get("LGTM_CI_APT_ETC_DIR") or "/etc/apt"),
        tmp_dir=Path(tmp_dir),
        sudo=sudo,
    )


def backoff_delays(settings: Settings) -> list[float]:
    """Return the delays before each retry, capped per delay and in total.

    Args:
        settings: Helper settings.

    Returns:
        One delay per retry (``attempts - 1`` entries).
    """
    delays: list[float] = []
    total = 0.0
    for retry in range(settings.attempts - 1):
        delay = min(settings.backoff_seconds * 2**retry, MAX_DELAY_SECONDS)
        delay = min(delay, MAX_TOTAL_BACKOFF_SECONDS - total)
        delays.append(delay)
        total += delay
    return delays


def _log(message: str) -> None:
    """Print a log line to stderr in the style of ``lib/log.sh``."""
    print(f"[apt] {message}", file=sys.stderr, flush=True)


def has_network_signature(lines: Sequence[str]) -> bool:
    """Return whether any line carries a DNS or network failure signature.

    Args:
        lines: apt output lines.

    Returns:
        True when one of ``NETWORK_SIGNATURES`` occurs.
    """
    return any(sig in line for line in lines for sig in NETWORK_SIGNATURES)


def deb822_paragraphs(text: str) -> list[dict[str, str]]:
    """Parse deb822 text into paragraphs of lower-cased field names.

    Continuation lines (starting with a space or tab) extend the previous
    field's value on a new line; ``#`` lines are comments.

    Args:
        text: File contents.

    Returns:
        One mapping per paragraph.
    """
    paragraphs: list[dict[str, str]] = []
    current: dict[str, str] = {}
    key = ""
    for raw in text.splitlines():
        if raw.startswith("#"):
            continue
        if not raw.strip():
            if current:
                paragraphs.append(current)
            current, key = {}, ""
            continue
        if raw[0] in " \t":
            if key:
                current[key] += "\n" + raw.strip()
            continue
        name, sep, value = raw.partition(":")
        if not sep:
            continue
        key = name.strip().lower()
        current[key] = value.strip()
    if current:
        paragraphs.append(current)
    return paragraphs


def source_uris(text: str, deb822: bool) -> list[str]:
    """Extract the URIs of the enabled entries of one sources file.

    Args:
        text: File contents.
        deb822: True for a ``.sources`` file, False for a one-line ``.list``.

    Returns:
        Every URI of an entry apt would use, in file order. deb822
        paragraphs with ``Enabled: no`` are skipped.
    """
    if deb822:
        return [
            uri
            for paragraph in deb822_paragraphs(text)
            if not apt_false(paragraph.get("enabled", "yes"))
            for uri in paragraph.get("uris", "").split()
        ]
    uris: list[str] = []
    for line in text.splitlines():
        match = _LIST_URI.match(line)
        if match and not line.lstrip().startswith("#"):
            uris.append(match.group(1))
    return uris


def _host(uri: str) -> str:
    """Return the lower-cased host of a URI, or an empty string."""
    try:
        host = urlsplit(uri).hostname or ""
    except ValueError:
        return ""
    return host.rstrip(".")


def is_third_party(path: Path) -> bool:
    """Return whether a sources file only points at known third-party hosts.

    Args:
        path: A ``.list`` or ``.sources`` file.

    Returns:
        True when the file has enabled URIs and every one of them is on a
        ``THIRD_PARTY_HOSTS`` host. A hostless URI is never third party, and
        the distribution's own sources are always kept.
    """
    if path.name in DISTRIBUTION_SOURCES:
        return False
    text = path.read_text(encoding="utf-8", errors="replace")
    uris = source_uris(text, deb822=path.suffix == ".sources")
    return bool(uris) and all(_host(uri) in THIRD_PARTY_HOSTS for uri in uris)


def filter_sources(source_parts: Path, dest: Path, keep_third_party: bool) -> list[str]:
    """Copy the sources files apt should read into ``dest``.

    Args:
        source_parts: The real ``sources.list.d`` directory.
        dest: Empty directory that becomes ``Dir::Etc::SourceParts``.
        keep_third_party: Copy third-party files too.

    Returns:
        Names of the files left out, sorted.
    """
    skipped: list[str] = []
    if not source_parts.is_dir():
        return skipped
    for path in sorted(source_parts.iterdir()):
        if path.suffix not in (".list", ".sources") or not path.is_file():
            continue
        if not keep_third_party and is_third_party(path):
            skipped.append(path.name)
            continue
        shutil.copyfile(path, dest / path.name)
    return skipped


def option_args(settings: Settings, source_parts: Path) -> list[str]:
    """Return the ``-o`` options every apt call carries.

    Args:
        settings: Helper settings.
        source_parts: Filtered ``Dir::Etc::SourceParts`` directory.

    Returns:
        ``-o key=value`` arguments.
    """
    timeout = str(settings.timeout_seconds)
    options = [
        ("Acquire::Retries", str(settings.acquire_retries)),
        ("Acquire::http::Timeout", timeout),
        ("Acquire::https::Timeout", timeout),
        ("DPkg::Lock::Timeout", "60"),
        ("Dir::Etc::SourceParts", require_safe(str(source_parts), "sources path")),
    ]
    args: list[str] = []
    for key, value in options:
        args.extend(["-o", f"{key}={value}"])
    return args


def _group_alive(pgid: int) -> bool:
    """Return whether any process of the group still exists."""
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def stop_group(child: subprocess.Popen[bytes], signum: int) -> bool:
    """Signal a call's process group; SIGKILL whatever outlives the grace.

    Args:
        child: The group leader (started with ``start_new_session``).
        signum: The signal to forward first.

    Returns:
        True when the group had to be killed with SIGKILL.
    """
    pgid = child.pid
    # EPERM: a member is not ours (root apt under sudo without a pty) or,
    # on macOS, only zombies are left; the others are still signalled.
    with suppress(ProcessLookupError, PermissionError):
        os.killpg(pgid, signum)
    deadline = time.monotonic() + CHILD_GRACE_SECONDS
    while time.monotonic() < deadline:
        if child.poll() is not None and not _group_alive(pgid):
            return False
        time.sleep(0.05)
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        child.poll()
        return False
    except PermissionError:
        pass
    with suppress(subprocess.TimeoutExpired):
        child.wait(timeout=CHILD_GRACE_SECONDS)
    return True


def _on_signal(signum: int, _frame: FrameType | None) -> None:
    """Stop the running apt call's process group, then unwind.

    Raises:
        Interrupted: Always, so the temporary directory is removed.
    """
    for handled in HANDLED_SIGNALS:
        signal.signal(handled, signal.SIG_IGN)
    for child in list(_CHILDREN):
        if stop_group(child, signum):
            print(
                f"::warning::apt did not stop within {CHILD_GRACE_SECONDS:g}s of"
                f" signal {signum} and was killed; under sudo apt may still be"
                " running and holding the dpkg lock",
                flush=True,
            )
    raise Interrupted(signum)


def stream(argv: Sequence[str]) -> tuple[int, list[str]]:
    """Run a command in its own session, echoing and capturing its output.

    Args:
        argv: Command and arguments.

    Returns:
        Exit code and output lines.
    """
    lines: list[str] = []
    # Block the handled signals until the child is registered, so the handler
    # always finds it; the child itself starts with the original mask.
    mask = signal.pthread_sigmask(signal.SIG_BLOCK, HANDLED_SIGNALS)
    try:
        proc = subprocess.Popen(  # pylint: disable=consider-using-with,subprocess-popen-preexec-fn
            list(argv),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            preexec_fn=partial(signal.pthread_sigmask, signal.SIG_SETMASK, mask),
        )
        _CHILDREN.append(proc)
    except FileNotFoundError as error:
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        print(f"{argv[0]}: {error.strerror}", flush=True)
        return 127, [str(error)]
    except BaseException:
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        raise
    try:
        with proc:
            # A signal that arrived while blocked is handled here.
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)
            # Decoded here rather than with Popen(text=True, errors=...): a bad
            # byte must not abort, and newline=None keeps universal newlines,
            # so apt's \r progress output still splits into lines.
            text = (
                io.TextIOWrapper(
                    proc.stdout,
                    encoding="utf-8",
                    errors="replace",
                    newline=None,
                )
                if proc.stdout is not None
                else ()
            )
            for line in text:
                sys.stdout.write(line)
                sys.stdout.flush()
                lines.append(line.rstrip("\n"))
            returncode = proc.wait()
            # Popen reports death by signal N as -N; use the shell's 128+N.
            if returncode < 0:
                returncode = SIGNAL_EXIT_BASE - returncode
    finally:
        _CHILDREN.remove(proc)
    return returncode, lines


def run_with_retries(
    label: str,
    argv: Sequence[str],
    settings: Settings,
    session: Session,
    *,
    warnings_fail: bool = False,
) -> Outcome:
    """Run one apt call, retrying only network failures.

    Args:
        label: Name for log lines, such as ``apt-get update``.
        argv: Command and arguments.
        settings: Helper settings.
        session: Process hooks.
        warnings_fail: Treat a zero exit with a network signature as a failed
            attempt (``apt-get update`` exits 0 when indexes fail to fetch).

    Returns:
        The terminal attempt's outcome.
    """
    delays = backoff_delays(settings)
    outcome = Outcome(returncode=1, network=False)
    for attempt in range(1, settings.attempts + 1):
        code, lines = session.runner(argv)
        # A signal death (128+N; apt itself never exits above 128) is never a
        # network failure, whatever apt printed first: no retry, no annotation.
        killed = code > SIGNAL_EXIT_BASE
        network = not killed and has_network_signature(lines)
        outcome = Outcome(returncode=code, network=network)
        succeeded = code == 0 and not (warnings_fail and outcome.network)
        if succeeded or not outcome.network:
            return outcome
        if attempt < settings.attempts:
            delay = delays[attempt - 1]
            _log(
                f"{label}: DNS or network failure"
                f" (attempt {attempt}/{settings.attempts}); retrying in {delay:g}s",
            )
            session.sleeper(delay)
    _log(f"{label}: DNS or network failure on all {settings.attempts} attempts")
    return outcome


def fail(label: str, code: int, network: bool) -> int:
    """Print the single failure annotation and return a non-zero exit code.

    Args:
        label: Name of the failed call.
        code: Exit code of its terminal attempt.
        network: Whether the failure is classified as DNS or network.

    Returns:
        The exit code to leave with.
    """
    code = code or 1
    if network:
        print(f"::error::{NETWORK_ERROR_MESSAGE}", flush=True)
    else:
        print(
            f"::error::{label} failed with exit code {code}"
            " (no DNS or network failure in its output)",
            flush=True,
        )
    return code


def apt_get(settings: Settings, source_parts: Path, *args: str) -> list[str]:
    """Build an ``apt-get`` command line with the helper's options."""
    return [
        *settings.sudo,
        "env",
        "DEBIAN_FRONTEND=noninteractive",
        # English messages, so the network signatures match on any runner.
        "LC_ALL=C",
        "apt-get",
        *option_args(settings, source_parts),
        *args,
    ]


@contextmanager
def filtered_sources(settings: Settings) -> Iterator[Path]:
    """Yield a private ``Dir::Etc::SourceParts`` without third-party files.

    Args:
        settings: Helper settings.

    Yields:
        The filtered directory; removed on exit, signals included.
    """
    tmp_root = settings.tmp_dir
    with tempfile.TemporaryDirectory(prefix=SOURCES_PREFIX, dir=tmp_root) as tmp:
        dest = Path(tmp)
        skipped = filter_sources(
            settings.etc_dir / "sources.list.d",
            dest,
            settings.keep_third_party,
        )
        if skipped:
            _log(
                "left out third-party sources: "
                + ", ".join(skipped)
                + " (set LGTM_CI_APT_KEEP_THIRD_PARTY_SOURCES=true to keep them)",
            )
        yield dest


def update_args() -> list[str]:
    """Return the ``apt-get update`` arguments.

    ``APT::Get::List-Cleanup=0`` keeps the lists of the sources left out of
    this call, which apt would otherwise delete.
    """
    return ["-o", "APT::Get::List-Cleanup=0", "update", "-q"]


def cmd_update(settings: Settings, session: Session) -> int:
    """Run ``apt-get update``.

    Stricter than ``install`` on purpose: an index that failed to refresh
    leaves the lists stale, so a later install could pick old versions or
    miss packages. ``update`` therefore fails on fetch warnings, while
    ``install`` (which only reads the lists) trusts apt's exit code.
    """
    with filtered_sources(settings) as parts:
        outcome = run_with_retries(
            "apt-get update",
            apt_get(settings, parts, *update_args()),
            settings,
            session,
            warnings_fail=True,
        )
    if outcome.returncode != 0 or outcome.network:
        return fail("apt-get update", outcome.returncode, outcome.network)
    return 0


def cmd_install(
    settings: Settings,
    packages: Sequence[str],
    session: Session,
    *,
    no_install_recommends: bool = False,
) -> int:
    """Run ``apt-get update`` then ``apt-get install -y`` for the packages.

    An ``install`` failure is a network failure when its terminal attempt
    shows one, or when the terminal ``update`` attempt never recovered from
    one (the package lists are then stale). A network failure that a later
    ``update`` attempt recovered from does not count.
    """
    with filtered_sources(settings) as parts:
        update = run_with_retries(
            "apt-get update",
            apt_get(settings, parts, *update_args()),
            settings,
            session,
            warnings_fail=True,
        )
        if update.returncode != 0:
            return fail("apt-get update", update.returncode, update.network)
        if update.network:
            _log("apt-get update left some indexes stale; installing anyway")
        recommends = ["--no-install-recommends"] if no_install_recommends else []
        install = run_with_retries(
            "apt-get install",
            apt_get(settings, parts, "install", "-y", "-q", *recommends, *packages),
            settings,
            session,
        )
    if install.returncode != 0:
        # A signal death is never a network failure, even after stale lists.
        killed = install.returncode > SIGNAL_EXIT_BASE
        network = not killed and (install.network or update.network)
        return fail("apt-get install", install.returncode, network)
    return 0


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    """Parse the command line.

    Raises:
        UsageError: On an invalid command line or package name.
    """
    parser = argparse.ArgumentParser(
        prog="apt_helper.py",
        description="Run apt with bounded timeouts and retries.",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("update", help="apt-get update")
    install = sub.add_parser("install", help="apt-get update, then apt-get install -y")
    install.add_argument("--no-install-recommends", action="store_true")
    install.add_argument("packages", nargs="+")
    try:
        args = parser.parse_args(list(argv))
    except SystemExit as exit_:
        raise UsageError("invalid arguments") from exit_
    if args.command == "install":
        bad = [p for p in args.packages if not is_package_name(p)]
        if bad:
            raise UsageError(f"invalid package names: {' '.join(map(repr, bad))}")
    return args


def main(
    argv: Sequence[str] | None = None,
    env: dict[str, str] | None = None,
    runner: Runner = stream,
    sleeper: Sleeper = time.sleep,
) -> int:
    """Entry point.

    Args:
        argv: Arguments (defaults to ``sys.argv[1:]``).
        env: Environment (defaults to ``os.environ``).
        runner: Executes commands (injected by tests).
        sleeper: Sleeps between attempts (injected by tests).

    Returns:
        The process exit code.
    """
    try:
        args = parse_args(sys.argv[1:] if argv is None else argv)
        settings = load_settings(env)
    except UsageError as error:
        _log(f"usage error: {error}")
        return EXIT_USAGE
    session = Session(runner=runner, sleeper=sleeper)
    previous = {sig: signal.signal(sig, _on_signal) for sig in HANDLED_SIGNALS}
    try:
        if args.command == "update":
            return cmd_update(settings, session)
        return cmd_install(
            settings,
            args.packages,
            session,
            no_install_recommends=args.no_install_recommends,
        )
    except UsageError as error:
        _log(f"usage error: {error}")
        return EXIT_USAGE
    except Interrupted as interrupted:
        _log(f"interrupted by signal {interrupted.signum}; cleaned up")
        return 128 + interrupted.signum
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


if __name__ == "__main__":
    sys.exit(main())
