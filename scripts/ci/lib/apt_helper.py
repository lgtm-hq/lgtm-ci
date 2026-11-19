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
- ``install [--no-install-recommends] [--no-update] PACKAGE...``:
  ``apt-get update`` then ``apt-get install -y`` (with
  ``--no-install-recommends`` when given). ``--no-update`` skips the update
  for a caller that ran the helper's ``update`` just before.

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
  invocation, holding copies of the ``sources.list.d`` files to use
  (``apt_sources.py``). A file
  is left out only when every URI of its enabled entries points at
  ``THIRD_PARTY_HOSTS`` (``packages.microsoft.com``, the only add-on
  repository on GitHub's Ubuntu images, and Launchpad PPAs). Hostless URIs
  (``file:``, ``cdrom:``, ``mirror+file:``) and any other host keep the file,
  and ``/etc/apt/sources.list`` and the distribution's own
  ``ubuntu.sources`` / ``debian.sources`` are always used. Set
  ``LGTM_CI_APT_KEEP_THIRD_PARTY_SOURCES=true`` to keep every file.
- In those copies, Ubuntu archive and security URIs (the image's
  ``mirror+file:`` list, an EC2 or other regional ``*.archive.ubuntu.com``
  host egress may not allow, and an allowed Canonical archive or security
  host) name a mirror list of the allowed archive hosts instead
  (``apt_mirrors.py``, ``apt_failover.py``, #1661, #1664): one for the
  archive suites, one for the ``*-security`` suites, at a stable per-user
  path (``<tmp>/lgtm-ci-apt-mirrors-<euid>/``) shared by every call of the
  job, so apt fails over between allowed hosts only and keeps one source
  identity for its indexes. ``/etc/apt/sources.list`` gets the same rewrite in a private
  copy (``main/sources.list``, passed as ``Dir::Etc::SourceList``) when any
  of its URIs changes; the real file is never written. Suites, components
  and ``Signed-By`` stay. This happens only when harden-runner's agent
  configuration proves block-mode egress; otherwise, and on any error
  reading it, the sources stay as they are. When the lists cannot be used
  (an untrusted stable directory, a write error, a directory ``_apt``
  cannot search), allowed hosts stay and other Ubuntu URIs name their first
  allowed host directly (#1661). One log line names the overridden URIs,
  each list and its hosts, or why there are no lists or no rewrite.
- ``install --no-update`` skips the update only on a trusted record of the
  last good update with this call's exact sources (``apt_failover``);
  otherwise it updates first, in the same call and budget.

apt runs as root (through ``sudo`` unless already root); root reads the
user-owned temporary directory, and the helper removes it without ``sudo``
because apt never writes into it. The mirror lists are not in it: apt's
``file`` and ``mirror`` methods read them as ``_apt``, so their own
directory is ``0711`` (searchable, not listable) and the lists ``0644``,
and they stay for the rest of the job.

Deadlines (#1571): the connection timeouts above never fire for a mirror
that stalls or trickles mid-transfer: in fixture run 43581374963
``apt-get update`` printed nothing for 24 minutes until the job was
cancelled. So each apt call attempt has a wall-clock deadline
(``LGTM_CI_APT_CALL_TIMEOUT_SECONDS``) and one helper run has a wall-clock
budget across all its calls, attempts and backoff
(``LGTM_CI_APT_TOTAL_TIMEOUT_SECONDS``). An attempt's deadline is the call
deadline cut to the budget left after reserving the time to end it
(``apt_stream.stop_reserve()``: up to ``2 * CHILD_GRACE_SECONDS`` = 20s to
stop the group plus ``ECHO_FLUSH_SECONDS`` = 1s to drain the echo, 21s); no
attempt starts with less than ``MIN_ATTEMPT_SECONDS`` of it. When the
deadline passes, the call's process group is stopped as on a signal
(SIGTERM, then SIGKILL after ``apt_stream.CHILD_GRACE_SECONDS``) and the
attempt counts as failed with exit code ``EXIT_TIMED_OUT``. A helper run
therefore ends within the budget plus process start-up (300s by default);
its final annotation may wait up to ``apt_stream.EMIT_SECONDS`` (2s) more
for a stdout that is not being read. The call runs and is read by
``apt_stream.py``, which never blocks on stdout.

The defaults fit two full attempts and a shorter third into one run: real
apt calls take at most about 45s (``update`` 43s, the Playwright system
packages 34s), so a 100s call deadline leaves room to spare, and with the
default 5s and 10s backoff a run of stalls costs 100 + 21, 5, 100 + 21, 10,
then a 22s third attempt + 21 = 300s. ``install`` without ``--no-update``
spends one budget on both calls; a stalled ``update`` (121s) still leaves
the ``install`` a full attempt.

Retries and classification:

- Each apt call is retried with capped exponential backoff, but only when its
  output carries a DNS or network signature (``NETWORK_SIGNATURES``) or it hit
  its deadline. Any other failure, such as ``Unable to locate package``, fails
  on its first attempt.
- A failure is classified only from the output of its own terminal attempt;
  stale lists from an earlier ``update`` never make an ``install`` error a
  network failure, and a signal death (exit above 128) never is one. For a
  network failure exactly one annotation is printed:
  ``::error::`` followed by ``NETWORK_ERROR_MESSAGE``. The text is a contract
  with the external consumer canary (``infra_canary_signatures`` in
  ``scripts/ci/lib/infra-signatures.sh``); change it only together with that
  list.
- When the terminal attempt hit its deadline, or the budget had no room for
  an attempt, exactly one annotation is printed: ``::error::`` followed by
  ``TIMEOUT_ERROR_MESSAGE`` filled in with the call (``apt-get update`` or
  ``apt-get install``) and both limits, such as ``apt-get update timed out
  (100s per attempt, 300s per helper run)``. It is not a canary signature
  yet: the signature rules need the message seen in a real run.

Cancellation: each apt call runs in its own session (process group). The
handled signals are blocked while the call is started and registered, so a
signal never finds an unregistered child. On SIGTERM, SIGHUP or SIGINT the
helper ignores further signals, sends the signal to the call's process group
and waits up to ``apt_stream.CHILD_GRACE_SECONDS`` for the whole group to
exit. If any
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
    LGTM_CI_APT_MIRROR_ACQUIRE_RETRIES: ``Acquire::Retries`` when the
        private mirror lists are in use (default 1, 0 to 5, never above
        ``LGTM_CI_APT_ACQUIRE_RETRIES``): apt spends every retry on the
        same mirror before it tries the next (#1664).
    LGTM_CI_APT_CALL_TIMEOUT_SECONDS: Wall-clock deadline of each apt call
        attempt (default 100, 1 to 3600), cut to the budget left.
    LGTM_CI_APT_TOTAL_TIMEOUT_SECONDS: Wall-clock budget of one helper run,
        stopping included (default 300, 30 to 3600). ``install`` without
        ``--no-update`` spends one budget on both calls.
    LGTM_CI_APT_KEEP_THIRD_PARTY_SOURCES: ``true``, ``yes`` or ``1`` keeps every
        ``sources.list.d`` file.
    LGTM_CI_APT_KEEP_MIRRORS: ``true``, ``yes`` or ``1`` leaves Ubuntu archive
        URIs as they are (no rewrite to allowed hosts).
    LGTM_CI_APT_EGRESS_CONFIG: Tests only; never set it in a workflow. The
        harden-runner agent configuration that proves block-mode egress and
        holds the allowed endpoints (default ``/home/agent/agent.json``).
    LGTM_CI_APT_MACHINE: Tests only; never set it in a workflow. Machine name
        that decides whether the amd64/i386 archive applies (default
        ``platform.machine()``).
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
    124 - an apt call's last attempt hit its deadline, or the budget left
        no room for an attempt
    128 + N - interrupted by signal N
    otherwise - the exit code of the failed apt call (never 0)
"""

from __future__ import annotations

import argparse
import os
import platform
import re
import shlex
import shutil
import signal
import sys
import tempfile
import time
from collections.abc import Callable, Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass, replace
from pathlib import Path

HERE = str(Path(__file__).resolve().parent)
if HERE not in sys.path:  # python3 -I leaves this lib/ directory off sys.path
    sys.path.insert(0, HERE)

# pylint: disable=wrong-import-position
import apt_failover  # noqa: E402
import apt_mirrors  # noqa: E402
import apt_sources  # noqa: E402
import apt_stream  # noqa: E402

# pylint: enable=wrong-import-position

# Re-bound with their types: mypy does not follow the bootstrapped import.
EXIT_TIMED_OUT: int = apt_stream.EXIT_TIMED_OUT
SIGNAL_EXIT_BASE: int = apt_stream.SIGNAL_EXIT_BASE
HANDLED_SIGNALS: tuple[signal.Signals, ...] = apt_stream.HANDLED_SIGNALS
Interrupted = apt_stream.Interrupted
on_signal = apt_stream.on_signal
emit = apt_stream.emit
# Sources files: parsed, filtered and rewritten in apt_sources.py.
THIRD_PARTY_HOSTS = apt_sources.THIRD_PARTY_HOSTS
DISTRIBUTION_SOURCES = apt_sources.DISTRIBUTION_SOURCES
apt_false = apt_sources.apt_false
deb822_paragraphs = apt_sources.deb822_paragraphs
source_uris = apt_sources.source_uris
is_third_party = apt_sources.is_third_party
filter_sources = apt_sources.filter_sources

# Stable annotation text for a DNS or network failure. The canary matches it
# as the whole message, so it carries no host, count or exit code.
NETWORK_ERROR_MESSAGE = (
    "apt could not reach a package mirror (DNS or network failure) after all retries"
)

# Stable annotation text for an apt call whose terminal attempt hit its
# deadline, or that had no budget left to start one. Filled in with the call
# ("apt-get update" or "apt-get install") and the two configured limits; no
# host, count or elapsed time, so a canary can match it later.
TIMEOUT_ERROR_MESSAGE = (
    "{label} timed out ({call}s per attempt,"  # no line break in the message
    " {total}s per helper run)"
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
# Two full attempts and a shorter third fit in the default budget (see above).
DEFAULT_CALL_TIMEOUT_SECONDS = 100
MAX_CALL_TIMEOUT_SECONDS = 3600
DEFAULT_TOTAL_TIMEOUT_SECONDS = 300
MIN_TOTAL_TIMEOUT_SECONDS = 30
MAX_TOTAL_TIMEOUT_SECONDS = 3600
# An attempt starts only with at least this many seconds of budget for it.
MIN_ATTEMPT_SECONDS = 5.0
EXIT_USAGE = 2
TRUE_VALUES = ("1", "true", "yes")


class UsageError(Exception):
    """Raised for an invalid command line or environment value."""


@dataclass(frozen=True)
class Settings:  # pylint: disable=too-many-instance-attributes  # one per setting
    """Retry, timeout and source settings read from the environment.

    Attributes:
        attempts: Attempts per apt call.
        backoff_seconds: Delay before the first retry; doubled per retry.
        timeout_seconds: ``Acquire::http(s)::Timeout``.
        acquire_retries: ``Acquire::Retries``.
        mirror_acquire_retries: ``Acquire::Retries`` with mirror lists.
        call_timeout_seconds: Wall-clock deadline of each apt call attempt.
        total_timeout_seconds: Wall-clock budget of one helper run.
        keep_third_party: Keep every ``sources.list.d`` file.
        keep_mirrors: Leave Ubuntu archive URIs as they are (#1661).
        egress_config: harden-runner agent configuration to read the
            allowed endpoints from (overridden by tests only).
        machine: Machine name for ``apt_mirrors.load_policy`` (overridden
            by tests only).
        etc_dir: apt configuration root.
        tmp_dir: Directory for the filtered sources.
        sudo: Prefix for apt commands.
    """

    attempts: int = 3
    backoff_seconds: float = 5.0
    timeout_seconds: int = 15
    acquire_retries: int = 3
    mirror_acquire_retries: int = 1
    call_timeout_seconds: int = DEFAULT_CALL_TIMEOUT_SECONDS
    total_timeout_seconds: int = DEFAULT_TOTAL_TIMEOUT_SECONDS
    keep_third_party: bool = False
    keep_mirrors: bool = False
    egress_config: Path = apt_mirrors.AGENT_CONFIG
    machine: str = ""
    etc_dir: Path = Path("/etc/apt")
    tmp_dir: Path = Path("/tmp")
    sudo: tuple[str, ...] = ()


@dataclass
class Outcome:
    """Result of one apt call after its retries.

    Attributes:
        returncode: Exit code of the terminal attempt.
        network: Whether the terminal attempt's output had a network signature.
        timed_out: Whether the terminal attempt was stopped at its deadline.
        started: False when the budget left no room for a first attempt.
    """

    returncode: int
    network: bool
    timed_out: bool = False
    started: bool = True


# Runs a command with a deadline in seconds (None: none) and returns its
# exit code (``EXIT_TIMED_OUT`` past the deadline) and output lines.
Runner = Callable[[Sequence[str], float | None], tuple[int, list[str]]]
Sleeper = Callable[[float], None]
Clock = Callable[[], float]


@dataclass
class Session:
    """Process hooks and the time budget of one helper invocation.

    Attributes:
        runner: Executes a command with a deadline (see ``Runner``).
        sleeper: Sleeps between attempts.
        clock: Monotonic clock in seconds.
        deadline: ``clock()`` value the whole run must end by, including the
            stop of a call that hits its deadline; None for no budget.
    """

    runner: Runner
    sleeper: Sleeper
    clock: Clock = time.monotonic
    deadline: float | None = None


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
    mirrors = env.get("LGTM_CI_APT_KEEP_MIRRORS", "").strip().lower()
    tmp_dir = require_safe(tempfile.gettempdir(), "temporary directory")
    return Settings(
        attempts=_env_int(env, "LGTM_CI_APT_ATTEMPTS", 3, 1, MAX_ATTEMPTS),
        backoff_seconds=float(_env_int(env, "LGTM_CI_APT_BACKOFF_SECONDS", 5, 0, 30)),
        timeout_seconds=_env_int(env, "LGTM_CI_APT_TIMEOUT_SECONDS", 15, 1, 120),
        acquire_retries=_env_int(env, "LGTM_CI_APT_ACQUIRE_RETRIES", 3, 0, 5),
        mirror_acquire_retries=_env_int(
            env,
            "LGTM_CI_APT_MIRROR_ACQUIRE_RETRIES",
            1,
            0,
            5,
        ),
        call_timeout_seconds=_env_int(
            env,
            "LGTM_CI_APT_CALL_TIMEOUT_SECONDS",
            DEFAULT_CALL_TIMEOUT_SECONDS,
            1,
            MAX_CALL_TIMEOUT_SECONDS,
        ),
        total_timeout_seconds=_env_int(
            env,
            "LGTM_CI_APT_TOTAL_TIMEOUT_SECONDS",
            DEFAULT_TOTAL_TIMEOUT_SECONDS,
            MIN_TOTAL_TIMEOUT_SECONDS,
            MAX_TOTAL_TIMEOUT_SECONDS,
        ),
        keep_third_party=keep in TRUE_VALUES,
        keep_mirrors=mirrors in TRUE_VALUES,
        egress_config=Path(
            env.get("LGTM_CI_APT_EGRESS_CONFIG") or str(apt_mirrors.AGENT_CONFIG),
        ),
        # LGTM_CI_APT_EGRESS_CONFIG and LGTM_CI_APT_MACHINE are test hooks only.
        machine=env.get("LGTM_CI_APT_MACHINE") or platform.machine(),
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
    emit(f"[apt] {message}", err=True)


def stream(argv: Sequence[str], timeout: float | None = None) -> tuple[int, list[str]]:
    """Run an apt call (a ``Runner``), matching network signatures as it prints."""
    code, lines = apt_stream.stream(argv, timeout, signatures=NETWORK_SIGNATURES)
    return int(code), list(lines)


def has_network_signature(lines: Sequence[str]) -> bool:
    """Return whether any line carries a DNS or network failure signature.

    Args:
        lines: apt output lines.

    Returns:
        True when one of ``NETWORK_SIGNATURES`` occurs.
    """
    return any(sig in line for line in lines for sig in NETWORK_SIGNATURES)


def option_args(settings: Settings, source_parts: Path) -> list[str]:
    """Return the ``-o`` options every apt call carries.

    Args:
        settings: Helper settings.
        source_parts: Filtered ``Dir::Etc::SourceParts`` directory.

    Returns:
        ``-o key=value`` arguments. When a source names a stable mirror
        list (#1664), ``Acquire::Retries`` is ``mirror_acquire_retries``
        (capped at ``acquire_retries``); a private copy of the main sources
        list becomes ``Dir::Etc::SourceList``.
    """
    timeout = str(settings.timeout_seconds)
    retries = settings.acquire_retries
    stable = apt_failover.lists_dir(settings.tmp_dir)
    if apt_failover.uses_lists(source_parts, stable):
        retries = min(retries, settings.mirror_acquire_retries)
    options = [
        ("Acquire::Retries", str(retries)),
        ("Acquire::http::Timeout", timeout),
        ("Acquire::https::Timeout", timeout),
        ("DPkg::Lock::Timeout", "60"),
        ("Dir::Etc::SourceParts", require_safe(str(source_parts), "sources path")),
    ]
    main_list = source_parts / apt_failover.MAIN_DIR / apt_failover.MAIN_LIST
    if main_list.is_file():
        safe = require_safe(str(main_list), "sources path")
        options.append(("Dir::Etc::SourceList", safe))
    args: list[str] = []
    for key, value in options:
        args.extend(["-o", f"{key}={value}"])
    return args


def attempt_timeout(
    settings: Settings,
    session: Session,
    delay: float = 0.0,
) -> float | None:
    """Return the deadline of an attempt starting after ``delay`` seconds.

    The run's budget must also cover ending a call that hits its deadline
    (``apt_stream.stop_reserve()``: stopping its group and draining its
    echo), so the helper's own failure annotation comes out within the
    budget.

    Args:
        settings: Helper settings.
        session: Process hooks and budget.
        delay: Backoff still to sleep before the attempt.

    Returns:
        The call deadline cut to the budget left, or None when fewer than
        ``MIN_ATTEMPT_SECONDS`` are left.
    """
    call = float(settings.call_timeout_seconds)
    if session.deadline is None:
        return call
    stop = float(apt_stream.stop_reserve())
    room = session.deadline - session.clock() - delay - stop
    if room < MIN_ATTEMPT_SECONDS:
        return None
    return min(call, room)


def classify(code: int, lines: Sequence[str]) -> Outcome:
    """Classify one attempt from its exit code and its own output.

    A signal death (128+N; apt itself never exits above 128) is never a
    network failure, whatever apt printed first: no retry, no annotation.
    Neither is a stopped stall, which has its own message.

    Args:
        code: The attempt's exit code.
        lines: The attempt's output lines.

    Returns:
        The attempt's outcome.
    """
    timed_out = code == EXIT_TIMED_OUT
    killed = code > SIGNAL_EXIT_BASE
    network = not killed and not timed_out and has_network_signature(lines)
    return Outcome(returncode=code, network=network, timed_out=timed_out)


def retryable(outcome: Outcome, *, warnings_fail: bool) -> bool:
    """Return whether a failed attempt is a network failure or a timeout.

    Args:
        outcome: The attempt's outcome.
        warnings_fail: A zero exit with a network signature is a failure.

    Returns:
        True when the attempt failed and another one may help.
    """
    succeeded = outcome.returncode == 0 and not (warnings_fail and outcome.network)
    return not succeeded and (outcome.network or outcome.timed_out)


def run_with_retries(
    label: str,
    argv: Sequence[str],
    settings: Settings,
    session: Session,
    *,
    warnings_fail: bool = False,
) -> Outcome:
    """Run one apt call, retrying only network failures and deadline expiries.

    Each attempt gets ``attempt_timeout``: the call deadline, cut to what is
    left of the run's budget. No attempt (first or retry) starts when the
    budget has no room for one; the call then ends as timed out.

    Args:
        label: Name for log lines, such as ``apt-get update``.
        argv: Command and arguments.
        settings: Helper settings.
        session: Process hooks and budget.
        warnings_fail: Treat a zero exit with a network signature as a failed
            attempt (``apt-get update`` exits 0 when indexes fail to fetch).

    Returns:
        The terminal attempt's outcome.
    """
    delays = backoff_delays(settings)
    timeout = attempt_timeout(settings, session)
    outcome = Outcome(EXIT_TIMED_OUT, False, timed_out=True, started=False)
    reason = "not started"
    for attempt in range(1, settings.attempts + 1):
        if timeout is None:
            _log(
                f"{label}: {reason}; no time left in the"
                f" {settings.total_timeout_seconds}s budget for attempt {attempt}",
            )
            return outcome
        outcome = classify(*session.runner(argv, timeout))
        if not retryable(outcome, warnings_fail=warnings_fail):
            return outcome
        reason = "DNS or network failure"
        if outcome.timed_out:
            reason = f"timed out after {timeout:g}s"
        if attempt == settings.attempts:
            break
        delay = delays[attempt - 1]
        timeout = attempt_timeout(settings, session, delay)
        if timeout is not None:
            _log(
                f"{label}: {reason}"
                f" (attempt {attempt}/{settings.attempts}); retrying in {delay:g}s",
            )
            session.sleeper(delay)
            timeout = attempt_timeout(settings, session)
    _log(f"{label}: {reason} on the last of {settings.attempts} attempts")
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
        emit(f"::error::{NETWORK_ERROR_MESSAGE}")
    else:
        emit(
            f"::error::{label} failed with exit code {code}"
            " (no DNS or network failure in its output)",
        )
    return code


def fail_outcome(label: str, outcome: Outcome, settings: Settings) -> int:
    """Print the annotation for a failed call's terminal attempt.

    A timed-out call gets ``TIMEOUT_ERROR_MESSAGE`` and exits
    ``EXIT_TIMED_OUT``; any other failure goes through ``fail``.

    Args:
        label: Name of the failed call.
        outcome: Its terminal attempt.
        settings: Helper settings, for the limits in the message.

    Returns:
        The exit code to leave with.
    """
    if outcome.timed_out:
        # No attempt ran: earlier calls of this run used up the budget.
        what = label if outcome.started else f"{label} did not start: the run"
        message = TIMEOUT_ERROR_MESSAGE.format(
            label=what,
            call=settings.call_timeout_seconds,
            total=settings.total_timeout_seconds,
        )
        emit(f"::error::{message}")
        return EXIT_TIMED_OUT
    return fail(label, outcome.returncode, outcome.network)


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


def load_mirror_policy(
    settings: Settings,
) -> tuple[apt_mirrors.MirrorPolicy | None, str]:
    """Load the archive rewrite policy; never raise.

    Args:
        settings: Helper settings.

    Returns:
        The policy (None: leave the sources as they are) and the reason when
        there is none ("" when ``keep_mirrors`` is set).
    """
    if settings.keep_mirrors:
        return None, ""
    try:
        policy, note = apt_mirrors.load_policy(
            settings.egress_config,
            machine=settings.machine or None,
        )
    except Interrupted:
        raise
    except Exception as error:  # pylint: disable=broad-exception-caught
        # Backstop: load_policy handles its own errors; nothing may fail apt.
        return None, f"egress config not usable ({type(error).__name__}: {error})"
    return policy, note


@contextmanager
def filtered_sources(settings: Settings) -> Iterator[Path]:
    """Yield a private ``Dir::Etc::SourceParts`` without third-party files.

    Ubuntu archive URIs egress may not allow are rewritten in the copies
    (``apt_mirrors``, #1661) unless ``keep_mirrors`` is set. Loading the
    policy or rewriting never fails the run: any error leaves the sources
    as they are, with one log line.

    Args:
        settings: Helper settings.

    Yields:
        The filtered directory; removed on exit, signals included.
    """
    tmp_root = settings.tmp_dir
    policy, note = load_mirror_policy(settings)
    with tempfile.TemporaryDirectory(prefix=SOURCES_PREFIX, dir=tmp_root) as tmp:
        dest = Path(tmp)
        real = settings.etc_dir / "sources.list.d"
        try:
            # The lists sit outside dest, so this call's cleanup keeps them.
            policy = policy.with_lists(tmp_root) if policy else None
            rewrite_for = policy.rewrite_for if policy else None
            skipped = filter_sources(real, dest, settings.keep_third_party, rewrite_for)
            if policy:
                main_list = settings.etc_dir / apt_failover.MAIN_LIST
                rewrite = policy.rewrite_for(main_list.name)
                apt_failover.copy_main_list(main_list, dest, rewrite)
        except Interrupted:
            raise
        except Exception as error:  # pylint: disable=broad-exception-caught
            if policy is None:
                raise
            # A rewrite bug must not cost the job its apt call: copy as is.
            for partial in dest.iterdir():
                if partial.is_dir() and not partial.is_symlink():
                    shutil.rmtree(partial)
                else:
                    partial.unlink()
            policy, note = None, f"rewrite failed ({type(error).__name__}: {error})"
            skipped = filter_sources(real, dest, settings.keep_third_party)
        if policy and policy.changes:
            _log(policy.summary())
        elif policy and policy.direct_reason:
            # Sources already on allowed hosts stay; say why they get no list.
            _log(f"one host per suite: {policy.direct_reason}")
        if note:
            _log(f"archive sources unchanged: {note}")
        if skipped:
            _log(
                "left out third-party sources: "
                + ", ".join(skipped)
                + " (set LGTM_CI_APT_KEEP_THIRD_PARTY_SOURCES=true to keep them)",
            )
        yield dest


def _note(why: str, what: str) -> None:
    """Log ``what`` with its reason when ``why`` is not empty."""
    if why:
        _log(f"{what} ({why})")


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
    stable = apt_failover.lists_dir(settings.tmp_dir)
    with filtered_sources(settings) as parts:
        identity = apt_failover.source_identity(parts, settings.etc_dir)
        _note(apt_failover.forget_update(stable), "update record not cleared")
        outcome = run_with_retries(
            "apt-get update",
            apt_get(settings, parts, *update_args()),
            settings,
            session,
            warnings_fail=True,
        )
    if outcome.returncode != 0 or outcome.network:
        return fail_outcome("apt-get update", outcome, settings)
    _note(apt_failover.record_update(stable, identity), "update not recorded")
    return 0


def cmd_install(
    settings: Settings,
    packages: Sequence[str],
    session: Session,
    *,
    no_install_recommends: bool = False,
    no_update: bool = False,
) -> int:
    """Run ``apt-get update`` (unless ``no_update``), then ``apt-get install -y``.

    An ``install`` failure is a network failure only when its own terminal
    attempt shows one. Stale lists from an ``update`` that never recovered
    are logged but do not count: an explicit install error (a package that
    fails to configure, a bad name) must never be reported as a network
    failure, because the canary retries that annotation (#1432 follow-up).
    """
    stable = apt_failover.lists_dir(settings.tmp_dir)
    with filtered_sources(settings) as parts:
        identity = apt_failover.source_identity(parts, settings.etc_dir)
        # --no-update (the Playwright path): skip the update only when the
        # record of the last one shows these sources; in doubt, update (#1664).
        why = apt_failover.refresh_reason(stable, identity) if no_update else ""
        if why:
            _log(f"install --no-update: updating first, because {why}")
            no_update = False
        if not no_update:
            _note(apt_failover.forget_update(stable), "update record not cleared")
        update = (
            Outcome(returncode=0, network=False)
            if no_update
            else run_with_retries(
                "apt-get update",
                apt_get(settings, parts, *update_args()),
                settings,
                session,
                warnings_fail=True,
            )
        )
        if update.returncode != 0:
            return fail_outcome("apt-get update", update, settings)
        if update.network:
            _log("apt-get update left some indexes stale; installing anyway")
        elif not no_update:
            _note(apt_failover.record_update(stable, identity), "update not recorded")
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
        terminal = replace(install, network=not killed and install.network)
        return fail_outcome("apt-get install", terminal, settings)
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
    install.add_argument(
        "--no-update",
        action="store_true",
        help="skip apt-get update: the helper's update ran just before",
    )
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
    deadline = time.monotonic() + settings.total_timeout_seconds
    session = Session(runner=runner, sleeper=sleeper, deadline=deadline)
    previous = {sig: signal.signal(sig, on_signal) for sig in HANDLED_SIGNALS}
    try:
        if args.command == "update":
            return cmd_update(settings, session)
        return cmd_install(
            settings,
            args.packages,
            session,
            no_install_recommends=args.no_install_recommends,
            no_update=args.no_update,
        )
    except UsageError as error:
        _log(f"usage error: {error}")
        return EXIT_USAGE
    except Interrupted as interrupted:
        signum = int(interrupted.signum)
        _log(f"interrupted by signal {signum}; cleaned up")
        return SIGNAL_EXIT_BASE + signum
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


if __name__ == "__main__":
    sys.exit(main())
