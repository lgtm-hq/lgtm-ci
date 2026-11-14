#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Run one apt call with a wall-clock deadline, echoing and capturing output.

Used by ``apt_helper.py`` (#1432, #1571); not a command of its own.

Every call runs in its own session (process group) with stdout and stderr
on one pipe. The main thread reads that pipe itself: non-blocking reads
through a selector, bounded by the call's deadline. There is no reader
thread, so nothing can still be writing to stdout when the helper exits or
unwinds from a signal, and a child that prints nothing still meets its
deadline. Two earlier failure modes are ruled out this way (#1571 review):

- A daemon reader blocked on a slow stdout while a detached child kept the
  pipe open made CPython abort at exit (``_enter_buffered_busy``, SIGABRT)
  instead of exiting 124.
- An echo error in the reader (``UnicodeEncodeError`` under an ASCII stdout)
  killed only the reader, so a failed ``update`` returned no lines and was
  classified as success.

Nothing the helper writes can block past a deadline either (#1571 review: a
stdout nobody read kept a 1s call running for over 30s, and SIGTERM waited
for it). Each stream gets a write that cannot block for its kind of
descriptor (``_Out``), and the caller's descriptor is never switched to
non-blocking, since other processes share its flags: a pipe is written only
when ``select`` reports it writable, at most ``select.PIPE_BUF`` bytes at a
time; a regular file or the null device directly; a TTY (where a writable
terminal can still block a ``PIPE_BUF`` write) or another device through a
private non-blocking descriptor opened on it. A stream that offers none of
these (a socket on macOS), is closed, or is the call's own pipe (fd 1 was
closed and reused) is not written at all; for stdout that is said once on
stderr, and output is still captured and classified.

Echoed output waits in a buffer of ``ECHO_BUFFER_BYTES``. While more than
``ECHO_HIGH_BYTES`` wait for a stdout that is taking writes, apt's output is
not read until less than ``ECHO_LOW_BYTES`` wait, so a slow log consumer
slows apt down instead of losing output. A stdout that took nothing for
``ECHO_STALL_SECONDS`` stalls: reading resumes, and what does not fit in
the buffer is not echoed (still captured and classified). At the end of the
call the buffer gets ``ECHO_FLUSH_SECONDS`` to drain, the rest is dropped,
and one ``[apt] N bytes of apt output not echoed (stdout not draining)``
note goes to stderr. The helper's own lines (``emit``) wait at most
``EMIT_SECONDS`` for their stream; a stream that did not take a whole line
in time is then written to only when it is writable at once.

Classification never depends on how much output is kept: the network
signatures are matched on the bytes as they arrive, a line at a time with
the partial last line carried over, so a signature split across reads is
still found. The captured output is capped at ``MAX_CAPTURE_BYTES`` (the
newest bytes, where apt's errors are); lines with a signature that the cap
evicted are returned first. Output is echoed as raw bytes, so no encoding
error is possible; an echo that fails anyway stops echoing but never stops
capturing. Only lone ``\\r`` and ``\\r\\n`` are rewritten as ``\\n`` in the
echo, as a text-mode stdout did, so dpkg's progress lines read as lines.
The captured bytes are decoded once at the end, as UTF-8 with replacement
and universal newlines, so apt's ``\\r`` progress output still splits into
lines.

Cancellation: the handled signals are blocked while the call is started and
registered, so a signal never finds an unregistered child. ``on_signal``
ignores further signals, forwards the signal to the call's process group,
waits up to ``CHILD_GRACE_SECONDS`` for the whole group to exit and sends
SIGKILL to whatever is left, then raises ``Interrupted``; the echo buffer is
then dropped, not drained, and replaced rather than resized (a view of it
held by the traceback would turn the cleanup into a ``BufferError``). When
the deadline passes, the group is stopped the same way with SIGTERM. On any
other exception the group is stopped too.

When the group leader (apt) exits while another process still holds the
pipe (a daemon a maintainer script started without its own session), the
call is over: the pipe gets ``LEADER_DRAIN_SECONDS`` to deliver the rest of
apt's output, is then closed, and the call returns apt's own exit code. The
leftover process is left running, as it would be without the helper; only a
leader that itself outlives its deadline gets its group stopped.
"""

from __future__ import annotations

import atexit
import fcntl
import os
import re
import select
import selectors
import signal
import stat
import subprocess
import sys
import time
from collections import deque
from collections.abc import Callable, Sequence
from contextlib import suppress
from enum import Enum, auto
from functools import partial
from types import FrameType
from typing import Any

CHILD_GRACE_SECONDS = 10.0
# Seconds the echo buffer gets to drain at the end of a call.
ECHO_FLUSH_SECONDS = 1.0
# Seconds one helper line (log, warning, annotation) may wait for its stream.
EMIT_SECONDS = 2.0
# Seconds the pipe is still read after the leader exited.
LEADER_DRAIN_SECONDS = 3.0
# How often the read loop checks whether the leader exited.
LEADER_POLL_SECONDS = 0.05
# Exit code of an attempt stopped at its deadline (coreutils timeout's code;
# apt-get itself exits 0, 1 or 100).
EXIT_TIMED_OUT = 124
EXIT_NOT_FOUND = 127
HANDLED_SIGNALS = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)
# Exit codes above this mean the child died by signal N (128+N).
SIGNAL_EXIT_BASE = 128
READ_CHUNK_BYTES = 65536
# Captured output kept for messages. apt prints far less; a child that
# floods the pipe keeps only its latest output, where apt's errors are.
MAX_CAPTURE_BYTES = 8 * 1024 * 1024
# Output waiting to be echoed; past this it is dropped, not waited for.
ECHO_BUFFER_BYTES = 1024 * 1024
# Reading apt's output pauses while this much waits for a stdout that is
# draining, and resumes below ECHO_LOW_BYTES.
ECHO_HIGH_BYTES = ECHO_BUFFER_BYTES // 4
ECHO_LOW_BYTES = ECHO_BUFFER_BYTES // 16
# Seconds without a write accepted after which stdout counts as stalled:
# reading resumes and what does not fit in the buffer is dropped.
ECHO_STALL_SECONDS = 2.0
# Bytes copied out of the echo buffer per write to a non-pipe stream.
WRITE_CHUNK_BYTES = 65536
# A partial line longer than this is matched and cut to a short tail.
MAX_LINE_BYTES = 64 * 1024
# Bytes kept around each signature match, and matches kept per call.
KEPT_MATCH_BYTES = 4096
MAX_KEPT_MATCHES = 16
_NEWLINES = re.compile(r"\r\n|\r|\n")
_BYTE_NEWLINES = re.compile(rb"\r\n|\r|\n")
_LINE_ENDS = (b"\n", b"\r")

# The apt call currently running, for the signal handler to signal.
_CHILDREN: list[subprocess.Popen[bytes]] = []


class Interrupted(Exception):
    """Raised by the signal handler once the apt call has exited.

    Attributes:
        signum: The signal received.
    """

    def __init__(self, signum: int) -> None:
        super().__init__(f"signal {signum}")
        self.signum = signum


def stop_reserve() -> float:
    """Return the seconds a call may take past its deadline.

    Stopping the group (``stop_group``: up to ``2 * CHILD_GRACE_SECONDS``)
    plus draining the echo buffer (``ECHO_FLUSH_SECONDS``).
    """
    return 2 * CHILD_GRACE_SECONDS + ECHO_FLUSH_SECONDS


class _Mode(Enum):
    """How an output stream is written without waiting on it."""

    STREAM = auto()  # No descriptor (tests): written through the stream.
    FILE = auto()  # A regular file or the null device: a write never waits.
    PIPE = auto()  # A FIFO: once writable, at most PIPE_BUF bytes per write.
    NONBLOCK = auto()  # A non-blocking descriptor: EAGAIN means "not now".
    OFF = auto()  # Not written to at all.


def _identity(info: os.stat_result) -> tuple[int, int, int]:
    """Return what identifies the file a descriptor is open on."""
    return info.st_dev, info.st_ino, info.st_rdev


def _is_null(info: os.stat_result) -> bool:
    """Return whether ``info`` is the null device."""
    if not stat.S_ISCHR(info.st_mode):
        return False
    try:
        return os.stat(os.devnull).st_rdev == info.st_rdev
    except OSError:
        return False


def _reopen(fd: int, info: os.stat_result) -> int | None:
    """Open a private non-blocking descriptor on the file ``fd`` is open on.

    The caller's descriptor shares its open file description (and so its
    flags) with other processes, so it is never switched to non-blocking.
    A TTY is reopened by its name; anything else through ``/proc/self/fd``
    or ``/dev/fd`` where that opens the file again (Linux). Where it only
    duplicates the descriptor (macOS) or fails (a socket), None.
    """
    paths = [f"/proc/self/fd/{fd}", f"/dev/fd/{fd}"]
    with suppress(OSError):
        if os.isatty(fd):
            paths.insert(0, os.ttyname(fd))
    flags = os.O_WRONLY | os.O_NONBLOCK | getattr(os, "O_NOCTTY", 0)
    for path in paths:
        try:
            new = os.open(path, flags)
        except OSError:
            continue
        try:
            same = _identity(os.fstat(new)) == _identity(info)
            private = not os.get_blocking(new) and os.get_blocking(fd)
            if not private and not os.get_blocking(fd):
                os.set_blocking(fd, True)  # A duplicate took our flag; undo.
        except OSError:
            same = private = False
        if same and private:
            return new
        os.close(new)
    return None


class _Out:  # pylint: disable=too-many-instance-attributes
    """An output stream that is never waited on past a deadline.

    Each kind of descriptor gets a write that cannot block (``_Mode``),
    without changing the flags of the caller's descriptor: a pipe is written
    once ``select`` reports it writable, ``select.PIPE_BUF`` bytes at a time
    (the only size POSIX guarantees fits then); a regular file or the null
    device is written directly; a TTY or other device gets a private
    non-blocking descriptor (``_reopen``). A stream that is closed, not open
    for writing, or offers none of these (a socket on macOS) is not written
    at all (``OFF``, with ``reason``). A stream without a descriptor (tests)
    is written through its ``buffer`` at once.

    Attributes:
        stream: The text stream (``sys.stdout`` or ``sys.stderr``).
        mode: How it is written.
        fd: The descriptor written to, or None.
        reason: Why the mode is ``OFF``.
        at_line_start: Whether the last byte written ended a line.
        stuck: Whether a helper line once did not fit within its wait.
        noted: Whether the ``OFF`` note was printed.
    """

    def __init__(self, target: Any) -> None:
        self.stream = target
        self.mode = _Mode.STREAM
        self.fd: int | None = None
        self.reason = ""
        self.at_line_start = True
        self.stuck = False
        self.noted = False
        self._source: int | None = None
        self._identity: tuple[int, int, int] | None = None
        self._own = False
        try:
            fd = target.fileno()
        except (AttributeError, OSError, ValueError):
            return
        self._source = fd
        try:
            info = os.fstat(fd)
            access = fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE
        except OSError as error:
            self._off(f"is unavailable ({error.strerror})")
            return
        self._identity = _identity(info)
        if access == os.O_RDONLY:
            self._off("is not open for writing")
        elif stat.S_ISREG(info.st_mode) or _is_null(info):
            self._use(fd, _Mode.FILE)
        elif not os.get_blocking(fd):
            self._use(fd, _Mode.NONBLOCK)
        elif stat.S_ISFIFO(info.st_mode):
            self._use(fd, _Mode.PIPE)
        else:
            private = _reopen(fd, info)
            if private is None:
                self._off("cannot be written without blocking")
            else:
                self._use(private, _Mode.NONBLOCK)
                self._own = True

    def _use(self, fd: int, mode: _Mode) -> None:
        """Write to ``fd`` in ``mode``."""
        self.fd, self.mode = fd, mode

    def _off(self, reason: str) -> None:
        """Never write; say why."""
        self.fd, self.mode, self.reason = None, _Mode.OFF, reason

    def current(self) -> bool:
        """Return whether the stream is still on the file it was set up for."""
        try:
            fd = self.stream.fileno()
        except (AttributeError, OSError, ValueError):
            return self._source is None
        try:
            identity: tuple[int, int, int] | None = _identity(os.fstat(fd))
        except OSError:
            identity = None
        return fd == self._source and identity == self._identity

    def close(self) -> None:
        """Close the private descriptor, if there is one."""
        if self._own and self.fd is not None:
            with suppress(OSError):
                os.close(self.fd)
        self._own = False
        self._off("is closed")

    def writable(self, timeout: float) -> bool:
        """Return whether the stream takes a write within ``timeout``."""
        if self.mode is _Mode.OFF:
            return False
        if self.fd is None or self.mode is _Mode.FILE:
            return True
        _, ready, _ = select.select([], [self.fd], [], timeout)
        return bool(ready)

    def write_ready(self, data: bytes) -> int:
        """Write what the stream takes now; it must be writable.

        Raises:
            OSError: The write failed.
            ValueError: The stream is closed.

        Returns:
            The number of bytes written (0: not writable after all).
        """
        if not data or self.mode is _Mode.OFF:
            return 0
        if self.fd is None:
            self.stream.flush()
            buffer = getattr(self.stream, "buffer", None)
            if buffer is None:
                self.stream.write(data.decode("utf-8", "replace"))
                self.stream.flush()
            else:
                buffer.write(data)
                buffer.flush()
            written = len(data)
        else:
            if self.mode is _Mode.PIPE:
                data = data[: select.PIPE_BUF]
            try:
                written = os.write(self.fd, data)
            except BlockingIOError:
                return 0
        if written:
            self.at_line_start = data[written - 1 : written] in _LINE_ENDS
        return written

    def write_until(self, data: bytes | bytearray, seconds: float) -> int:
        """Write ``data``, waiting at most ``seconds`` for the stream.

        Each write gets a copy of its slice, never a view: a view that an
        exception's traceback still held would keep a ``bytearray`` from
        being resized (``BufferError``) while the exception unwinds.

        Raises:
            OSError: A write failed.
            ValueError: The stream is closed.

        Returns:
            The number of bytes written.
        """
        end = time.monotonic() + seconds
        step = select.PIPE_BUF if self.mode is _Mode.PIPE else WRITE_CHUNK_BYTES
        done = 0
        while done < len(data):
            if not self.writable(max(0.0, end - time.monotonic())):
                break
            written = self.write_ready(bytes(data[done : done + step]))
            if not written:
                break
            done += written
        return done


_OUTS: list[_Out] = []


def _out_for(target: Any) -> _Out:
    """Return the ``_Out`` of a stream, keeping its line and stuck state.

    A stream whose descriptor now refers to another file (closed and
    reused) is set up again.
    """
    found = next((out for out in _OUTS if out.stream is target), None)
    if found is not None:
        if found.current():
            return found
        _OUTS.remove(found)
        found.close()
    out = _Out(target)
    for old in _OUTS[:-7]:
        old.close()
    _OUTS[:] = [*_OUTS[-7:], out]
    return out


def _close_outs() -> None:
    """Close every private descriptor still cached (helper teardown)."""
    while _OUTS:
        _OUTS.pop().close()


atexit.register(_close_outs)


def emit(text: str, *, err: bool = False) -> None:
    """Print one helper line to stdout (or stderr) without blocking for long.

    Waits at most ``EMIT_SECONDS`` for the stream, or not at all once a line
    did not fit in time; a line that does not fit is cut or dropped. A line
    after a cut-off echo starts on a line of its own. A stream that cannot
    be written without blocking (``_Out``) gets nothing.

    Args:
        text: The line, without its newline.
        err: Write to stderr instead of stdout.
    """
    target = sys.stderr if err else sys.stdout
    if target is None:
        return
    out = _out_for(target)
    if out.mode is _Mode.OFF:
        return
    data = text.encode("utf-8", "replace") + b"\n"
    if not out.at_line_start:
        data = b"\n" + data
    try:
        with suppress(OSError, ValueError):
            target.flush()
        written = out.write_until(data, 0.0 if out.stuck else EMIT_SECONDS)
    except (OSError, ValueError):
        return
    if written < len(data):
        out.stuck = True


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

    Takes at most ``2 * CHILD_GRACE_SECONDS``.

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


def _warn_killed(cause: str) -> None:
    """Print the warning for a group that needed SIGKILL."""
    emit(
        f"::warning::apt did not stop within {CHILD_GRACE_SECONDS:g}s of {cause}"
        " and was killed; under sudo apt may still be running and holding the"
        " dpkg lock",
    )


def on_signal(signum: int, _frame: FrameType | None) -> None:
    """Stop the running apt call's process group, then unwind.

    Raises:
        Interrupted: Always, so the caller's cleanup runs.
    """
    for handled in HANDLED_SIGNALS:
        signal.signal(handled, signal.SIG_IGN)
    for child in list(_CHILDREN):
        if stop_group(child, signum):
            _warn_killed(f"signal {signum}")
    raise Interrupted(signum)


class _Capture:
    """The newest ``MAX_CAPTURE_BYTES`` of one call's output.

    Attributes:
        evicted: Whether older output was dropped.
    """

    def __init__(self) -> None:
        self._chunks: deque[bytes] = deque()
        self._size = 0
        self.evicted = False

    def add(self, chunk: bytes) -> None:
        """Append a chunk, dropping the oldest output past the cap."""
        self._chunks.append(chunk)
        self._size += len(chunk)
        excess = self._size - MAX_CAPTURE_BYTES
        while excess > 0:
            self.evicted = True
            first = self._chunks[0]
            if len(first) <= excess:
                self._chunks.popleft()
                cut = len(first)
            else:
                self._chunks[0] = first[excess:]
                cut = excess
            self._size -= cut
            excess -= cut

    def lines(self) -> list[str]:
        """Return the output as lines, decoded with universal newlines."""
        return _decode(b"".join(self._chunks))


def _decode(data: bytes) -> list[str]:
    """Decode output as UTF-8 lines with universal newlines."""
    lines = _NEWLINES.split(data.decode("utf-8", errors="replace"))
    if lines[-1] == "":
        lines.pop()
    return lines


class _Matcher:
    """Finds signatures in output as it arrives, across reads and lines.

    Attributes:
        found: Up to ``MAX_KEPT_MATCHES`` excerpts of lines with a match.
    """

    def __init__(self, signatures: Sequence[str]) -> None:
        self._signatures = tuple(s.encode("utf-8") for s in signatures if s)
        self._tail = max((len(s) for s in self._signatures), default=1) - 1
        self._carry = b""
        self.found: list[bytes] = []

    def feed(self, chunk: bytes) -> None:
        """Match every line the chunk completes; carry the partial last one."""
        if not self._signatures or len(self.found) >= MAX_KEPT_MATCHES:
            return
        *complete, rest = _BYTE_NEWLINES.split(self._carry + chunk)
        for line in complete:
            self._check(line)
        if len(rest) > MAX_LINE_BYTES:
            self._check(rest)
            # The tail is too short to hold a whole signature again.
            rest = rest[len(rest) - self._tail :] if self._tail else b""
        self._carry = rest

    def finish(self) -> None:
        """Match the last line, if the output did not end with a newline."""
        if self._carry:
            self._check(self._carry)
            self._carry = b""

    def _check(self, line: bytes) -> None:
        """Keep an excerpt of the line around its first signature."""
        if len(self.found) >= MAX_KEPT_MATCHES:
            return
        for signature in self._signatures:
            at = line.find(signature)
            if at >= 0:
                half = KEPT_MATCH_BYTES // 2
                start = max(0, at - half)
                self.found.append(line[start : at + len(signature) + half])
                return


class _Echo:
    """Copies a call's output to stdout without ever waiting on stdout.

    Lone ``\\r`` (dpkg's progress lines) and ``\\r\\n`` are echoed as ``\\n``,
    as a text-mode stdout with universal newlines did; the captured output
    is not changed.
    """

    def __init__(self) -> None:
        out = _out_for(sys.stdout) if sys.stdout else None
        self._out: _Out | None = out
        self._buffer = bytearray()
        self._ends_line = True
        self._after_cr = False
        self._paused = False
        self._progress = time.monotonic()
        self.dropped = 0
        if out is not None and out.mode is _Mode.OFF:
            self._out = None
            if not out.noted:
                out.noted = True
                emit(f"[apt] not echoing apt output: stdout {out.reason}", err=True)

    @property
    def wants_fd(self) -> int | None:
        """Return stdout's descriptor while output waits for it."""
        if self._out is None or not self._buffer:
            return None
        return self._out.fd

    @property
    def paused(self) -> bool:
        """Return whether reading should wait for stdout to take the buffer.

        True from ``ECHO_HIGH_BYTES`` down to ``ECHO_LOW_BYTES``, unless
        stdout took nothing for ``ECHO_STALL_SECONDS``.
        """
        if self._out is None or self._out.fd is None:
            return False
        size = len(self._buffer)
        if size >= ECHO_HIGH_BYTES:
            self._paused = True
        elif size < ECHO_LOW_BYTES:
            self._paused = False
        stalled = time.monotonic() - self._progress > ECHO_STALL_SECONDS
        return self._paused and not stalled

    def disable(self, reason: str) -> None:
        """Stop echoing (capture goes on) and say why on stderr."""
        self._out = None
        self.dropped = 0
        self._buffer = bytearray()
        emit(f"[apt] not echoing apt output: stdout {reason}", err=True)

    def add(self, chunk: bytes) -> None:
        """Queue a chunk; past ``ECHO_BUFFER_BYTES`` drop it, counted."""
        if self._out is None:
            return
        if self._after_cr and chunk.startswith(b"\n"):
            chunk = chunk[1:]  # The \r before it was already echoed as \n.
            self._after_cr = False  # Only this one \n belongs to that \r.
        if not chunk:
            return
        self._after_cr = chunk.endswith(b"\r")
        chunk = chunk.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
        if not self._buffer:
            self._progress = time.monotonic()
        kept = chunk[: max(0, ECHO_BUFFER_BYTES - len(self._buffer))]
        self.dropped += len(chunk) - len(kept)
        if kept:
            self._buffer += kept
            self._ends_line = kept.endswith(b"\n")
        if self._out.fd is None:
            self.drain()

    def drain(self) -> None:
        """Write what stdout takes without waiting."""
        self._write(0.0)

    def finish(self, seconds: float) -> None:
        """Give the rest ``seconds`` to drain, then drop it with a note."""
        if self._out is not None and not self._ends_line:
            self._buffer = self._buffer + b"\n"
            self._ends_line = True
        pending = len(self._buffer)
        written = self._write(0.0 if self._out and self._out.stuck else seconds)
        if self._out is not None and pending and not written:
            self._out.stuck = True
        self._drop()

    def abort(self) -> None:
        """Drop what waits, without writing (an exception is unwinding).

        The buffer is replaced, never resized: a view of it may still be
        held by the traceback.
        """
        self._drop()

    def _drop(self) -> None:
        """Drop the buffer and report what was not echoed."""
        self.dropped += len(self._buffer)
        self._buffer = bytearray()
        if self.dropped:
            note = f"[apt] {self.dropped} bytes of apt output not echoed"
            self.dropped = 0
            emit(f"{note} (stdout not draining)", err=True)

    def _write(self, seconds: float) -> int:
        """Write from the buffer for up to ``seconds``; on an error stop."""
        if self._out is None or not self._buffer:
            return 0
        try:
            written = self._out.write_until(self._buffer, seconds)
        except (OSError, ValueError) as error:
            self._out = None
            self._buffer = bytearray()
            emit(f"[apt] stopped echoing apt output: {error}", err=True)
            return 0
        if written:
            self._buffer = self._buffer[written:]
            self._progress = time.monotonic()
        return written


class _End(Enum):
    """How reading a call's output ended."""

    EOF = auto()
    LEADER_EXITED = auto()
    DEADLINE = auto()


def _remaining(deadline: float | None) -> float | None:
    """Return the seconds left until ``deadline`` (None: no deadline)."""
    return None if deadline is None else max(0.0, deadline - time.monotonic())


def _sync_out(
    selector: selectors.BaseSelector,
    echo: _Echo,
    fd: int,
    out_fd: int | None,
) -> int | None:
    """Watch stdout for writability while output waits for it.

    A stdout that is the call's own pipe (fd 1 was closed and Popen reused
    it) cannot be watched; echoing is then turned off instead.

    Returns:
        The stdout descriptor now watched, or None.
    """
    wanted = echo.wants_fd
    if wanted == out_fd:
        return out_fd
    if out_fd is not None:
        selector.unregister(out_fd)
    if wanted is None:
        return None
    if wanted == fd:
        echo.disable("is the apt output pipe")
        return None
    try:
        selector.register(wanted, selectors.EVENT_WRITE)
    except (KeyError, OSError, ValueError) as error:
        echo.disable(f"cannot be watched ({error})")
        return None
    return wanted


def _read(
    proc: subprocess.Popen[bytes],
    fd: int,
    sink: Callable[[bytes], None],
    echo: _Echo,
    deadline: float | None,
) -> _End:
    """Read a non-blocking pipe until EOF, the deadline or the leader's exit.

    While ``echo`` is paused (stdout is draining, but slower than apt
    writes) the pipe is not read, so apt waits as it would on a blocking
    stdout; the deadline still counts. Once the leader exited, the pipe is
    read for ``LEADER_DRAIN_SECONDS`` more (whatever the deadline, and
    without pausing), then given up.
    """
    drain_until: float | None = None
    with selectors.SelectSelector() as selector:
        reading = False
        out_fd: int | None = None
        while True:
            if drain_until is None and proc.poll() is not None:
                drain_until = time.monotonic() + LEADER_DRAIN_SECONDS
            read = drain_until is not None or not echo.paused
            if read != reading:
                if read:
                    selector.register(fd, selectors.EVENT_READ)
                else:
                    selector.unregister(fd)
                reading = read
            out_fd = _sync_out(selector, echo, fd, out_fd)
            remaining = _remaining(deadline if drain_until is None else drain_until)
            if remaining == 0.0:
                return _End.DEADLINE if drain_until is None else _End.LEADER_EXITED
            wait = LEADER_POLL_SECONDS
            if remaining is not None:
                wait = remaining if drain_until is not None else min(wait, remaining)
            for key, _ in selector.select(wait):
                if key.fd != fd:
                    echo.drain()
                    continue
                try:
                    chunk = os.read(fd, READ_CHUNK_BYTES)
                except BlockingIOError:
                    continue
                if not chunk:
                    return _End.EOF
                sink(chunk)
                echo.add(chunk)


def _pump(
    proc: subprocess.Popen[bytes],
    sink: Callable[[bytes], None],
    deadline: float | None,
) -> bool:
    """Echo and capture the call's output until it ends and the leader exits.

    Args:
        proc: The call, with its output on ``proc.stdout``.
        sink: Receives every output byte.
        deadline: ``time.monotonic()`` value to give up at; None waits.

    Returns:
        True when the leader exited before the deadline (its output ended or
        stopped being read ``LEADER_DRAIN_SECONDS`` later).
    """
    if proc.stdout is not None:
        fd = proc.stdout.fileno()
        os.set_blocking(fd, False)
        echo = _Echo()
        try:
            end = _read(proc, fd, sink, echo, deadline)
        except BaseException:
            # Never mask the exception (Interrupted) with one from cleanup.
            with suppress(Exception):
                echo.abort()
            raise
        echo.finish(ECHO_FLUSH_SECONDS)
        if end is _End.DEADLINE:
            return False
        if end is _End.LEADER_EXITED:
            emit(
                "[apt] the call exited, but a process it started still holds"
                " its output; no longer reading it",
                err=True,
            )
            return True
    try:
        proc.wait(timeout=_remaining(deadline))
    except subprocess.TimeoutExpired:
        return False
    return True


def stream(
    argv: Sequence[str],
    timeout: float | None = None,
    signatures: Sequence[str] = (),
) -> tuple[int, list[str]]:
    """Run a command in its own session, echoing and capturing its output.

    When ``timeout`` passes before the leader exits, or before it closes its
    output, the process group is stopped with ``stop_group`` (SIGTERM, then
    SIGKILL after ``CHILD_GRACE_SECONDS``) and the pipe is closed, so a
    process outside the group that still holds it is left behind without
    blocking anything. On any exception the group is stopped too, unless
    the signal handler already did.

    Args:
        argv: Command and arguments.
        timeout: Wall-clock deadline in seconds; None waits forever.
        signatures: Strings matched on the output as it arrives; a line with
            one that the capture cap evicted is still returned, first.

    Returns:
        Exit code and output lines. ``EXIT_TIMED_OUT`` when the deadline
        passed.
    """
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
        emit(f"{argv[0]}: {error.strerror}")
        return EXIT_NOT_FOUND, [str(error)]
    except BaseException:
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        raise
    capture = _Capture()
    matcher = _Matcher(signatures)

    def sink(chunk: bytes) -> None:
        capture.add(chunk)
        matcher.feed(chunk)

    returncode = EXIT_TIMED_OUT
    try:
        # A signal that arrived while blocked is handled here.
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        deadline = None if timeout is None else time.monotonic() + timeout
        if _pump(proc, sink, deadline):
            returncode = proc.wait()
        elif stop_group(proc, signal.SIGTERM):
            _warn_killed(f"its {timeout:g}s deadline")
    except Interrupted:
        raise
    except BaseException:
        # Best effort, even when the leader is gone: no member may outlive us.
        stop_group(proc, signal.SIGTERM)
        raise
    finally:
        _CHILDREN.remove(proc)
        if proc.stdout is not None:
            with suppress(OSError):
                proc.stdout.close()
    matcher.finish()
    lines = capture.lines()
    if capture.evicted and matcher.found:
        lines = [_decode(found)[0] for found in matcher.found] + lines
    # Popen reports death by signal N as -N; use the shell's 128+N.
    if returncode < 0:
        returncode = SIGNAL_EXIT_BASE - returncode
    return returncode, lines
