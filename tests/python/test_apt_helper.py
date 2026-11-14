# SPDX-License-Identifier: MIT
# pylint: disable=too-many-lines  # One case per helper rule; split files would hide gaps.
"""Tests for ``scripts/ci/lib/apt_helper.py`` (#1432).

The CLI tests run the helper as a process with the checked-in fake
``apt-get`` (``tests/fixtures/apt/fake-apt-get``) first on ``PATH`` and an apt
configuration root copied from ``tests/fixtures/apt``. No real apt and no
network are involved. Like apt, the fake applies the ``-o`` options of each
call; the slow-source tests prove that wiring by having it honour the
timeout it got, and the signal tests use its hang mode.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import pty
import re
import select
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Any

import pytest
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/lib/apt_helper.py"
MIRROR = "apt could not reach a package mirror"
EXPECTED_ERROR = f"::error::{MIRROR} (DNS or network failure) after all retries"
DNS_FAILURE = (
    "E: Failed to fetch https://security.ubuntu.com/ubuntu/pool/universe/m/musl/"
    "musl-tools_1.2.5-3build1_amd64v3.deb"
    "  Temporary failure resolving 'security.ubuntu.com'"
)
UPDATE_DNS_WARNING = (
    "W: Failed to fetch mirror+file:/etc/apt/apt-mirrors.txt/dists/resolute/InRelease"
    "  Temporary failure resolving 'security.ubuntu.com'"
)
NOT_FOUND = "E: Unable to locate package no-such-package"
NOT_NETWORK = "(no DNS or network failure in its output)"
MS_URI = "URIs: https://packages.microsoft.com/u\n"
THIRD_PARTY = [
    "git-core-ubuntu-ppa-resolute.sources",
    "microsoft-prod.list",
    "microsoft-with-disabled-mirror.sources",
    "multi-line-ppas.sources",
]
KEPT = [
    "apt-cacher.list",
    "azure-mirror.list",
    "corporate-mirror.list",
    "kernel-org.list",
    "local-repo-with-disabled-microsoft.sources",
    "multi-line-mixed.sources",
    "ubuntu.sources",
]
HIT = "Hit:1 http://azure.archive.ubuntu.com/ubuntu resolute InRelease"
INJECTION = '"; DPkg::Pre-Invoke { "true"; }; Junk "'
SIGNAL_DEADLINE_SECONDS = 60


@dataclass
class Result:
    """A finished helper run.

    Attributes:
        code: Exit code.
        stdout: Standard output (apt output and the annotation).
        stderr: Standard error (helper log lines).
        calls: One record per fake ``apt-get`` call.
        seconds: Wall-clock duration.
    """

    code: int
    stdout: str
    stderr: str
    calls: list[dict[str, Any]]
    seconds: float

    def errors(self) -> list[str]:
        """Return the ``::error`` annotation lines."""
        return [line for line in self.stdout.splitlines() if line.startswith("::error")]


@pytest.fixture(name="helper")
def fixture_helper(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the helper without running it."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="streamer")
def fixture_streamer(helper: ModuleType) -> ModuleType:
    """Return ``apt_stream``, the module the loaded helper runs apt through."""
    return sys.modules[helper.on_signal.__module__]


@pytest.fixture(name="project_root")
def fixture_project_root(fixtures_dir: Path) -> Path:
    """Return the repository root."""
    return fixtures_dir.parents[1]


@pytest.fixture(name="apt_root")
def fixture_apt_root(tmp_path: Path, fixtures_dir: Path) -> Path:
    """Return a fake ``/etc/apt`` with the fixture sources."""
    root = tmp_path / "etc-apt"
    shutil.copytree(fixtures_dir / "apt/sources.list.d", root / "sources.list.d")
    shutil.copyfile(fixtures_dir / "apt/sources.list", root / "sources.list")
    return root


@pytest.fixture(name="helper_tmp")
def fixture_helper_tmp(tmp_path: Path) -> Path:
    """Return the helper's TMPDIR, so tests can see what it leaves behind."""
    path = tmp_path / "tmp"
    path.mkdir()
    return path


@pytest.fixture(name="helper_env")
def fixture_helper_env(
    tmp_path: Path,
    apt_root: Path,
    helper_tmp: Path,
    fixtures_dir: Path,
) -> dict[str, str]:
    """Return the base environment of a helper run with the fake apt-get."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    fake = bin_dir / "apt-get"
    shutil.copyfile(fixtures_dir / "apt/fake-apt-get", fake)
    fake.chmod(0o755)
    return {
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "TMPDIR": str(helper_tmp),
        "LGTM_CI_APT_ETC_DIR": str(apt_root),
        "LGTM_CI_APT_SUDO": "",
        "LGTM_CI_APT_BACKOFF_SECONDS": "0",
        "FAKE_APT_LOG": str(tmp_path / "apt-calls.jsonl"),
    }


@pytest.fixture(name="helper_cmd")
def fixture_helper_cmd(project_root: Path) -> list[str]:
    """Return the command that runs the helper."""
    return [sys.executable, "-I", str(project_root / SCRIPT_PATH)]


@pytest.fixture(name="run_helper")
def fixture_run_helper(
    helper_env: dict[str, str],
    helper_cmd: list[str],
    helper_tmp: Path,
) -> Callable[..., Result]:
    """Return a runner for the helper CLI against the fake apt-get."""
    log = Path(helper_env["FAKE_APT_LOG"])

    def _run(
        *args: str,
        plan: list[dict[str, Any]] | None = None,
        **env: str,
    ) -> Result:
        full_env = {
            **helper_env,
            "FAKE_APT_PLAN": json.dumps(plan or [{"exit": 0, "output": "ok"}]),
            **env,
        }
        start = time.monotonic()
        proc = subprocess.run(
            [*helper_cmd, *args],
            capture_output=True,
            text=True,
            env=full_env,
            timeout=120,
            check=False,
        )
        seconds = time.monotonic() - start
        calls = (
            [json.loads(line) for line in log.read_text("utf-8").splitlines()]
            if log.exists()
            else []
        )
        # Every run, whatever its outcome, removes its private sources dir.
        assert_that(list(helper_tmp.iterdir())).is_empty()
        return Result(proc.returncode, proc.stdout, proc.stderr, calls, seconds)

    return _run


def _verbs(result: Result) -> list[str]:
    """Return the apt-get verb (update/install) of every recorded call."""
    verbs = ("update", "install")
    return [next(a for a in call["argv"] if a in verbs) for call in result.calls]


# --- install / update ------------------------------------------------------


def test_install_succeeds_first_time(run_helper: Callable[..., Result]) -> None:
    """One update and one install, each carrying every option itself."""
    result = run_helper("install", "musl-tools")

    assert_that(result.code).is_equal_to(0)
    assert_that(_verbs(result)).is_equal_to(["update", "install"])
    assert_that(result.calls[1]["argv"][-4:]).is_equal_to(
        ["install", "-y", "-q", "musl-tools"],
    )
    for call in result.calls:
        assert_that(call["applied"]).contains_entry(
            {"Acquire::Retries": "3"},
            {"Acquire::http::Timeout": "15"},
            {"Acquire::https::Timeout": "15"},
        )
        assert_that(call["applied"]).does_not_contain_key("Dir::Etc::SourceList")
        parts = call["applied"]["Dir::Etc::SourceParts"]
        assert_that(Path(parts).name).starts_with("lgtm-ci-apt-sources-")
    assert_that(result.errors()).is_empty()


def test_each_invocation_gets_its_own_sources_dir(
    run_helper: Callable[..., Result],
) -> None:
    """Two runs never share a SourceParts directory (no global state)."""
    first = run_helper("update")
    second = run_helper("update")

    calls = first.calls + second.calls
    parts = [call["applied"]["Dir::Etc::SourceParts"] for call in calls]
    assert_that(set(parts)).is_length(2)


def test_transient_failure_then_success(run_helper: Callable[..., Result]) -> None:
    """A DNS failure on install is retried and the second attempt wins."""
    plan = [
        {"exit": 0, "output": HIT},
        {"exit": 100, "output": DNS_FAILURE},
        {"exit": 0, "output": "Setting up musl-tools"},
    ]
    result = run_helper("install", "musl-tools", plan=plan)

    assert_that(result.code).is_equal_to(0)
    assert_that(_verbs(result)).is_equal_to(["update", "install", "install"])
    assert_that(result.stderr).contains(
        "apt-get install: DNS or network failure (attempt 1/3)",
    )
    assert_that(result.errors()).is_empty()


def test_persistent_dns_failure_emits_the_stable_error(
    run_helper: Callable[..., Result],
) -> None:
    """Every attempt fails on DNS: one exact annotation and apt's exit code."""
    plan = [{"exit": 0, "output": ""}, {"exit": 100, "output": DNS_FAILURE}]
    result = run_helper("install", "musl-tools", plan=plan)

    assert_that(result.code).is_equal_to(100)
    assert_that(_verbs(result)).is_equal_to(["update", "install", "install", "install"])
    assert_that(result.errors()).is_equal_to([EXPECTED_ERROR])


def test_recovered_dns_failure_does_not_taint_a_later_failure(
    run_helper: Callable[..., Result],
) -> None:
    """DNS on update, then success, then a missing package: not network."""
    plan = [
        {"exit": 0, "output": UPDATE_DNS_WARNING},
        {"exit": 0, "output": HIT},
        {"exit": 100, "output": NOT_FOUND},
    ]
    result = run_helper("install", "no-such-package", plan=plan)

    assert_that(result.code).is_equal_to(100)
    assert_that(_verbs(result)).is_equal_to(["update", "update", "install"])
    assert_that(result.errors()).is_equal_to(
        [f"::error::apt-get install failed with exit code 100 {NOT_NETWORK}"],
    )


@pytest.mark.parametrize(
    "install_output",
    [
        pytest.param(NOT_FOUND, id="not-found"),
        pytest.param(
            "dpkg: error processing package libnss3 (--configure):\n"
            "E: Sub-process /usr/bin/dpkg returned an error code (1)",
            id="dpkg-configure",
        ),
    ],
)
def test_stale_update_does_not_make_an_install_error_a_network_failure(
    run_helper: Callable[..., Result],
    install_output: str,
) -> None:
    """Stale lists are logged, but an explicit install error stays one."""
    plan = [{"exit": 0, "output": UPDATE_DNS_WARNING}] * 3
    plan.append({"exit": 100, "output": install_output})
    result = run_helper("install", "musl-tools", plan=plan)

    assert_that(result.code).is_equal_to(100)
    assert_that(_verbs(result)).is_equal_to(["update", "update", "update", "install"])
    assert_that(result.errors()).does_not_contain(EXPECTED_ERROR)
    assert_that(result.errors()).is_length(1)


def test_update_command_fails_on_persistent_dns_warnings(
    run_helper: Callable[..., Result],
) -> None:
    """``update`` alone treats exhausted DNS warnings as a failure."""
    result = run_helper("update", plan=[{"exit": 0, "output": UPDATE_DNS_WARNING}])

    assert_that(result.code).is_equal_to(1)
    assert_that(_verbs(result)).is_equal_to(["update"] * 3)
    assert_that(result.errors()).is_equal_to([EXPECTED_ERROR])


def test_non_network_failure_is_not_retried_or_labelled_network(
    run_helper: Callable[..., Result],
) -> None:
    """``Unable to locate package`` fails once, with a non-network annotation."""
    plan = [{"exit": 0, "output": HIT}, {"exit": 100, "output": NOT_FOUND}]
    result = run_helper("install", "no-such-package", plan=plan)

    assert_that(result.code).is_equal_to(100)
    assert_that(_verbs(result)).is_equal_to(["update", "install"])
    assert_that(result.errors()).is_equal_to(
        [f"::error::apt-get install failed with exit code 100 {NOT_NETWORK}"],
    )


# --- third-party sources ---------------------------------------------------


def test_only_known_third_party_sources_are_left_out(
    run_helper: Callable[..., Result],
    apt_root: Path,
) -> None:
    """Microsoft and PPA files are left out; every other file stays.

    Kept: corporate, apt-cacher and kernel.org mirrors, a mixed multi-line
    file, and Sol's enabled ``file:`` stanza next to a disabled Microsoft
    one. Left out: a file whose only enabled stanza is Microsoft, even with
    a disabled corporate stanza. ``/etc/apt`` is untouched.
    """
    before = {p.name: p.read_bytes() for p in (apt_root / "sources.list.d").iterdir()}
    main_list = (apt_root / "sources.list").read_bytes()
    result = run_helper("install", "musl-tools")

    assert_that(result.code).is_equal_to(0)
    for call in result.calls:
        assert_that(sorted(call["sources"])).is_equal_to(KEPT)
    assert_that(result.stderr).contains(", ".join(THIRD_PARTY))
    after = {p.name: p.read_bytes() for p in (apt_root / "sources.list.d").iterdir()}
    assert_that(after).is_equal_to(before)
    assert_that((apt_root / "sources.list").read_bytes()).is_equal_to(main_list)


def test_third_party_sources_kept_on_opt_out(run_helper: Callable[..., Result]) -> None:
    """``LGTM_CI_APT_KEEP_THIRD_PARTY_SOURCES=true`` keeps every sources file."""
    result = run_helper("update", LGTM_CI_APT_KEEP_THIRD_PARTY_SOURCES="true")

    assert_that(result.code).is_equal_to(0)
    seen = sorted(result.calls[0]["sources"])
    assert_that(seen).is_equal_to(sorted(KEPT + THIRD_PARTY))
    assert_that(result.stderr).does_not_contain("left out third-party sources")


@pytest.mark.parametrize(
    ("name", "text", "third_party"),
    [
        ("ubuntu.sources", "URIs: https://packages.microsoft.com/u\n", False),
        ("debian.sources", "URIs: https://packages.microsoft.com/u\n", False),
        ("other.sources", "URIs: https://packages.microsoft.com/u\n", True),
        ("hostless.sources", "URIs: file:/srv/repo\n", False),
        ("cdrom.list", "deb cdrom:[Ubuntu]/ resolute main\n", False),
        ("mixed.sources", "URIs: https://ppa.launchpad.net/a cdrom:/b\n", False),
        ("all-disabled.sources", "URIs: https://example.com/a\nEnabled: no\n", False),
        ("disabled-false.sources", MS_URI + "Enabled: false\n", False),
        ("disabled-0.sources", MS_URI + "Enabled: 0\n", False),
        ("disabled-off.sources", MS_URI + "Enabled: off\n", False),
        ("disabled-without.sources", MS_URI + "Enabled: without\n", False),
        ("disabled-disable.sources", MS_URI + "Enabled: disable\n", False),
        ("disabled-No.sources", MS_URI + "Enabled: No\n", False),
        ("enabled-yes.sources", MS_URI + "Enabled: yes\n", True),
        ("empty.list", "# nothing\n", False),
    ],
)
def test_is_third_party(
    helper: ModuleType,
    tmp_path: Path,
    name: str,
    text: str,
    third_party: bool,
) -> None:
    """Only files whose enabled URIs are all on the denylist are left out."""
    path = tmp_path / name
    path.write_text(f"Types: deb\n{text}" if name.endswith(".sources") else text)

    assert_that(helper.is_third_party(path)).is_equal_to(third_party)


def test_deb822_continuation_lines_and_enabled(helper: ModuleType) -> None:
    """Every URI of a multi-line field is read; disabled stanzas are not."""
    text = (
        "# URIs: https://commented.example\n"
        "Types: deb\n"
        "URIs: https://a.example/ubuntu\n"
        " https://b.example/ubuntu\n"
        "\thttps://c.example/ubuntu\n"
        "Suites: resolute\n"
        "\n"
        "Types: deb\n"
        "URIs: http://disabled.example/ubuntu\n"
        "Enabled: No\n"
        "\n"
        "Types: deb\n"
        "URIs: http://d.example/ubuntu\n"
        "Enabled: yes\n"
    )

    assert_that(helper.source_uris(text, deb822=True)).is_equal_to(
        [
            "https://a.example/ubuntu",
            "https://b.example/ubuntu",
            "https://c.example/ubuntu",
            "http://d.example/ubuntu",
        ],
    )


# --- timeouts and the 30s criterion ----------------------------------------


def test_blocked_third_party_source_costs_under_30s(
    run_helper: Callable[..., Result],
) -> None:
    """A never-answering packages.microsoft.com does not delay the job (#1432).

    The fake sleeps for the HTTP timeout it applied whenever it can see an
    enabled source on the blocked host, and fails like apt; with the
    helper's defaults (3 attempts, 15s timeout, 5s backoff) a visible source
    would cost over 45s. The helper leaves the source out, so it costs
    nothing.
    """
    result = run_helper(
        "install",
        "musl-tools",
        FAKE_APT_SLOW_HOST="packages.microsoft.com",
        LGTM_CI_APT_BACKOFF_SECONDS="5",
    )

    assert_that(result.code).is_equal_to(0)
    assert_that(result.seconds).is_less_than(30)


def test_kept_slow_source_is_bounded_by_the_timeout_option(
    run_helper: Callable[..., Result],
) -> None:
    """Kept on opt-out, the slow source costs the configured timeout per attempt."""
    result = run_helper(
        "update",
        FAKE_APT_SLOW_HOST="ppa.launchpad.net",
        LGTM_CI_APT_KEEP_THIRD_PARTY_SOURCES="true",
        LGTM_CI_APT_TIMEOUT_SECONDS="1",
        LGTM_CI_APT_ATTEMPTS="2",
    )

    assert_that(result.code).is_equal_to(100)
    assert_that(_verbs(result)).is_equal_to(["update", "update"])
    assert_that(result.calls[0]["applied"]["Acquire::http::Timeout"]).is_equal_to("1")
    assert_that(result.seconds).is_between(2, 30)
    assert_that(result.errors()).is_equal_to([EXPECTED_ERROR])


# --- injection --------------------------------------------------------------


@pytest.mark.parametrize("command", [["update"], ["install", "musl-tools"]])
def test_unsafe_tmpdir_is_rejected_before_apt_runs(
    run_helper: Callable[..., Result],
    tmp_path: Path,
    command: list[str],
) -> None:
    """A TMPDIR that would inject apt configuration exits 2, runs nothing."""
    unsafe = tmp_path / INJECTION
    unsafe.mkdir()
    sudo_log = tmp_path / "sudo.log"
    sudo = tmp_path / "fake-sudo"
    sudo.write_text(f'#!/bin/sh\necho "$@" >> "{sudo_log}"\nexec "$@"\n', "utf-8")
    sudo.chmod(0o755)

    result = run_helper(*command, TMPDIR=str(unsafe), LGTM_CI_APT_SUDO=str(sudo))

    assert_that(result.code).is_equal_to(2)
    assert_that(result.stderr).contains("temporary directory")
    assert_that(sudo_log.exists()).is_false()
    assert_that(result.calls).is_empty()
    assert_that(list(unsafe.iterdir())).is_empty()


@pytest.mark.parametrize(
    "value",
    [INJECTION, "/tmp/a b", '/tmp/a"b', "/tmp/a;b", "/tmp/a{b}", "/tmp/a\nb"],
)
def test_option_values_reject_unsafe_paths(
    helper: ModuleType,
    value: str,
) -> None:
    """No path outside ``[A-Za-z0-9/._-]`` reaches an apt option."""
    with pytest.raises(helper.UsageError):
        helper.option_args(helper.Settings(), Path(value))


@pytest.mark.parametrize(
    "package",
    [
        "-oDPkg::Pre-Invoke=x",
        "curl-",
        "foo=1.0",
        "foo/resolute",
        "pkg:amd64",
        "Libnss3",
        "a",
        "pkg;rm",
        "pkg name",
        "²x",
    ],
)
def test_invalid_package_names_exit_2(
    run_helper: Callable[..., Result],
    package: str,
) -> None:
    """Only Debian policy package names reach apt-get."""
    result = run_helper("install", "libnss3", package)

    assert_that(result.code).is_equal_to(2)
    assert_that(result.calls).is_empty()


def test_valid_package_names_reach_apt(run_helper: Callable[..., Result]) -> None:
    """A trailing ``+`` (``g++``) and dotted names are real packages."""
    result = run_helper("install", "g++", "libatk-bridge2.0-0t64", "libc6")

    assert_that(result.code).is_equal_to(0)
    assert_that(result.calls[1]["argv"][-3:]).is_equal_to(
        ["g++", "libatk-bridge2.0-0t64", "libc6"],
    )


def test_update_keeps_the_lists_of_left_out_sources(
    run_helper: Callable[..., Result],
) -> None:
    """Every update passes ``APT::Get::List-Cleanup=0``; install does not need it."""
    result = run_helper("install", "musl-tools")
    update, install = result.calls

    assert_that(update["applied"]).contains_entry({"APT::Get::List-Cleanup": "0"})
    assert_that(install["applied"]).does_not_contain_key("APT::Get::List-Cleanup")
    assert_that(run_helper("update").calls[-1]["applied"]).contains_entry(
        {"APT::Get::List-Cleanup": "0"},
    )


@pytest.mark.parametrize(("flag", "expected"), [(True, True), (False, False)])
def test_no_install_recommends_is_opt_in(
    run_helper: Callable[..., Result],
    flag: bool,
    expected: bool,
) -> None:
    """``--no-install-recommends`` reaches apt-get install only when asked."""
    args = (
        ["install", "--no-install-recommends", "libnss3"]
        if flag
        else [
            "install",
            "libnss3",
        ]
    )
    result = run_helper(*args)

    install = result.calls[1]["argv"]
    assert_that("--no-install-recommends" in install).is_equal_to(expected)
    assert_that(install[-1]).is_equal_to("libnss3")
    assert_that(result.calls[0]["argv"]).does_not_contain("--no-install-recommends")


# --- cancellation -----------------------------------------------------------


@pytest.mark.parametrize("signum", [signal.SIGTERM, signal.SIGHUP, signal.SIGINT])
def test_signal_stops_the_process_group_cleans_up_and_exits_128_plus_n(
    helper_env: dict[str, str],
    helper_cmd: list[str],
    helper_tmp: Path,
    tmp_path: Path,
    signum: signal.Signals,
) -> None:
    """A signal reaches apt and its grandchild; the sources dir is removed.

    Handshake: the fake apt-get writes ``ready`` only after its own handler
    and its grandchild's trap are in place, so no fixed sleep is needed.
    """
    hang = tmp_path / "hang"
    hang.mkdir()
    env = {**helper_env, "FAKE_APT_HANG_DIR": str(hang)}
    with subprocess.Popen(
        [*helper_cmd, "update"],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    ) as proc:
        deadline = time.monotonic() + SIGNAL_DEADLINE_SECONDS
        while not (hang / "ready").exists():
            assert_that(proc.poll()).is_none()
            assert_that(time.monotonic()).is_less_than(deadline)
            time.sleep(0.01)
        assert_that([p.name for p in helper_tmp.iterdir()]).is_length(1)
        proc.send_signal(signum)
        _, stderr = proc.communicate(timeout=SIGNAL_DEADLINE_SECONDS)

    grandchild = int((hang / "grandchild.pid").read_text("utf-8"))
    assert_that(proc.returncode).is_equal_to(128 + int(signum))
    assert_that((hang / "apt-signal").read_text("utf-8")).is_equal_to(str(int(signum)))
    assert_that((hang / "grandchild-signal").read_text("utf-8").strip()).is_equal_to(
        signum.name.removeprefix("SIG"),
    )
    with pytest.raises(ProcessLookupError):
        os.kill(grandchild, 0)
    assert_that(list(helper_tmp.iterdir())).is_empty()
    assert_that(stderr).contains(f"interrupted by signal {int(signum)}")


def _wait_for(path: Path) -> None:
    """Wait (bounded) for a handshake file."""
    deadline = time.monotonic() + SIGNAL_DEADLINE_SECONDS
    while not path.exists():
        assert_that(time.monotonic()).is_less_than(deadline)
        time.sleep(0.01)


def _gone(pid: int) -> bool:
    """Return whether a process no longer exists (waits briefly for reaping)."""
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.02)
    return False


def _handle_signal_with(
    streamer: ModuleType,
    script: str,
    ready: Path,
) -> int | None:
    """Run ``_on_signal`` against a session-leader shell running ``script``.

    Returns:
        The leader's status right after the handler.
    """
    previous = {sig: signal.getsignal(sig) for sig in streamer.HANDLED_SIGNALS}
    with subprocess.Popen(
        ["/bin/sh", "-c", script],
        start_new_session=True,
        text=True,
    ) as child:
        streamer._CHILDREN.append(child)  # pylint: disable=protected-access
        try:
            _wait_for(ready)
            with pytest.raises(streamer.Interrupted):
                streamer.on_signal(signal.SIGTERM, None)
            status = child.poll()
        finally:
            # macOS reports EPERM for a group of zombies.
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(child.pid, signal.SIGKILL)
            streamer._CHILDREN.clear()  # pylint: disable=protected-access
            for sig, handler in previous.items():
                signal.signal(sig, handler)
    return status


def test_signal_handler_kills_a_leader_that_ignores_the_signal(
    streamer: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """After the grace period the group gets SIGKILL, with a dpkg-lock warning."""
    monkeypatch.setattr(streamer, "CHILD_GRACE_SECONDS", 0.3)
    ready = tmp_path / "ready"
    script = f"trap '' TERM; touch '{ready}'; while :; do sleep 1; done"

    status = _handle_signal_with(streamer, script, ready)

    assert_that(status).is_equal_to(-signal.SIGKILL)
    out = capsys.readouterr().out
    assert_that(out).contains("::warning::apt did not stop within 0.3s")
    assert_that(out).contains("holding the dpkg lock")


def test_signal_handler_kills_a_grandchild_after_the_leader_exits(
    streamer: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """The leader dies on SIGTERM; a TERM-ignoring grandchild still gets SIGKILL."""
    monkeypatch.setattr(streamer, "CHILD_GRACE_SECONDS", 0.3)
    ready = tmp_path / "ready"
    pid_file = tmp_path / "grandchild.pid"
    # \$\$ is the grandchild's own pid; the leader exits on SIGTERM at once.
    loop = "while :; do sleep 0.1; done"
    grandchild = f"trap '' TERM; echo \\$\\$ > '{pid_file}'; {loop}"
    script = (
        f'/bin/sh -c "{grandchild}" & '
        f"while [ ! -s '{pid_file}' ]; do sleep 0.01; done; touch '{ready}'; "
        "while :; do sleep 0.1; done"
    )

    status = _handle_signal_with(streamer, script, ready)

    assert_that(status).is_equal_to(-signal.SIGTERM)
    assert_that(_gone(int(pid_file.read_text("utf-8")))).is_true()
    assert_that(capsys.readouterr().out).contains("::warning::apt did not stop")


def test_signal_handler_does_not_warn_when_the_group_stops(
    streamer: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """A group that exits on the forwarded signal is not escalated."""
    monkeypatch.setattr(streamer, "CHILD_GRACE_SECONDS", 5)
    ready = tmp_path / "ready"
    script = f"touch '{ready}'; while :; do sleep 0.1; done"

    status = _handle_signal_with(streamer, script, ready)

    assert_that(status).is_equal_to(-signal.SIGTERM)
    assert_that(capsys.readouterr().out).does_not_contain("::warning::")


RACE_DRIVER = r"""
import importlib.util, json, os, signal, subprocess, sys
spec = importlib.util.spec_from_file_location("apt_helper", sys.argv[1])
helper = importlib.util.module_from_spec(spec)
sys.modules["apt_helper"] = helper
spec.loader.exec_module(helper)
streamer = sys.modules["apt_stream"]
started = []

class Racing(subprocess.Popen):
    # Deliver SIGTERM right after the child exists, before stream() can
    # register it: the boundary the signal mask protects.
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        started.append(self)
        os.kill(os.getpid(), signal.SIGTERM)

streamer.subprocess.Popen = Racing
for sig in streamer.HANDLED_SIGNALS:
    signal.signal(sig, streamer.on_signal)
try:
    streamer.stream(["sleep", "30"])
    outcome = "not interrupted"
except streamer.Interrupted as error:
    outcome = f"interrupted {error.signum}"
child = started[0]
alive = child.poll() is None
if alive:
    os.killpg(child.pid, signal.SIGKILL)
registered = len(streamer._CHILDREN)
print(json.dumps({"outcome": outcome, "alive": alive,
                  "returncode": child.returncode, "registered": registered}))
"""


def test_signal_at_process_start_is_not_lost(project_root: Path) -> None:
    """A signal between Popen and registration still stops the child.

    The driver runs in its own process with a timeout, so a regression fails
    instead of hanging the suite.
    """
    proc = subprocess.run(
        [sys.executable, "-I", "-c", RACE_DRIVER, str(project_root / SCRIPT_PATH)],
        capture_output=True,
        text=True,
        timeout=SIGNAL_DEADLINE_SECONDS,
        check=False,
    )

    result = json.loads(proc.stdout.strip().splitlines()[-1])
    assert_that(result).is_equal_to(
        {
            "outcome": f"interrupted {int(signal.SIGTERM)}",
            "alive": False,
            # The child got the forwarded SIGTERM itself: it was started
            # with the signals unblocked.
            "returncode": -signal.SIGTERM,
            "registered": 0,
        },
    )


# --- arguments and settings ------------------------------------------------


@pytest.mark.parametrize(
    "args",
    [[], ["install"], ["run", "--", "true"], ["install", "-o", "x"], ["upgrade"]],
)
def test_usage_errors_exit_2(
    run_helper: Callable[..., Result],
    args: list[str],
) -> None:
    """Bad command lines (including the removed ``run`` mode) exit 2."""
    result = run_helper(*args)

    assert_that(result.code).is_equal_to(2)
    assert_that(result.calls).is_empty()


@pytest.mark.parametrize(
    ("name", "value"),
    [
        ("LGTM_CI_APT_ATTEMPTS", "0"),
        ("LGTM_CI_APT_ATTEMPTS", "6"),
        ("LGTM_CI_APT_ATTEMPTS", "²"),
        ("LGTM_CI_APT_ATTEMPTS", "٣"),
        ("LGTM_CI_APT_BACKOFF_SECONDS", "31"),
        ("LGTM_CI_APT_TIMEOUT_SECONDS", "x"),
        ("LGTM_CI_APT_TIMEOUT_SECONDS", "121"),
        ("LGTM_CI_APT_ACQUIRE_RETRIES", "6"),
        ("LGTM_CI_APT_CALL_TIMEOUT_SECONDS", "0"),
        ("LGTM_CI_APT_CALL_TIMEOUT_SECONDS", "3601"),
        ("LGTM_CI_APT_CALL_TIMEOUT_SECONDS", "1.5"),
    ],
)
def test_invalid_environment_exits_2(
    run_helper: Callable[..., Result],
    name: str,
    value: str,
) -> None:
    """Out-of-range or non-ASCII-digit settings are usage errors."""
    result = run_helper("update", **{name: value})

    assert_that(result.code).is_equal_to(2)
    assert_that(result.stderr).contains(name)
    assert_that(result.calls).is_empty()


@pytest.mark.parametrize(
    ("attempts", "backoff", "expected"),
    [
        (3, 5.0, [5.0, 10.0]),
        (5, 30.0, [30.0, 30.0, 0.0, 0.0]),
        (5, 10.0, [10.0, 20.0, 30.0, 0.0]),
        (5, 4.0, [4.0, 8.0, 16.0, 30.0]),
        (1, 30.0, []),
    ],
)
def test_backoff_is_capped(
    helper: ModuleType,
    attempts: int,
    backoff: float,
    expected: list[float],
) -> None:
    """Each delay is at most 30s and the delays of one call at most 60s."""
    settings = helper.Settings(attempts=attempts, backoff_seconds=backoff)

    delays = helper.backoff_delays(settings)

    assert_that(delays).is_equal_to(expected)
    assert_that(sum(delays)).is_less_than_or_equal_to(60)


def test_retries_sleep_the_capped_delays(helper: ModuleType) -> None:
    """``run_with_retries`` sleeps exactly the capped delays."""
    delays: list[float] = []
    session = helper.Session(
        runner=lambda _argv, _timeout: (100, [DNS_FAILURE]),
        sleeper=delays.append,
    )
    settings = helper.Settings(attempts=5, backoff_seconds=30.0)

    outcome = helper.run_with_retries("apt-get update", ["x"], settings, session)

    assert_that(outcome.network).is_true()
    assert_that(delays).is_equal_to([30.0, 30.0, 0.0, 0.0])


def test_missing_executable_is_not_a_network_failure(
    helper: ModuleType,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A missing executable exits 127 and is not labelled as a network failure."""
    code, lines = helper.stream(["lgtm-ci-no-such-binary-1432"])
    capsys.readouterr()

    assert_that(code).is_equal_to(127)
    assert_that(helper.has_network_signature(lines)).is_false()


@pytest.mark.parametrize(
    ("line", "expected"),
    [
        (
            "Err:2 https://security.ubuntu.com"
            "  Temporary failure resolving 'security.ubuntu.com'",
            True,
        ),
        (
            "E: Failed to fetch https://packages.microsoft.com/x"
            "  Could not connect to 13.107.1.1:443",
            True,
        ),
        ("E: Failed to fetch http://x/y  Connection timed out [IP: 1.2.3.4 80]", True),
        ("E: Unable to connect to archive.ubuntu.com:http:", True),
        ("E: Could not resolve 'blocked.example'", False),
        (NOT_FOUND, False),
    ],
)
def test_network_signatures(helper: ModuleType, line: str, expected: bool) -> None:
    """Only the documented DNS and connection messages count as network failures."""
    assert_that(helper.has_network_signature([line])).is_equal_to(expected)


def test_default_sudo_depends_on_uid(
    helper: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Without ``LGTM_CI_APT_SUDO`` a non-root user gets ``sudo``, root none."""
    monkeypatch.setattr(helper.os, "geteuid", lambda: 1000)
    assert_that(helper.load_settings({}).sudo).is_equal_to(("sudo",))
    monkeypatch.setattr(helper.os, "geteuid", lambda: 0)
    assert_that(helper.load_settings({}).sudo).is_equal_to(())


def test_no_direct_apt_calls_outside_the_helper(project_root: Path) -> None:
    """Every apt call in scripts and workflows goes through the helper (#1432).

    Comment lines are documentation and are skipped. ``--with-deps`` is
    checked by the Playwright BATS tests: it remains only as the off-Linux
    path and the unrecognised-dry-run fallback.
    """
    pattern = re.compile(r"\bapt-get\b|\bapt (?:update|install)\b")
    # The helper itself, and the parser that reads the apt command older
    # Playwright versions print (it never runs it).
    allowed = {
        project_root / SCRIPT_PATH,
        project_root / "scripts/ci/lib/playwright_deps.py",
    }
    offenders: list[str] = []
    for top in ("scripts", ".github"):
        for path in sorted((project_root / top).rglob("*")):
            suffixes = (".sh", ".py", ".yml", ".yaml")
            if not path.is_file() or path in allowed or path.suffix not in suffixes:
                continue
            lines = path.read_text("utf-8").splitlines()
            for number, line in enumerate(lines, start=1):
                stripped = line.strip()
                if stripped.startswith("#") or 'echo "  apt install' in stripped:
                    continue
                if pattern.search(stripped):
                    rel = path.relative_to(project_root)
                    offenders.append(f"{rel}:{number}: {stripped}")

    assert_that(offenders).is_empty()


def test_stream_keeps_universal_newlines(helper: ModuleType, tmp_path: Path) -> None:
    """CRLF and bare CR from apt split into lines as in text mode."""
    script = tmp_path / "emit"
    script.write_text("#!/bin/sh\nprintf 'a\\r\\nb\\rc\\n'\n")
    script.chmod(0o755)

    returncode, lines = helper.stream([str(script)])

    assert_that(returncode).is_equal_to(0)
    assert_that(lines).is_equal_to(["a", "b", "c"])


def test_apt_runs_in_the_c_locale(helper: ModuleType, tmp_path: Path) -> None:
    """Network signatures are English, so apt must not be localised."""
    settings = helper.load_settings({})
    argv = helper.apt_get(settings, tmp_path, "update")

    assert_that(argv).contains("LC_ALL=C")
    assert_that(argv.index("LC_ALL=C")).is_less_than(argv.index("apt-get"))


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("no", True),
        ("False", True),
        ("disable", True),
        ("0", True),
        ("00", True),
        ("+0", True),
        ("-0", True),
        ("0x0", True),
        ("0abc", False),
        ("0x", False),
        ("08", False),
        ("  0", True),
        ("4294967296", True),
        ("4294967297", False),
        ("99999999999999999999", False),
        ("yes", False),
        ("1", False),
        ("01", False),
        ("0x1", False),
        ("2", False),
        ("maybe", False),
    ],
)
def test_apt_false_matches_string_to_bool(
    helper: ModuleType,
    value: str,
    expected: bool,
) -> None:
    """Enabled values are read the way apt's StringToBool reads them."""
    assert_that(helper.apt_false(value)).is_equal_to(expected)


def test_stream_reports_a_signal_death_as_128_plus_n(
    helper: ModuleType,
    tmp_path: Path,
) -> None:
    """A child killed by a signal exits 128+N, not Popen's negative code."""
    script = tmp_path / "die"
    script.write_text("#!/bin/sh\nkill -KILL $$\n")
    script.chmod(0o755)

    returncode, _ = helper.stream([str(script)])

    assert_that(returncode).is_equal_to(128 + 9)


def test_signal_death_is_not_a_network_failure(
    helper: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """apt killed after printing a DNS error is not retried or annotated."""
    count = tmp_path / "count"
    script = tmp_path / "dns-then-die"
    dns = f'echo "{DNS_FAILURE}"'
    lines = ["#!/bin/sh", f"echo x >> {count}", dns, "kill -KILL $$"]
    script.write_text("\n".join(lines) + "\n")
    script.chmod(0o755)
    settings = helper.load_settings({"LGTM_CI_APT_BACKOFF_SECONDS": "0"})
    session = helper.Session(runner=helper.stream, sleeper=lambda _delay: None)

    argv = [str(script)]
    outcome = helper.run_with_retries("apt-get install", argv, settings, session)

    assert_that(outcome.returncode).is_equal_to(128 + 9)
    assert_that(outcome.network).is_false()
    assert_that(count.read_text().splitlines()).is_length(1)
    assert_that(capsys.readouterr().out).does_not_contain(EXPECTED_ERROR)


def test_install_killed_after_stale_update_is_not_a_network_failure(
    helper: ModuleType,
    helper_env: dict[str, str],
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Stale indexes from update do not turn a killed install into DNS."""
    calls: list[list[str]] = []

    def runner(argv: list[str], _timeout: float | None) -> tuple[int, list[str]]:
        calls.append(list(argv))
        if "update" in argv:
            return 0, [UPDATE_DNS_WARNING]
        return 128 + 9, []

    settings = helper.load_settings(helper_env)
    session = helper.Session(runner=runner, sleeper=lambda _delay: None)

    code = helper.cmd_install(settings, ["curl"], session)

    assert_that(code).is_equal_to(128 + 9)
    assert_that(capsys.readouterr().out).does_not_contain(EXPECTED_ERROR)


def test_no_update_skips_the_refresh(run_helper: Callable[..., Result]) -> None:
    """``install --no-update`` runs only the install, not a second update."""
    plan = [{"exit": 0, "output": ""}]
    result = run_helper("install", "--no-update", "libnss3", plan=plan)

    assert_that(result.code).is_equal_to(0)
    assert_that(_verbs(result)).is_equal_to(["install"])


def test_no_update_with_no_install_recommends(
    run_helper: Callable[..., Result],
) -> None:
    """Both flags together: one install call, with --no-install-recommends."""
    plan = [{"exit": 0, "output": ""}]
    result = run_helper(
        "install",
        "--no-update",
        "--no-install-recommends",
        "libnss3",
        plan=plan,
    )

    assert_that(result.code).is_equal_to(0)
    assert_that(_verbs(result)).is_equal_to(["install"])
    assert_that(result.calls[0]["argv"]).contains("--no-install-recommends")


# --- per-call deadline and run budget (#1571) ----------------------------

STALL = {"stall": True, "output": HIT}
PLAYWRIGHT_RUNNER = "scripts/ci/lib/testing/playwright_runner.sh"
PLAYWRIGHT_WORKFLOW = ".github/workflows/reusable-test-e2e-playwright.yml"
# Seconds left for the install-deps dry run, npx and interpreter start-up.
PLAYWRIGHT_STEP_MARGIN_SECONDS = 120
CLEAN_EXIT_MARKERS = ("Fatal Python error", "Traceback", "_enter_buffered_busy")


def _timeout_error(label: str, call: int, total: int = 300) -> str:
    """Return the annotation for a call that timed out."""
    return f"::error::{label} timed out ({call}s per attempt, {total}s per helper run)"


def _shell_int(path: Path, name: str) -> int:
    """Return the integer a shell file assigns to ``name``."""
    match = re.search(rf"^{name}=([0-9]+)$", path.read_text("utf-8"), re.MULTILINE)
    assert match is not None, f"{name} not found in {path}"
    return int(match.group(1))


def _step_timeout_minutes(workflow: Path, step: str) -> int:
    """Return the ``timeout-minutes`` of a workflow step."""
    text = workflow.read_text("utf-8")
    pattern = rf"- name: {re.escape(step)}\n(?:\s+\S.*\n)*?\s+timeout-minutes: (\d+)"
    match = re.search(pattern, text)
    assert match is not None, f"no timeout-minutes for {step!r}"
    return int(match.group(1))


class FakeClock:
    """A clock that attempts and backoff sleeps advance."""

    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        """Advance by a backoff delay."""
        self.now += seconds


def test_call_timeout_and_budget_defaults(helper: ModuleType) -> None:
    """Unset, each attempt gets 100s and one helper run 300s."""
    settings = helper.load_settings({"LGTM_CI_APT_SUDO": ""})

    assert_that(settings.call_timeout_seconds).is_equal_to(100)
    assert_that(settings.total_timeout_seconds).is_equal_to(300)


@pytest.mark.parametrize("value", ["29", "3601", "x"])
def test_invalid_total_timeout_exits_2(
    run_helper: Callable[..., Result],
    value: str,
) -> None:
    """The run budget must be an integer from 30 to 3600."""
    result = run_helper("update", LGTM_CI_APT_TOTAL_TIMEOUT_SECONDS=value)

    assert_that(result.code).is_equal_to(2)
    assert_that(result.stderr).contains("LGTM_CI_APT_TOTAL_TIMEOUT_SECONDS")


@pytest.mark.parametrize("attempts", [1, 3, 5])
def test_worst_case_run_stays_inside_the_budget(
    helper: ModuleType,
    streamer: ModuleType,
    attempts: int,
) -> None:
    """Every attempt stalls and needs SIGKILL: the run still ends in its budget.

    Each attempt is charged its whole deadline plus the longest stop
    (``stop_reserve()``: ``2 * CHILD_GRACE_SECONDS`` and the echo flush), on
    a simulated clock.
    """
    clock = FakeClock()
    timeouts: list[float] = []

    def runner(_argv: Sequence[str], timeout: float | None) -> tuple[int, list[str]]:
        assert timeout is not None
        timeouts.append(timeout)
        clock.now += timeout + streamer.stop_reserve()
        return helper.EXIT_TIMED_OUT, []

    settings = helper.Settings(attempts=attempts, backoff_seconds=5.0)
    start = clock.now
    session = helper.Session(
        runner=runner,
        sleeper=clock.sleep,
        clock=clock,
        deadline=start + settings.total_timeout_seconds,
    )

    outcome = helper.run_with_retries("apt-get update", ["x"], settings, session)

    assert_that(outcome.timed_out).is_true()
    assert_that(clock.now - start).is_less_than_or_equal_to(300)
    assert_that(streamer.stop_reserve()).is_equal_to(21.0)
    assert_that(min(timeouts)).is_greater_than_or_equal_to(helper.MIN_ATTEMPT_SECONDS)
    # 100 + 21, 5s backoff, 100 + 21, 10s backoff leaves 43s: a 22s third
    # attempt and its 21s stop. Nothing is left for a fourth.
    assert_that(timeouts).is_equal_to([100.0, 100.0, 22.0][:attempts])


def test_stalled_update_leaves_the_install_a_full_attempt(
    helper: ModuleType,
    streamer: ModuleType,
) -> None:
    """``install`` without ``--no-update``: a stalled update leaves room."""
    clock = FakeClock()
    timeouts: list[float] = []

    def runner(_argv: Sequence[str], timeout: float | None) -> tuple[int, list[str]]:
        assert timeout is not None
        timeouts.append(timeout)
        clock.now += timeout + streamer.stop_reserve()
        return helper.EXIT_TIMED_OUT, []

    settings = helper.Settings(attempts=1)
    session = helper.Session(
        runner=runner,
        sleeper=clock.sleep,
        clock=clock,
        deadline=clock.now + settings.total_timeout_seconds,
    )

    helper.run_with_retries("apt-get update", ["x"], settings, session)
    helper.run_with_retries("apt-get install", ["x"], settings, session)

    assert_that(timeouts).is_equal_to([100.0, 100.0])


def test_playwright_install_step_fits_its_worst_case(
    helper: ModuleType,
    project_root: Path,
) -> None:
    """update + install + two browser downloads fit the step's backstop.

    Each helper run ends within its budget (previous test); the browser
    download is bounded per attempt and retried once (#1563).
    """
    runner = project_root / PLAYWRIGHT_RUNNER
    apt_budget = _shell_int(runner, "PLAYWRIGHT_APT_TIMEOUT_DEFAULT")
    download = _shell_int(runner, "PLAYWRIGHT_INSTALL_TIMEOUT_DEFAULT")
    grace = _shell_int(runner, "PLAYWRIGHT_INSTALL_KILL_GRACE_DEFAULT")
    step = _step_timeout_minutes(
        project_root / PLAYWRIGHT_WORKFLOW,
        "Install Playwright browsers",
    )

    worst = 2 * apt_budget + 2 * (download + grace)

    assert_that(apt_budget).is_less_than_or_equal_to(helper.MAX_TOTAL_TIMEOUT_SECONDS)
    assert_that(worst).is_equal_to(1220)
    assert_that(step).is_equal_to(25)
    assert_that(worst + PLAYWRIGHT_STEP_MARGIN_SECONDS).is_less_than_or_equal_to(
        step * 60,
    )


def test_stalled_update_is_stopped_retried_and_fails_with_the_timeout_message(
    run_helper: Callable[..., Result],
) -> None:
    """A silent apt-get is stopped at each deadline, retried, then annotated."""
    result = run_helper("update", plan=[STALL], LGTM_CI_APT_CALL_TIMEOUT_SECONDS="1")

    assert_that(result.code).is_equal_to(124)
    assert_that(_verbs(result)).is_equal_to(["update", "update", "update"])
    assert_that(result.errors()).is_equal_to([_timeout_error("apt-get update", 1)])
    assert_that(result.stderr).contains(
        "apt-get update: timed out after 1s (attempt 1/3); retrying in 0s",
    )
    assert_that(result.stdout).contains(HIT)
    assert_that(result.seconds).is_less_than(30)


def test_budget_stops_retries_when_no_room_is_left(
    run_helper: Callable[..., Result],
) -> None:
    """With 30s per run and 20s reserved to stop, a third 3s attempt never starts."""
    result = run_helper(
        "update",
        plan=[STALL],
        LGTM_CI_APT_CALL_TIMEOUT_SECONDS="3",
        LGTM_CI_APT_TOTAL_TIMEOUT_SECONDS="30",
    )

    assert_that(result.code).is_equal_to(124)
    assert_that(_verbs(result)).is_equal_to(["update", "update"])
    assert_that(result.stderr).contains("no time left in the 30s budget for attempt 3")
    assert_that(result.errors()).is_equal_to(
        [_timeout_error("apt-get update", 3, total=30)],
    )
    assert_that(result.seconds).is_less_than(30)


def test_stall_then_success_recovers(run_helper: Callable[..., Result]) -> None:
    """A stall on the first update attempt is retried; the run succeeds."""
    plan = [
        STALL,
        {"exit": 0, "output": HIT},
        {"exit": 0, "output": "Setting up musl-tools"},
    ]
    result = run_helper(
        "install",
        "musl-tools",
        plan=plan,
        LGTM_CI_APT_CALL_TIMEOUT_SECONDS="1",
    )

    assert_that(result.code).is_equal_to(0)
    assert_that(_verbs(result)).is_equal_to(["update", "update", "install"])
    assert_that(result.stderr).contains("apt-get update: timed out after 1s")
    assert_that(result.errors()).is_empty()


def test_stalled_install_fails_with_the_timeout_message(
    run_helper: Callable[..., Result],
) -> None:
    """The install has its own deadline and message, never the DNS one."""
    plan = [{"exit": 0, "output": HIT}, STALL]
    result = run_helper(
        "install",
        "musl-tools",
        plan=plan,
        LGTM_CI_APT_CALL_TIMEOUT_SECONDS="1",
        LGTM_CI_APT_ATTEMPTS="2",
    )

    assert_that(result.code).is_equal_to(124)
    assert_that(_verbs(result)).is_equal_to(["update", "install", "install"])
    assert_that(result.errors()).is_equal_to([_timeout_error("apt-get install", 1)])


def _slow_reader(stream: Any, sink: list[bytes]) -> None:
    """Drain a pipe slowly, as a backpressured log consumer does."""
    time.sleep(0.5)
    while chunk := stream.read1(4096):
        sink.append(chunk)
        time.sleep(0.005)


def _kill_quietly(pid_file: Path) -> None:
    """SIGKILL the process whose pid a file holds, if it is still there."""
    if pid_file.exists():
        with contextlib.suppress(ProcessLookupError, ValueError):
            os.kill(int(pid_file.read_text("utf-8")), signal.SIGKILL)


def test_detached_flood_into_a_slow_stdout_exits_124_cleanly(
    helper_env: dict[str, str],
    helper_cmd: list[str],
    tmp_path: Path,
) -> None:
    """A detached child holding and flooding the pipe cannot abort the helper.

    Review repro (#1571): with a reader thread still writing to a
    backpressured stdout at exit, CPython aborted (SIGABRT,
    ``_enter_buffered_busy``) instead of exiting 124.
    """
    pid_file = tmp_path / "detached.pid"
    env = {
        **helper_env,
        "FAKE_APT_PLAN": json.dumps([{"detach_flood": True, "stall": True}]),
        "FAKE_APT_DETACHED_PID": str(pid_file),
        "LGTM_CI_APT_CALL_TIMEOUT_SECONDS": "1",
        "LGTM_CI_APT_ATTEMPTS": "1",
    }
    out: list[bytes] = []
    try:
        with subprocess.Popen(
            [*helper_cmd, "update"],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ) as proc:
            reader = threading.Thread(target=_slow_reader, args=(proc.stdout, out))
            reader.start()
            stderr = proc.stderr.read() if proc.stderr else b""
            proc.wait(timeout=SIGNAL_DEADLINE_SECONDS)
            reader.join(SIGNAL_DEADLINE_SECONDS)
    finally:
        _kill_quietly(pid_file)

    text = stderr.decode("utf-8", "replace")
    assert_that(proc.returncode).is_equal_to(124)
    for marker in CLEAN_EXIT_MARKERS:
        assert_that(text).does_not_contain(marker)
    stdout = b"".join(out).decode("utf-8", "replace")
    assert_that(stdout).contains("flood.example")
    assert_that(stdout.rstrip().splitlines()[-1]).is_equal_to(
        _timeout_error("apt-get update", 1),
    )


def test_sigterm_during_a_detached_flood_exits_cleanly(
    helper_env: dict[str, str],
    helper_cmd: list[str],
    tmp_path: Path,
) -> None:
    """SIGTERM mid-stall exits 143 at once, whoever still holds the pipe."""
    pid_file = tmp_path / "detached.pid"
    env = {
        **helper_env,
        "FAKE_APT_PLAN": json.dumps([{"detach_flood": True, "stall": True}]),
        "FAKE_APT_DETACHED_PID": str(pid_file),
    }
    out: list[bytes] = []
    try:
        with subprocess.Popen(
            [*helper_cmd, "update"],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ) as proc:
            reader = threading.Thread(target=_slow_reader, args=(proc.stdout, out))
            reader.start()
            _wait_for(pid_file)
            time.sleep(0.5)
            start = time.monotonic()
            proc.send_signal(signal.SIGTERM)
            stderr = proc.stderr.read() if proc.stderr else b""
            proc.wait(timeout=SIGNAL_DEADLINE_SECONDS)
            seconds = time.monotonic() - start
            reader.join(SIGNAL_DEADLINE_SECONDS)
    finally:
        _kill_quietly(pid_file)

    text = stderr.decode("utf-8", "replace")
    assert_that(proc.returncode).is_equal_to(128 + int(signal.SIGTERM))
    assert_that(text).contains(f"interrupted by signal {int(signal.SIGTERM)}")
    for marker in CLEAN_EXIT_MARKERS:
        assert_that(text).does_not_contain(marker)
    assert_that(seconds).is_less_than(15)


def test_stream_leaves_no_thread_and_no_open_pipe(
    helper: ModuleType,
    streamer: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsysbinary: pytest.CaptureFixture[bytes],
    tmp_path: Path,
) -> None:
    """A timed-out call leaves nothing behind that could print later.

    A process outside the group keeps the pipe open past the stop; the call
    still returns at its deadline, with no thread left and the pipe closed,
    so nothing from it reaches the next attempt's output.
    """
    monkeypatch.setattr(streamer, "CHILD_GRACE_SECONDS", 0.3)
    pid_file = tmp_path / "outsider.pid"
    script = tmp_path / "outsider"
    script.write_text(
        "#!/usr/bin/env python3\n"
        "import os, sys, time\n"
        "if os.fork() == 0:\n"
        "    os.setsid()\n"
        f"    open({str(pid_file)!r}, 'w').write(str(os.getpid()))\n"
        "    while True:\n"
        "        os.write(1, b'late\\n')\n"
        "        time.sleep(0.01)\n"
        "print('started', flush=True)\n"
        "time.sleep(300)\n",
    )
    script.chmod(0o755)
    threads = threading.active_count()
    closed: list[Any] = []
    real_popen = streamer.subprocess.Popen

    def popen(*args: Any, **kwargs: Any) -> Any:
        proc = real_popen(*args, **kwargs)
        closed.append(proc)
        return proc

    monkeypatch.setattr(streamer.subprocess, "Popen", popen)
    try:
        start = time.monotonic()
        returncode, lines = helper.stream([str(script)], timeout=0.5)
        seconds = time.monotonic() - start
    finally:
        _wait_for(pid_file)
        _kill_quietly(pid_file)

    assert_that(returncode).is_equal_to(helper.EXIT_TIMED_OUT)
    assert_that(lines).contains("started")
    assert_that(seconds).is_less_than(5)
    assert_that(threading.active_count()).is_equal_to(threads)
    assert_that(closed[0].stdout.closed).is_true()
    capsysbinary.readouterr()
    time.sleep(0.2)
    assert_that(capsysbinary.readouterr().out).is_empty()


def test_undecodable_dns_warning_under_an_ascii_stdout_is_still_retried(
    helper: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """An echo that cannot encode a byte never turns a failed update into success.

    Review repro (#1571): under an ASCII stdout a DNS warning carrying an
    invalid byte made the reader die on ``UnicodeEncodeError``; ``apt-get
    update`` exits 0 there, so the run passed with no lines to classify.
    """
    count = tmp_path / "count"
    script = tmp_path / "dns-warning"
    script.write_bytes(
        b"#!/bin/sh\n"
        + f"echo x >> '{count}'\n".encode()
        + b"printf 'W: Failed to fetch http://m\\377/x  "
        + b"Temporary failure resolving \\047m\\377\\047\\n'\n"
        + b"exit 0\n",
    )
    script.chmod(0o755)
    raw = io.BytesIO()
    ascii_out = io.TextIOWrapper(raw, encoding="ascii", errors="strict")
    monkeypatch.setattr(sys, "stdout", ascii_out)
    settings = helper.Settings(attempts=3, backoff_seconds=0.0)
    session = helper.Session(runner=helper.stream, sleeper=lambda _delay: None)

    outcome = helper.run_with_retries(
        "apt-get update",
        [str(script)],
        settings,
        session,
        warnings_fail=True,
    )
    ascii_out.flush()

    assert_that(outcome.returncode).is_equal_to(0)
    assert_that(outcome.network).is_true()
    assert_that(count.read_text().splitlines()).is_length(3)
    assert_that(raw.getvalue()).contains(b"Temporary failure resolving 'm\xff'")


def test_echo_failure_keeps_capturing(
    helper: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """A stdout that fails every write still leaves every line captured."""

    class BrokenBuffer:
        """A binary stdout whose writes fail like a closed pipe."""

        def write(self, _data: bytes) -> int:
            """Fail."""
            raise BrokenPipeError(32, "Broken pipe")

        def flush(self) -> None:
            """Nothing is buffered."""

    out = SimpleNamespace(buffer=BrokenBuffer(), flush=lambda: None)
    script = tmp_path / "lines"
    script.write_text(f'#!/bin/sh\necho one\necho "{DNS_FAILURE}"\nexit 100\n')
    script.chmod(0o755)
    monkeypatch.setattr(sys, "stdout", out)

    returncode, lines = helper.stream([str(script)], timeout=30)

    monkeypatch.undo()
    assert_that(returncode).is_equal_to(100)
    assert_that(lines).is_equal_to(["one", DNS_FAILURE])
    assert_that(capsys.readouterr().err).contains("stopped echoing apt output")


def test_deadline_kills_a_term_ignoring_call_after_the_grace(
    helper: ModuleType,
    streamer: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """A call that ignores SIGTERM gets SIGKILL, grandchildren included."""
    monkeypatch.setattr(streamer, "CHILD_GRACE_SECONDS", 0.3)
    pid_file = tmp_path / "grandchild.pid"
    script = tmp_path / "stubborn"
    script.write_text(
        "#!/bin/sh\n"
        "trap '' TERM\n"
        f"sleep 300 & echo $! > '{pid_file}'\n"
        "echo started\n"
        "while :; do sleep 0.1; done\n",
    )
    script.chmod(0o755)

    start = time.monotonic()
    returncode, lines = helper.stream([str(script)], timeout=0.5)

    assert_that(returncode).is_equal_to(helper.EXIT_TIMED_OUT)
    assert_that(lines).contains("started")
    assert_that(time.monotonic() - start).is_less_than(10)
    assert_that(_gone(int(pid_file.read_text("utf-8")))).is_true()
    assert_that(streamer._CHILDREN).is_empty()  # pylint: disable=protected-access
    out = capsys.readouterr().out
    assert_that(out).contains("::warning::apt did not stop within 0.3s")
    assert_that(out).contains("0.5s deadline")


def _leaves_a_member(tmp_path: Path, pid_file: Path, body: str) -> Path:
    """Write a script that leaves a group member holding its output."""
    count = tmp_path / "count"
    script = tmp_path / "leaves-a-member"
    member = f"sleep 300 & echo $! > '{pid_file}'"
    script.write_text(f"#!/bin/sh\necho x >> '{count}'\n{member}\n{body}\n")
    script.chmod(0o755)
    return script


@pytest.mark.parametrize(
    ("body", "code"),
    [
        (f"echo '{HIT}'\nexit 0", 0),
        (f"echo '{NOT_FOUND}'\nexit 100", 100),
    ],
)
def test_leader_exit_ends_the_call_despite_a_member_holding_the_output(
    # pylint: disable=too-many-arguments,too-many-positional-arguments
    helper: ModuleType,
    streamer: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
    body: str,
    code: int,
) -> None:
    """apt's own exit code counts once it exited; no timeout, no retry.

    A process apt left in its group (a daemon a maintainer script started)
    keeps the pipe open. The call returns after the drain window with the
    leader's code, classified as usual, and the member is left running.
    """
    monkeypatch.setattr(streamer, "LEADER_DRAIN_SECONDS", 0.5)
    pid_file = tmp_path / "member.pid"
    script = _leaves_a_member(tmp_path, pid_file, body)
    settings = helper.Settings(attempts=3, backoff_seconds=0.0)
    session = helper.Session(runner=helper.stream, sleeper=lambda _delay: None)
    try:
        start = time.monotonic()
        outcome = helper.run_with_retries(
            "apt-get install",
            [str(script)],
            settings,
            session,
        )
        seconds = time.monotonic() - start
        # Left running: raises ProcessLookupError if it was stopped.
        os.kill(int(pid_file.read_text("utf-8")), 0)
    finally:
        _kill_quietly(pid_file)

    assert_that(outcome.returncode).is_equal_to(code)
    assert_that(outcome.timed_out).is_false()
    assert_that(outcome.network).is_false()
    assert_that((tmp_path / "count").read_text().splitlines()).is_length(1)
    assert_that(seconds).is_less_than(5)
    assert_that(capsys.readouterr().err).contains("still holds its output")


def test_leader_exit_returns_its_output(
    helper: ModuleType,
    streamer: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """The output the leader printed is returned with its exit code."""
    monkeypatch.setattr(streamer, "LEADER_DRAIN_SECONDS", 0.5)
    pid_file = tmp_path / "member.pid"
    script = _leaves_a_member(tmp_path, pid_file, f"echo '{NOT_FOUND}'\nexit 100")
    try:
        returncode, lines = helper.stream([str(script)], timeout=30)
    finally:
        _kill_quietly(pid_file)

    assert_that(returncode).is_equal_to(100)
    assert_that(lines).is_equal_to([NOT_FOUND])


def test_unexpected_error_stops_the_group_after_the_leader_exits(
    helper: ModuleType,
    streamer: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """On an exception the group is stopped even when the leader is gone."""
    pid_file = tmp_path / "member.pid"
    script = _leaves_a_member(tmp_path, pid_file, "exit 0")

    def read_after_exit(proc: Any, *_args: Any) -> Any:
        """Fail unexpectedly once the leader has exited and been reaped."""
        _wait_for(pid_file)
        proc.wait(timeout=10)
        raise RuntimeError("unexpected")

    monkeypatch.setattr(streamer, "_read", read_after_exit)
    try:
        with pytest.raises(RuntimeError):
            helper.stream([str(script)], timeout=30)
        assert_that(_gone(int(pid_file.read_text("utf-8")))).is_true()
    finally:
        _kill_quietly(pid_file)


def test_stream_within_the_deadline_is_unchanged(
    helper: ModuleType,
    tmp_path: Path,
) -> None:
    """A call that finishes in time keeps its exit code and output."""
    script = tmp_path / "quick"
    script.write_text("#!/bin/sh\necho one\necho two\nexit 100\n")
    script.chmod(0o755)

    returncode, lines = helper.stream([str(script)], timeout=30)

    assert_that(returncode).is_equal_to(100)
    assert_that(lines).is_equal_to(["one", "two"])


def test_timeout_is_retried_and_not_a_network_failure(helper: ModuleType) -> None:
    """A timed-out attempt is retried; recovery clears the timeout."""
    results = iter([(124, [DNS_FAILURE]), (0, [HIT])])
    delays: list[float] = []
    session = helper.Session(
        runner=lambda _argv, _timeout: next(results),
        sleeper=delays.append,
    )
    settings = helper.Settings(attempts=3, backoff_seconds=5.0)

    outcome = helper.run_with_retries("apt-get update", ["x"], settings, session)

    assert_that(outcome.returncode).is_equal_to(0)
    assert_that(outcome.timed_out).is_false()
    assert_that(delays).is_equal_to([5.0])


def test_capture_keeps_the_latest_output_past_the_cap(
    streamer: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A flood is capped; the newest lines, where apt's errors are, survive."""
    monkeypatch.setattr(streamer, "MAX_CAPTURE_BYTES", 64)
    capture = streamer._Capture()  # pylint: disable=protected-access
    for number in range(100):
        capture.add(f"line {number}\n".encode())

    lines = capture.lines()

    assert_that(lines[-1]).is_equal_to("line 99")
    assert_that(len("\n".join(lines)) + 1).is_less_than_or_equal_to(64)
    assert_that(capture.evicted).is_true()


# --- a stdout nobody reads, and floods (#1571 review) ----------------------

BULK_BYTES = 200 * 1024
FLOOD_BYTES = 25 * 1024 * 1024
BULK_STALL = {"output": HIT, "bulk": BULK_BYTES, "stall": True}


def _start_unread(
    helper_cmd: list[str],
    env: dict[str, str],
    err: Path,
) -> subprocess.Popen[bytes]:
    """Start the helper with a stdout pipe that is never read."""
    with err.open("wb") as handle:
        return subprocess.Popen(  # pylint: disable=consider-using-with
            [*helper_cmd, "update"],
            env=env,
            stdout=subprocess.PIPE,
            stderr=handle,
        )


def test_unread_stdout_cannot_stretch_the_budget(
    helper_env: dict[str, str],
    helper_cmd: list[str],
    tmp_path: Path,
) -> None:
    """A stdout nobody reads never holds a call past its deadline.

    Review repro (#1571): 200 KB of output, a 1s call deadline and a 30s
    budget, with stdout unread; the helper was still running at 33s.
    """
    env = {
        **helper_env,
        "FAKE_APT_PLAN": json.dumps([BULK_STALL]),
        "LGTM_CI_APT_CALL_TIMEOUT_SECONDS": "1",
        "LGTM_CI_APT_TOTAL_TIMEOUT_SECONDS": "30",
    }
    err = tmp_path / "stderr"
    start = time.monotonic()
    proc = _start_unread(helper_cmd, env, err)
    try:
        code = proc.wait(timeout=SIGNAL_DEADLINE_SECONDS)
    finally:
        proc.kill()
        if proc.stdout is not None:
            proc.stdout.close()
    seconds = time.monotonic() - start

    text = err.read_text("utf-8", "replace")
    assert_that(code).is_equal_to(124)
    assert_that(seconds).is_less_than(30 + 5)
    assert_that(text).contains("bytes of apt output not echoed (stdout not draining)")
    for marker in CLEAN_EXIT_MARKERS:
        assert_that(text).does_not_contain(marker)


def test_sigterm_with_an_unread_stdout_exits_at_once(
    helper_env: dict[str, str],
    helper_cmd: list[str],
    tmp_path: Path,
) -> None:
    """SIGTERM exits 143 promptly; pending echo output is dropped, not drained."""
    log = Path(helper_env["FAKE_APT_LOG"])
    env = {
        **helper_env,
        "FAKE_APT_PLAN": json.dumps([BULK_STALL]),
    }
    err = tmp_path / "stderr"
    proc = _start_unread(helper_cmd, env, err)
    try:
        _wait_for(log)
        time.sleep(1.0)
        start = time.monotonic()
        proc.send_signal(signal.SIGTERM)
        code = proc.wait(timeout=SIGNAL_DEADLINE_SECONDS)
        seconds = time.monotonic() - start
    finally:
        proc.kill()
        if proc.stdout is not None:
            proc.stdout.close()

    text = err.read_text("utf-8", "replace")
    assert_that(code).is_equal_to(128 + int(signal.SIGTERM))
    assert_that(seconds).is_less_than(5)
    assert_that(text).contains(f"interrupted by signal {int(signal.SIGTERM)}")
    for marker in CLEAN_EXIT_MARKERS:
        assert_that(text).does_not_contain(marker)


def test_early_dns_warning_survives_a_flood(run_helper: Callable[..., Result]) -> None:
    """A network signature before 25 MiB of output still fails the update.

    Review repro (#1571): the capture cap evicted the warning, and an
    ``update`` that exits 0 was classified as success.
    """
    plan = [
        {"exit": 0, "output": UPDATE_DNS_WARNING, "bulk": FLOOD_BYTES},
        {"exit": 0, "output": HIT},
    ]
    result = run_helper("update", plan=plan)

    assert_that(result.code).is_equal_to(0)
    assert_that(_verbs(result)).is_equal_to(["update", "update"])
    assert_that(result.stderr).contains("apt-get update: DNS or network failure")
    # The flood really went through (echoed, or counted as not echoed).
    echoed = result.stdout.count("bulk.example") * 1024
    pattern = r"\[apt\] (\d+) bytes of apt output"
    dropped = sum(int(n) for n in re.findall(pattern, result.stderr))
    assert_that(echoed + dropped).is_greater_than(FLOOD_BYTES * 9 // 10)


def test_signature_split_across_reads_is_found(streamer: ModuleType) -> None:
    """A signature cut in two by the pipe reads is still matched."""
    matcher = streamer._Matcher(["Temporary failure resolving"])  # pylint: disable=protected-access
    cut = UPDATE_DNS_WARNING.index("failure") + 3
    first, second = UPDATE_DNS_WARNING[:cut], UPDATE_DNS_WARNING[cut:]

    matcher.feed(b"Hit:1 x\r\n" + first.encode())
    assert_that(matcher.found).is_empty()
    matcher.feed(second.encode() + b"\nGet:2 y\n")

    assert_that(matcher.found).is_length(1)
    assert_that(matcher.found[0].decode()).contains("Temporary failure resolving")


def test_signature_in_an_endless_line_is_found(streamer: ModuleType) -> None:
    """A line longer than ``MAX_LINE_BYTES`` is matched, also across its cut."""
    matcher = streamer._Matcher(["Could not connect"])  # pylint: disable=protected-access
    filler = b"x" * (streamer.MAX_LINE_BYTES + 10)

    matcher.feed(filler + b"Could not")
    matcher.feed(b" connect" + filler)
    matcher.finish()

    assert_that(matcher.found).is_length(1)


def test_stream_finds_a_signature_split_across_writes(
    helper: ModuleType,
    tmp_path: Path,
) -> None:
    """Through a real pipe: a signature written in two pieces is classified."""
    script = tmp_path / "split"
    cut = DNS_FAILURE.index("resolving") + 4
    script.write_text(
        "#!/bin/sh\n"
        f"printf '%s' \"{DNS_FAILURE[:cut]}\"\n"
        "sleep 0.3\n"
        f"printf '%s\\n' \"{DNS_FAILURE[cut:]}\"\n"
        "exit 100\n",
    )
    script.chmod(0o755)

    returncode, lines = helper.stream([str(script)], timeout=30)

    assert_that(returncode).is_equal_to(100)
    assert_that(helper.classify(returncode, lines).network).is_true()


def test_evicted_signature_line_is_returned_first(
    helper: ModuleType,
    streamer: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """The capture keeps its cap; the evicted signature line comes back first."""
    monkeypatch.setattr(streamer, "MAX_CAPTURE_BYTES", 4096)
    script = tmp_path / "flood"
    script.write_text(
        "#!/bin/sh\n"
        f'echo "{DNS_FAILURE}"\n'
        'i=0; while [ $i -lt 1000 ]; do echo "Get:$i filler"; i=$((i+1)); done\n'
        "exit 0\n",
    )
    script.chmod(0o755)

    returncode, lines = helper.stream([str(script)], timeout=30)

    assert_that(returncode).is_equal_to(0)
    assert_that(lines[0]).is_equal_to(DNS_FAILURE)
    assert_that(lines[-1]).is_equal_to("Get:999 filler")
    assert_that(lines).does_not_contain("Get:0 filler")


# --- echo per descriptor type, cancellation, backpressure (#1571 review) ---

STREAM_DRIVER = r"""
import importlib.util, json, os, signal, sys
spec = importlib.util.spec_from_file_location("apt_helper", sys.argv[1])
helper = importlib.util.module_from_spec(spec)
sys.modules["apt_helper"] = helper
spec.loader.exec_module(helper)
streamer = sys.modules["apt_stream"]
"""

CLOSED_STDOUT_DRIVER = STREAM_DRIVER + r"""
os.close(1)
code, lines = streamer.stream(sys.argv[2:], timeout=30)
os.write(2, json.dumps({"code": code, "lines": lines}).encode() + b"\n")
"""

SIGNAL_MID_WRITE_DRIVER = STREAM_DRIVER + r"""
real_write = os.write
fired = []

def write(fd, data):
    # The signal arrives while an echo write is in progress: its handler
    # runs as soon as the write returns, inside the writing frame.
    if fd == 1 and not fired:
        fired.append(True)
        os.kill(os.getpid(), signal.SIGTERM)
    return real_write(fd, data)

os.write = write
sys.exit(helper.main(["update"]))
"""


def _read_pty(master: int, sink: list[bytes], done: threading.Event) -> None:
    """Drain a PTY master until ``done`` is set and nothing is left."""
    while True:
        ready, _, _ = select.select([master], [], [], 0.1)
        if not ready:
            if done.is_set():
                return
            continue
        try:
            chunk = os.read(master, 65536)
        except OSError:  # EIO on Linux once the slave side is closed.
            return
        if not chunk:
            return
        sink.append(chunk)


def _run_on_pty(
    helper_cmd: list[str],
    env: dict[str, str],
    err: Path,
    *,
    drained: bool,
) -> tuple[int, float, bytes]:
    """Run ``update`` with a PTY as stdout, read or never read."""
    master, slave = pty.openpty()
    out: list[bytes] = []
    done = threading.Event()
    reader = threading.Thread(target=_read_pty, args=(master, out, done))
    try:
        with err.open("wb") as handle:
            start = time.monotonic()
            proc = subprocess.Popen(  # pylint: disable=consider-using-with
                [*helper_cmd, "update"],
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=slave,
                stderr=handle,
            )
        os.close(slave)
        slave = -1
        if drained:
            reader.start()
        try:
            code = proc.wait(timeout=SIGNAL_DEADLINE_SECONDS)
        finally:
            proc.kill()
        seconds = time.monotonic() - start
    finally:
        done.set()
        if reader.is_alive():
            reader.join(SIGNAL_DEADLINE_SECONDS)
        if slave >= 0:
            os.close(slave)
        os.close(master)
    return code, seconds, b"".join(out)


def test_unread_tty_stdout_cannot_stretch_the_deadline(
    helper_env: dict[str, str],
    helper_cmd: list[str],
    tmp_path: Path,
) -> None:
    """A terminal nobody reads never holds a call past its deadline.

    Review repro (#1571): 200 KB of output into a PTY whose master was not
    read kept a 1s call blocked in ``os.write`` for over 4s; a write of
    ``PIPE_BUF`` bytes only never blocks on a pipe.
    """
    env = {
        **helper_env,
        "FAKE_APT_PLAN": json.dumps([BULK_STALL]),
        "LGTM_CI_APT_CALL_TIMEOUT_SECONDS": "1",
        "LGTM_CI_APT_ATTEMPTS": "1",
    }
    err = tmp_path / "stderr"

    code, seconds, _ = _run_on_pty(helper_cmd, env, err, drained=False)

    text = err.read_text("utf-8", "replace")
    assert_that(code).is_equal_to(124)
    # 1s deadline, the fake stops at once, at most one 2s wait for a line.
    assert_that(seconds).is_less_than(1 + 5)
    for marker in CLEAN_EXIT_MARKERS:
        assert_that(text).does_not_contain(marker)


def test_drained_tty_stdout_gets_all_the_output(
    helper_env: dict[str, str],
    helper_cmd: list[str],
    tmp_path: Path,
) -> None:
    """Through a private non-blocking descriptor, a read terminal gets it all."""
    env = {
        **helper_env,
        "FAKE_APT_PLAN": json.dumps([{"output": HIT, "bulk": BULK_BYTES}]),
    }
    err = tmp_path / "stderr"

    code, _, out = _run_on_pty(helper_cmd, env, err, drained=True)

    text = out.decode("utf-8", "replace")
    assert_that(code).is_equal_to(0)
    assert_that(text).contains(HIT)
    assert_that(text.count("bulk.example")).is_equal_to(BULK_BYTES // 1024)
    assert_that(err.read_text("utf-8")).does_not_contain("not echoed")


def test_out_never_changes_the_flags_of_a_shared_tty(streamer: ModuleType) -> None:
    """The caller's terminal stays blocking; the helper writes a copy."""
    master, slave = pty.openpty()
    try:
        with os.fdopen(os.dup(slave), "w", encoding="utf-8") as stream:
            out = streamer._Out(stream)  # pylint: disable=protected-access
            modes = streamer._Mode  # pylint: disable=protected-access
            try:
                assert_that(out.mode).is_equal_to(modes.NONBLOCK)
                assert_that(out.fd).is_not_equal_to(stream.fileno())
                assert_that(os.get_blocking(stream.fileno())).is_true()
                assert_that(os.get_blocking(slave)).is_true()
            finally:
                out.close()
    finally:
        os.close(slave)
        os.close(master)


def test_socket_stdout_is_never_written_in_a_blocking_way(
    streamer: ModuleType,
) -> None:
    """A socket is reopened privately where possible, else not echoed to."""
    left, right = socket.socketpair()
    try:
        with right.makefile("w", encoding="utf-8") as stream:
            out = streamer._Out(stream)  # pylint: disable=protected-access
            try:
                assert_that(out.mode).is_in(
                    streamer._Mode.NONBLOCK,  # pylint: disable=protected-access
                    streamer._Mode.OFF,  # pylint: disable=protected-access
                )
                if out.mode is streamer._Mode.OFF:  # pylint: disable=protected-access
                    assert_that(out.reason).contains("without blocking")
                assert_that(right.getblocking()).is_true()
            finally:
                out.close()
    finally:
        left.close()
        right.close()


def test_signal_during_an_echo_write_exits_128_plus_n(
    helper_env: dict[str, str],
    project_root: Path,
) -> None:
    """A signal mid-write unwinds to 143; cleanup never masks it.

    Review repro (#1571): SIGTERM during a blocked write left a memoryview
    of the echo buffer in the traceback; resizing the buffer in cleanup
    raised ``BufferError`` instead of exiting 143.
    """
    env = {**helper_env, "FAKE_APT_PLAN": json.dumps([BULK_STALL])}
    proc = subprocess.run(
        [
            sys.executable,
            "-I",
            "-c",
            SIGNAL_MID_WRITE_DRIVER,
            str(project_root / SCRIPT_PATH),
        ],
        capture_output=True,
        env=env,
        timeout=SIGNAL_DEADLINE_SECONDS,
        check=False,
    )

    text = proc.stderr.decode("utf-8", "replace")
    assert_that(proc.returncode).is_equal_to(128 + int(signal.SIGTERM))
    assert_that(text).contains(f"interrupted by signal {int(signal.SIGTERM)}")
    assert_that(text).does_not_contain("BufferError")
    for marker in CLEAN_EXIT_MARKERS:
        assert_that(text).does_not_contain(marker)


def test_cleanup_after_an_exception_mid_write_keeps_the_exception(
    helper: ModuleType,
    streamer: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """An exception raised inside an echo write is the one that propagates.

    The output ends mid-line, so cleanup would have to add a newline: with
    a view of the buffer still held by the traceback, resizing it in place
    raised ``BufferError`` over the ``Interrupted``.
    """
    read_fd, write_fd = os.pipe()
    stream = os.fdopen(write_fd, "w", encoding="utf-8")
    real_write = os.write
    fired: list[bool] = []

    def write(fd: int, data: bytes) -> int:
        if fd == write_fd and not fired:
            fired.append(True)
            raise streamer.Interrupted(int(signal.SIGTERM))
        return real_write(fd, data)

    script = tmp_path / "lines"
    script.write_text("#!/bin/sh\nprintf 'one\\ntwo'\nexit 0\n")
    script.chmod(0o755)
    monkeypatch.setattr(sys, "stdout", stream)
    monkeypatch.setattr(streamer.os, "write", write)
    try:
        with pytest.raises(streamer.Interrupted):
            helper.stream([str(script)], timeout=30)
    finally:
        monkeypatch.undo()
        stream.close()
        os.close(read_fd)


def test_closed_stdout_does_not_stop_the_call(
    project_root: Path,
    tmp_path: Path,
) -> None:
    """With fd 1 closed, Popen reuses it for the pipe; apt still runs.

    Review repro (#1571): registering stdout raised ``KeyError: '1 (FD 1)
    is already registered'`` and stopped the call.
    """
    script = tmp_path / "lines"
    script.write_text(f'#!/bin/sh\necho one\necho "{DNS_FAILURE}"\nexit 100\n')
    script.chmod(0o755)
    proc = subprocess.run(
        [
            sys.executable,
            "-I",
            "-c",
            CLOSED_STDOUT_DRIVER,
            str(project_root / SCRIPT_PATH),
            str(script),
        ],
        capture_output=True,
        text=True,
        timeout=SIGNAL_DEADLINE_SECONDS,
        check=False,
    )

    assert_that(proc.returncode).described_as(proc.stderr).is_equal_to(0)
    result = json.loads(proc.stderr.strip().splitlines()[-1])
    assert_that(result).is_equal_to({"code": 100, "lines": ["one", DNS_FAILURE]})
    assert_that(proc.stderr).contains("[apt] not echoing apt output: stdout")
    assert_that(proc.stderr).does_not_contain("Traceback")


def _steady_reader(stream: Any, sink: list[bytes]) -> None:
    """Drain a pipe steadily but slower than a flood is written."""
    while chunk := stream.read1(16384):
        sink.append(chunk)
        time.sleep(0.002)


FLOOD_ECHO_BYTES = 10 * 1024 * 1024


def test_flood_into_a_draining_stdout_is_echoed_whole(
    helper_env: dict[str, str],
    helper_cmd: list[str],
) -> None:
    """A stdout slower than apt but still draining loses nothing.

    Review repro (#1571): reads of 64 KiB against writes of ``PIPE_BUF``
    (512 bytes on macOS) filled the echo buffer and dropped output although
    stdout was read. Reading apt's output now waits for stdout instead.
    """
    env = {
        **helper_env,
        "FAKE_APT_PLAN": json.dumps([{"output": HIT, "bulk": FLOOD_ECHO_BYTES}]),
    }
    out: list[bytes] = []
    with subprocess.Popen(
        [*helper_cmd, "update"],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ) as proc:
        reader = threading.Thread(target=_steady_reader, args=(proc.stdout, out))
        reader.start()
        stderr = proc.stderr.read() if proc.stderr else b""
        proc.wait(timeout=SIGNAL_DEADLINE_SECONDS)
        reader.join(SIGNAL_DEADLINE_SECONDS)

    stdout = b"".join(out)
    assert_that(proc.returncode).is_equal_to(0)
    assert_that(stdout.count(b"bulk.example")).is_equal_to(FLOOD_ECHO_BYTES // 1024)
    assert_that(stderr.decode("utf-8", "replace")).does_not_contain("not echoed")


def test_flood_into_an_unread_stdout_still_meets_the_deadline(
    helper_env: dict[str, str],
    helper_cmd: list[str],
    tmp_path: Path,
) -> None:
    """Waiting for stdout stops once it stalls; the deadline always counts."""
    env = {
        **helper_env,
        "FAKE_APT_PLAN": json.dumps(
            [{"output": HIT, "bulk": FLOOD_ECHO_BYTES, "stall": True}],
        ),
        "LGTM_CI_APT_CALL_TIMEOUT_SECONDS": "4",
        "LGTM_CI_APT_ATTEMPTS": "1",
    }
    err = tmp_path / "stderr"
    start = time.monotonic()
    proc = _start_unread(helper_cmd, env, err)
    try:
        code = proc.wait(timeout=SIGNAL_DEADLINE_SECONDS)
    finally:
        proc.kill()
        if proc.stdout is not None:
            proc.stdout.close()
    seconds = time.monotonic() - start

    text = err.read_text("utf-8", "replace")
    assert_that(code).is_equal_to(124)
    assert_that(seconds).is_less_than(4 + 5)
    assert_that(text).contains("bytes of apt output not echoed (stdout not draining)")


def test_echo_pauses_only_while_stdout_drains(
    streamer: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Above the high-water mark reading pauses, until stdout stalls."""
    read_fd, write_fd = os.pipe()
    stream = os.fdopen(write_fd, "w", encoding="utf-8")
    clock = [100.0]
    monkeypatch.setattr(sys, "stdout", stream)
    monkeypatch.setattr(streamer.time, "monotonic", lambda: clock[0])
    try:
        echo = streamer._Echo()  # pylint: disable=protected-access
        echo.add(b"x" * streamer.ECHO_HIGH_BYTES)
        assert_that(echo.paused).is_true()
        clock[0] += streamer.ECHO_STALL_SECONDS + 1
        assert_that(echo.paused).is_false()
        monkeypatch.undo()
        echo.abort()
    finally:
        monkeypatch.undo()
        stream.close()
        os.close(read_fd)


def test_echo_turns_lone_carriage_returns_into_newlines(
    streamer: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """dpkg's ``\\r`` progress lines echo as lines, also split across reads."""
    raw = io.BytesIO()
    monkeypatch.setattr(sys, "stdout", SimpleNamespace(buffer=raw, flush=lambda: None))
    echo = streamer._Echo()  # pylint: disable=protected-access
    for chunk in (b"50%\r", b"\n60%\r", b"70%\rdone\r\n", b"x\r", b"\r", b"y\n"):
        echo.add(chunk)
    echo.finish(0.0)

    assert_that(raw.getvalue()).is_equal_to(b"50%\n60%\n70%\ndone\nx\n\ny\n")


def test_echo_keeps_a_blank_line_after_a_split_crlf(
    streamer: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A ``\\r\\n`` split across reads swallows only its own ``\\n``."""
    raw = io.BytesIO()
    monkeypatch.setattr(sys, "stdout", SimpleNamespace(buffer=raw, flush=lambda: None))
    echo = streamer._Echo()  # pylint: disable=protected-access
    for chunk in (b"a\r", b"\n", b"\nb\r"):
        echo.add(chunk)
    echo.finish(0.0)

    assert_that(raw.getvalue()).is_equal_to(b"a\n\nb\n")


def test_carriage_returns_leave_the_capture_unchanged(
    helper: ModuleType,
    capsysbinary: pytest.CaptureFixture[bytes],
    tmp_path: Path,
) -> None:
    """Only the echo translates ``\\r``; the lines are classified as before."""
    script = tmp_path / "progress"
    script.write_text("#!/bin/sh\nprintf 'a\\rb\\r\\nc\\n'\n")
    script.chmod(0o755)

    returncode, lines = helper.stream([str(script)], timeout=30)

    assert_that(returncode).is_equal_to(0)
    assert_that(lines).is_equal_to(["a", "b", "c"])
    assert_that(capsysbinary.readouterr().out).is_equal_to(b"a\nb\nc\n")
