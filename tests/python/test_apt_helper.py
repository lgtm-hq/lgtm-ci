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
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
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


def test_unrecovered_update_classifies_the_install_failure(
    run_helper: Callable[..., Result],
) -> None:
    """The terminal update attempt still failed on DNS: the lists are stale."""
    plan = [{"exit": 0, "output": UPDATE_DNS_WARNING}] * 3
    plan.append({"exit": 100, "output": NOT_FOUND})
    result = run_helper("install", "musl-tools", plan=plan)

    assert_that(result.code).is_equal_to(100)
    assert_that(_verbs(result)).is_equal_to(["update", "update", "update", "install"])
    assert_that(result.errors()).is_equal_to([EXPECTED_ERROR])


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
    helper: ModuleType,
    script: str,
    ready: Path,
) -> int | None:
    """Run ``_on_signal`` against a session-leader shell running ``script``.

    Returns:
        The leader's status right after the handler.
    """
    previous = {sig: signal.getsignal(sig) for sig in helper.HANDLED_SIGNALS}
    with subprocess.Popen(
        ["/bin/sh", "-c", script],
        start_new_session=True,
        text=True,
    ) as child:
        helper._CHILDREN.append(child)  # pylint: disable=protected-access
        try:
            _wait_for(ready)
            with pytest.raises(helper.Interrupted):
                on_signal = helper._on_signal  # pylint: disable=protected-access
                on_signal(signal.SIGTERM, None)
            status = child.poll()
        finally:
            # macOS reports EPERM for a group of zombies.
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(child.pid, signal.SIGKILL)
            helper._CHILDREN.clear()  # pylint: disable=protected-access
            for sig, handler in previous.items():
                signal.signal(sig, handler)
    return status


def test_signal_handler_kills_a_leader_that_ignores_the_signal(
    helper: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """After the grace period the group gets SIGKILL, with a dpkg-lock warning."""
    monkeypatch.setattr(helper, "CHILD_GRACE_SECONDS", 0.3)
    ready = tmp_path / "ready"
    script = f"trap '' TERM; touch '{ready}'; while :; do sleep 1; done"

    status = _handle_signal_with(helper, script, ready)

    assert_that(status).is_equal_to(-signal.SIGKILL)
    out = capsys.readouterr().out
    assert_that(out).contains("::warning::apt did not stop within 0.3s")
    assert_that(out).contains("holding the dpkg lock")


def test_signal_handler_kills_a_grandchild_after_the_leader_exits(
    helper: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """The leader dies on SIGTERM; a TERM-ignoring grandchild still gets SIGKILL."""
    monkeypatch.setattr(helper, "CHILD_GRACE_SECONDS", 0.3)
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

    status = _handle_signal_with(helper, script, ready)

    assert_that(status).is_equal_to(-signal.SIGTERM)
    assert_that(_gone(int(pid_file.read_text("utf-8")))).is_true()
    assert_that(capsys.readouterr().out).contains("::warning::apt did not stop")


def test_signal_handler_does_not_warn_when_the_group_stops(
    helper: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """A group that exits on the forwarded signal is not escalated."""
    monkeypatch.setattr(helper, "CHILD_GRACE_SECONDS", 5)
    ready = tmp_path / "ready"
    script = f"touch '{ready}'; while :; do sleep 0.1; done"

    status = _handle_signal_with(helper, script, ready)

    assert_that(status).is_equal_to(-signal.SIGTERM)
    assert_that(capsys.readouterr().out).does_not_contain("::warning::")


RACE_DRIVER = r"""
import importlib.util, json, os, signal, subprocess, sys
spec = importlib.util.spec_from_file_location("apt_helper", sys.argv[1])
helper = importlib.util.module_from_spec(spec)
sys.modules["apt_helper"] = helper
spec.loader.exec_module(helper)
started = []

class Racing(subprocess.Popen):
    # Deliver SIGTERM right after the child exists, before stream() can
    # register it: the boundary the signal mask protects.
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        started.append(self)
        os.kill(os.getpid(), signal.SIGTERM)

helper.subprocess.Popen = Racing
for sig in helper.HANDLED_SIGNALS:
    signal.signal(sig, helper._on_signal)
try:
    helper.stream(["sleep", "30"])
    outcome = "not interrupted"
except helper.Interrupted as error:
    outcome = f"interrupted {error.signum}"
child = started[0]
alive = child.poll() is None
if alive:
    os.killpg(child.pid, signal.SIGKILL)
print(json.dumps({"outcome": outcome, "alive": alive,
                  "returncode": child.returncode, "registered": len(helper._CHILDREN)}))
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
        runner=lambda _argv: (100, [DNS_FAILURE]),
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

    def runner(argv: list[str]) -> tuple[int, list[str]]:
        calls.append(list(argv))
        if "update" in argv:
            return 0, [UPDATE_DNS_WARNING]
        return 128 + 9, []

    settings = helper.load_settings(helper_env)
    session = helper.Session(runner=runner, sleeper=lambda _delay: None)

    code = helper.cmd_install(settings, ["curl"], session)

    assert_that(code).is_equal_to(128 + 9)
    assert_that(capsys.readouterr().out).does_not_contain(EXPECTED_ERROR)
