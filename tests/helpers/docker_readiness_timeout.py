#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Supervise real readiness deadlines and clean only the fixture's own session."""

import os
import signal
import subprocess
import sys
from pathlib import Path


def owned_groups(session: int) -> dict[int, int]:
    """Find live group representatives in the isolated synthetic session."""
    groups = {}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdecimal():
            continue
        pid = int(entry.name)
        try:
            state = (entry / "stat").read_text().rsplit(")", 1)[1].split()[0]
            if state != "Z" and os.getsid(pid) == session:
                groups[os.getpgid(pid)] = pid
        except (FileNotFoundError, ProcessLookupError):
            continue
    return groups


def cleanup(session: int) -> None:
    """Recheck session/group ownership immediately before any cleanup signal."""
    for group, pid in owned_groups(session).items():
        try:
            if os.getsid(pid) == session and os.getpgid(pid) == group:
                if group == os.getpgrp():
                    raise AssertionError("refusing to signal the test supervisor")
                os.killpg(group, signal.SIGKILL)
                print(f"cleaned verified fixture group {group} in session {session}")
        except ProcessLookupError:
            continue


def check_deadline(script: str) -> None:
    """Require production to fail promptly and leave no signal-ignoring child."""
    with subprocess.Popen(
        ["bash", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    ) as process:
        try:
            try:
                output, _ = process.communicate(timeout=3)
            except subprocess.TimeoutExpired as error:
                raise AssertionError("deadline left a live fixture") from error
            print(output, end="")
            if process.returncode != 1:
                raise AssertionError(f"setup exit 1 expected, got {process.returncode}")
            survivors = owned_groups(process.pid)
            if survivors:
                raise AssertionError(f"live fixture groups: {survivors}")
            print("bounded setup failure; no live fixture groups")
        finally:
            cleanup(process.pid)
            process.communicate(timeout=2)


def main() -> None:
    """Run a supervised production path or a child that really ignores TERM."""
    if sys.argv[1] == "ignore-term":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with Path(os.environ["READINESS_EVENTS"]).open("a", encoding="utf-8") as events:
            events.write(f"ignoring TERM: {sys.argv[2]}\n")
        while True:
            signal.pause()
    check_deadline(sys.argv[1])


if __name__ == "__main__":
    main()
