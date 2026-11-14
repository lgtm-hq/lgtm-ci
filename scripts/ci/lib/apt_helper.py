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
    LGTM_CI_APT_CALL_TIMEOUT_SECONDS: Wall-clock deadline of each apt call
        attempt (default 100, 1 to 3600), cut to the budget left.
    LGTM_CI_APT_TOTAL_TIMEOUT_SECONDS: Wall-clock budget of one helper run,
        stopping included (default 300, 30 to 3600). ``install`` without
        ``--no-update`` spends one budget on both calls.
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
    124 - an apt call's last attempt hit its deadline, or the budget left
        no room for an attempt
    128 + N - interrupted by signal N
    otherwise - the exit code of the failed apt call (never 0)
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import shutil
import signal
import sys
import tempfile
import time
from collections.abc import Callable, Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

try:
    import apt_stream
except ImportError:  # python3 -I leaves this lib/ directory off sys.path
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import apt_stream

# Re-bound with their types: mypy does not follow the bootstrapped import.
EXIT_TIMED_OUT: int = apt_stream.EXIT_TIMED_OUT
SIGNAL_EXIT_BASE: int = apt_stream.SIGNAL_EXIT_BASE
HANDLED_SIGNALS: tuple[signal.Signals, ...] = apt_stream.HANDLED_SIGNALS
Interrupted = apt_stream.Interrupted
on_signal = apt_stream.on_signal
emit = apt_stream.emit

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
        call_timeout_seconds: Wall-clock deadline of each apt call attempt.
        total_timeout_seconds: Wall-clock budget of one helper run.
        keep_third_party: Keep every ``sources.list.d`` file.
        etc_dir: apt configuration root.
        tmp_dir: Directory for the filtered sources.
        sudo: Prefix for apt commands.
    """

    attempts: int = 3
    backoff_seconds: float = 5.0
    timeout_seconds: int = 15
    acquire_retries: int = 3
    call_timeout_seconds: int = DEFAULT_CALL_TIMEOUT_SECONDS
    total_timeout_seconds: int = DEFAULT_TOTAL_TIMEOUT_SECONDS
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
        timed_out: Whether the terminal attempt was stopped at its deadline.
    """

    returncode: int
    network: bool
    timed_out: bool = False


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
    tmp_dir = require_safe(tempfile.gettempdir(), "temporary directory")
    return Settings(
        attempts=_env_int(env, "LGTM_CI_APT_ATTEMPTS", 3, 1, MAX_ATTEMPTS),
        backoff_seconds=float(_env_int(env, "LGTM_CI_APT_BACKOFF_SECONDS", 5, 0, 30)),
        timeout_seconds=_env_int(env, "LGTM_CI_APT_TIMEOUT_SECONDS", 15, 1, 120),
        acquire_retries=_env_int(env, "LGTM_CI_APT_ACQUIRE_RETRIES", 3, 0, 5),
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
    outcome = Outcome(returncode=EXIT_TIMED_OUT, network=False, timed_out=True)
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
        message = TIMEOUT_ERROR_MESSAGE.format(
            label=label,
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
        return fail_outcome("apt-get update", outcome, settings)
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
    with filtered_sources(settings) as parts:
        # --no-update: the caller ran the helper's own ``update`` just before
        # (the Playwright path), so the lists are fresh; do not refresh twice.
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
        network = not killed and install.network
        terminal = Outcome(install.returncode, network, install.timed_out)
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
