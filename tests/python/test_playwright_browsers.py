# SPDX-License-Identifier: MIT
"""Tests for ``playwright_browsers.py`` and ``playwright_ldd.py`` (#1433).

Both live in ``scripts/ci/lib``.

The browser install skips the download on an exact cache hit and runs apt only
when ``ldd`` reports a missing library. These tests pin the cache key
composition (nothing unknown may produce a key) and the probe's fail-safe
paths (every doubt is "install").

Fixtures in ``tests/fixtures/playwright-browsers``: ``ldd`` output with every
library resolved, with two missing, and for a static file; an ``os-release``
of Ubuntu 24.04.
"""

from __future__ import annotations

import subprocess
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/lib/playwright_browsers.py"
LDD_PATH = "scripts/ci/lib/playwright_ldd.py"
ELF = b"\x7fELF\x02\x01\x01\x00"
Runner = Callable[
    [Sequence[str], Mapping[str, str]],
    subprocess.CompletedProcess[str],
]
INEXACT = ["", "unknown", "^1.56.0", "1.56", "latest", "1.56.1 extra"]
UNKNOWN_PLATFORM = [(None, "x64"), ("linux-ubuntu24.04", None)]
UBUNTU = "linux-ubuntu24.04"
SHELL_AND_FIREFOX = ["chromium_headless_shell", "firefox"]
FIREFOX_KEY = "playwright-browsers-linux-ubuntu24.04-x64-1.56.1-full-firefox"


@pytest.fixture(name="pwb")
def fixture_pwb(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load playwright_browsers.py without running it."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="ldd_mod")
def fixture_ldd_mod(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load playwright_ldd.py without running it."""
    return load_script(LDD_PATH)


def _ldd_output(fixtures_dir: Path, name: str) -> str:
    """Return one checked-in ldd output."""
    return (fixtures_dir / "playwright-browsers" / name).read_text("utf-8")


def _browser(root: Path, name: str, *, complete: bool = True, elf: bool = True) -> Path:
    """Create a fake browser install ``root/name``: an executable and a library."""
    path = root / name
    (path / "lib").mkdir(parents=True)
    (path / "chrome").write_bytes(ELF if elf else b"#!/bin/sh\n")
    (path / "lib" / "libbundled.so").write_bytes(ELF if elf else b"text")
    (path / "README").write_text("not an ELF file", "utf-8")
    if complete:
        (path / "INSTALLATION_COMPLETE").write_text("", "utf-8")
    return path


def _runner(
    stdout: str,
    returncode: int = 0,
) -> tuple[Runner, list[tuple[list[str], dict[str, str]]]]:
    """Return a fake ldd runner and the list it records its calls in."""
    calls: list[tuple[list[str], dict[str, str]]] = []

    def run(
        argv: Sequence[str],
        env: Mapping[str, str],
    ) -> subprocess.CompletedProcess[str]:
        """Record the call and answer with the canned output."""
        calls.append((list(argv), dict(env)))
        return subprocess.CompletedProcess(list(argv), returncode, stdout, "")

    return run, calls


def _incomplete_chromium(root: Path) -> Path:
    """Create a chromium install without the completion marker."""
    return _browser(root, "chromium-1200", complete=False)


def _chromium_without_elf(root: Path) -> Path:
    """Create a complete chromium install that holds no ELF file."""
    return _browser(root, "chromium-1200", elf=False)


# cache key


@pytest.mark.parametrize(
    ("version", "browsers", "mode", "expected"),
    [
        (
            "1.56.1",
            "chromium",
            "full",
            "playwright-browsers-linux-ubuntu24.04-x64-1.56.1-full-chromium",
        ),
        (
            "1.57.0",
            "webkit chromium,firefox chromium",
            "headless-shell",
            "playwright-browsers-linux-ubuntu24.04-x64-1.57.0-headless-shell-"
            "chromium-firefox-webkit",
        ),
        (
            "1.58.0-beta-1700000000000",
            "all",
            "full",
            "playwright-browsers-linux-ubuntu24.04-x64-1.58.0-beta-1700000000000-full-"
            "chromium-firefox-webkit",
        ),
    ],
)
def test_cache_key_carries_os_arch_version_mode_and_browsers(
    pwb: ModuleType,
    version: str,
    browsers: str,
    mode: str,
    expected: str,
) -> None:
    """The key names everything that changes which browser builds are cached."""
    key = pwb.cache_key(
        version=version,
        browsers=browsers,
        mode=mode,
        os_part="linux-ubuntu24.04",
        arch_part="x64",
    )

    assert_that(key).is_equal_to(expected)


@pytest.mark.parametrize("version", INEXACT)
def test_cache_key_is_empty_without_an_exact_version(
    pwb: ModuleType,
    version: str,
) -> None:
    """A range or unresolved version must never key the cache."""
    key = pwb.cache_key(
        version=version,
        browsers="chromium",
        mode="full",
        os_part="linux-ubuntu24.04",
        arch_part="x64",
    )

    assert_that(key).is_empty()


@pytest.mark.parametrize(("os_part", "arch_part"), UNKNOWN_PLATFORM)
def test_cache_key_is_empty_for_an_unknown_os_or_arch(
    pwb: ModuleType,
    os_part: str | None,
    arch_part: str | None,
) -> None:
    """An unknown OS release or architecture skips the cache instead of sharing it."""
    key = pwb.cache_key(
        version="1.56.1",
        browsers="chromium",
        mode="full",
        os_part=os_part,
        arch_part=arch_part,
    )

    assert_that(key).is_empty()


def test_cache_keys_differ_across_versions_and_modes(pwb: ModuleType) -> None:
    """Two versions or two modes never share a key (no restore-keys prefix either)."""
    keys = {
        pwb.cache_key(
            version=v,
            browsers="chromium",
            mode=m,
            os_part=UBUNTU,
            arch_part="x64",
        )
        for v in ("1.56.0", "1.56.1")
        for m in ("full", "headless-shell")
    }

    assert_that(keys).is_length(4)


def test_os_fragment_reads_the_linux_release(
    pwb: ModuleType,
    fixtures_dir: Path,
) -> None:
    """Linux keys carry the distribution and release from os-release."""
    release = fixtures_dir / "playwright-browsers" / "os-release-ubuntu-24.04"

    assert_that(pwb.os_fragment("Linux", release, "")).is_equal_to("linux-ubuntu24.04")


def test_os_fragment_is_none_without_os_release(
    pwb: ModuleType,
    tmp_path: Path,
) -> None:
    """A Linux runner with no readable os-release has no key."""
    assert_that(pwb.os_fragment("Linux", tmp_path / "missing", "")).is_none()


@pytest.mark.parametrize(
    ("system", "mac", "expected"),
    [
        ("macOS", "15.3.1", "macos-15"),
        ("macOS", "", None),
        ("Windows", "", "windows"),
        ("FreeBSD", "", None),
    ],
)
def test_os_fragment_off_linux(
    pwb: ModuleType,
    tmp_path: Path,
    system: str,
    mac: str,
    expected: str | None,
) -> None:
    """macOS keys carry the major release; unknown systems have no key."""
    assert_that(pwb.os_fragment(system, tmp_path / "none", mac)).is_equal_to(expected)


@pytest.mark.parametrize(
    ("env", "machine", "expected"),
    [
        ({"RUNNER_ARCH": "X64"}, "aarch64", "x64"),
        ({"RUNNER_ARCH": "ARM64"}, "x86_64", "arm64"),
        ({}, "x86_64", "x64"),
        ({}, "aarch64", "arm64"),
        ({}, "riscv64", None),
    ],
)
def test_arch_fragment(
    pwb: ModuleType, env: dict[str, str], machine: str, expected: str | None
) -> None:
    """RUNNER_ARCH wins; an unknown machine has no key."""
    assert_that(pwb.arch_fragment(env, machine)).is_equal_to(expected)


# browsers path


@pytest.mark.parametrize(
    ("env", "system", "expected"),
    [
        ({}, "Linux", "/home/u/.cache/ms-playwright"),
        ({"XDG_CACHE_HOME": "/xdg"}, "Linux", "/xdg/ms-playwright"),
        ({}, "macOS", "/home/u/Library/Caches/ms-playwright"),
        ({"LOCALAPPDATA": "/local"}, "Windows", "/local/ms-playwright"),
        ({"PLAYWRIGHT_BROWSERS_PATH": "/custom"}, "Linux", "/custom"),
    ],
)
def test_browsers_path(
    pwb: ModuleType,
    env: dict[str, str],
    system: str,
    expected: str,
) -> None:
    """The path follows Playwright's own resolution."""
    path = pwb.browsers_path(env, system, Path("/home/u"))

    assert_that(str(path)).is_equal_to(expected)


def test_browsers_path_inside_node_modules_is_not_cached(pwb: ModuleType) -> None:
    """PLAYWRIGHT_BROWSERS_PATH=0 keeps browsers in node_modules: no path."""
    env = {"PLAYWRIGHT_BROWSERS_PATH": "0"}

    assert_that(pwb.browsers_path(env, "Linux", Path("/h"))).is_none()


# presence


@pytest.mark.parametrize(
    ("names", "mode", "expected"),
    [
        (["chromium"], "full", ["chromium"]),
        (["chromium", "firefox"], "headless-shell", SHELL_AND_FIREFOX),
        (["webkit"], "headless-shell", ["webkit"]),
        (["chrome"], "full", None),
    ],
)
def test_dir_prefixes(
    pwb: ModuleType, names: list[str], mode: str, expected: list[str] | None
) -> None:
    """Browser names map to Playwright's directory prefixes; channels are unknown."""
    assert_that(pwb.dir_prefixes(names, mode)).is_equal_to(expected)


def test_present_needs_a_complete_install_of_every_browser(
    pwb: ModuleType,
    tmp_path: Path,
) -> None:
    """A browser counts only with Playwright's INSTALLATION_COMPLETE marker."""
    _browser(tmp_path, "chromium-1200")
    _browser(tmp_path, "firefox-1500", complete=False)

    assert_that(pwb.present(tmp_path, ["chromium"])).is_true()
    assert_that(pwb.present(tmp_path, ["chromium", "firefox"])).is_false()


def test_present_does_not_mistake_the_headless_shell_for_chromium(
    pwb: ModuleType, tmp_path: Path
) -> None:
    """``chromium-*`` does not match ``chromium_headless_shell-*``."""
    _browser(tmp_path, "chromium_headless_shell-1200")

    assert_that(pwb.present(tmp_path, ["chromium"])).is_false()
    assert_that(pwb.present(tmp_path, ["chromium_headless_shell"])).is_true()


@pytest.mark.parametrize("prefixes", [None, []])
def test_present_is_false_for_unknown_browsers(
    pwb: ModuleType,
    tmp_path: Path,
    prefixes: list[str] | None,
) -> None:
    """An unknown browser name is never reported present."""
    assert_that(pwb.present(tmp_path, prefixes)).is_false()


def test_present_is_false_without_a_browsers_path(pwb: ModuleType) -> None:
    """No browsers path (node_modules install) is never reported present."""
    assert_that(pwb.present(None, ["chromium"])).is_false()


# ldd probe


def test_probe_reports_nothing_when_every_library_resolves(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
) -> None:
    """Every ELF file is checked with the browser's own lib dirs on LD_LIBRARY_PATH."""
    browser = _browser(tmp_path, "chromium-1200")
    run, calls = _runner(_ldd_output(fixtures_dir, "ldd-resolved.txt"))

    missing = pwb.probe(
        root=tmp_path,
        prefixes=["chromium"],
        env={"LD_LIBRARY_PATH": "/opt/x"},
        which=lambda _: "/usr/bin/ldd",
        run=run,
    )

    assert_that(missing).is_empty()
    assert_that([argv[1] for argv, _ in calls]).is_equal_to(
        [str(browser / "chrome"), str(browser / "lib" / "libbundled.so")],
    )
    expected = f"{browser}:{browser / 'lib'}:/opt/x"
    assert_that(calls[0][1]["LD_LIBRARY_PATH"]).is_equal_to(expected)


def test_probe_lists_the_missing_libraries(
    pwb: ModuleType, tmp_path: Path, fixtures_dir: Path
) -> None:
    """``=> not found`` lines are the missing libraries, de-duplicated and sorted."""
    _browser(tmp_path, "chromium-1200")
    run, _ = _runner(_ldd_output(fixtures_dir, "ldd-missing.txt"))

    missing = pwb.probe(
        root=tmp_path, prefixes=["chromium"], env={}, which=lambda _: "ldd", run=run
    )

    assert_that(missing).is_equal_to(["libatk-1.0.so.0", "libnss3.so"])


def test_probe_accepts_a_static_file(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
) -> None:
    """ldd's non-zero exit for a static file is not a doubt."""
    _browser(tmp_path, "chromium-1200")
    run, _ = _runner(_ldd_output(fixtures_dir, "ldd-static.txt"), returncode=1)

    missing = pwb.probe(
        root=tmp_path, prefixes=["chromium"], env={}, which=lambda _: "ldd", run=run
    )

    assert_that(missing).is_empty()


def test_probe_fails_safe_without_ldd(pwb: ModuleType, tmp_path: Path) -> None:
    """No ldd on PATH: undecidable, so the caller installs."""
    _browser(tmp_path, "chromium-1200")

    assert_that(pwb.probe).raises(pwb.Undecidable).when_called_with(
        root=tmp_path,
        prefixes=["chromium"],
        env={},
        which=lambda _: None,
    ).contains("ldd is not on PATH")


@pytest.mark.parametrize(
    ("make", "prefixes", "message"),
    [
        (lambda root: None, ["chromium"], "no complete chromium install"),
        (_incomplete_chromium, ["chromium"], "no complete"),
        (_chromium_without_elf, ["chromium"], "no ELF file"),
        (lambda root: _browser(root, "chromium-1200"), None, "unknown browser"),
    ],
)
def test_probe_fails_safe_when_it_cannot_see_the_browser(
    pwb: ModuleType,
    tmp_path: Path,
    make: Callable[[Path], object],
    prefixes: list[str] | None,
    message: str,
) -> None:
    """A missing, incomplete or empty install, or an unknown browser, is undecidable."""
    make(tmp_path)
    run, _ = _runner("")

    assert_that(pwb.probe).raises(pwb.Undecidable).when_called_with(
        root=tmp_path,
        prefixes=prefixes,
        env={},
        which=lambda _: "ldd",
        run=run,
    ).contains(message)


def test_probe_fails_safe_when_ldd_fails(pwb: ModuleType, tmp_path: Path) -> None:
    """An ldd error other than "not a dynamic executable" is undecidable."""
    _browser(tmp_path, "chromium-1200")
    run, _ = _runner("ldd: error while loading", returncode=127)

    assert_that(pwb.probe).raises(pwb.Undecidable).when_called_with(
        root=tmp_path,
        prefixes=["chromium"],
        env={},
        which=lambda _: "ldd",
        run=run,
    ).contains("exited 127")


def test_probe_fails_safe_when_ldd_hangs(pwb: ModuleType, tmp_path: Path) -> None:
    """A timed-out ldd call is undecidable."""
    _browser(tmp_path, "chromium-1200")

    def hang(
        argv: Sequence[str],
        env: Mapping[str, str],
    ) -> subprocess.CompletedProcess[str]:
        """Behave like an ldd call that ran into its timeout."""
        raise subprocess.TimeoutExpired(cmd=list(argv), timeout=30)

    assert_that(pwb.probe).raises(pwb.Undecidable).when_called_with(
        root=tmp_path,
        prefixes=["chromium"],
        env={},
        which=lambda _: "ldd",
        run=hang,
    ).contains("timed out")


def test_run_ldd_passes_the_environment_and_a_timeout(ldd_mod: ModuleType) -> None:
    """The real runner hands its environment to the child."""
    result = ldd_mod.run_ldd(["/usr/bin/env"], {"PROBE_MARKER": "on"})

    assert_that(result.stdout).contains("PROBE_MARKER=on")
    assert_that(ldd_mod.LDD_TIMEOUT_SECONDS).is_equal_to(30)


# command line


def _main(
    pwb: ModuleType,
    argv: list[str],
    monkeypatch: pytest.MonkeyPatch,
    env: dict[str, str],
) -> int:
    """Run main() with only ``env`` as the relevant environment."""
    for name in (
        "PLAYWRIGHT_BROWSERS_PATH",
        "RUNNER_OS",
        "RUNNER_ARCH",
        "OS_RELEASE_FILE",
        "XDG_CACHE_HOME",
    ):
        monkeypatch.delenv(name, raising=False)
    for name, value in env.items():
        monkeypatch.setenv(name, value)
    return int(pwb.main(argv))


def test_main_cache_key_and_path(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``cache-key`` and ``cache-path`` print one line each."""
    release = fixtures_dir / "playwright-browsers" / "os-release-ubuntu-24.04"
    env = {
        "RUNNER_OS": "Linux",
        "RUNNER_ARCH": "X64",
        "OS_RELEASE_FILE": str(release),
        "PLAYWRIGHT_BROWSERS_PATH": str(tmp_path),
    }

    argv = ["cache-key", "--version", "1.56.1", "--browsers", "firefox"]
    assert_that(_main(pwb, argv, monkeypatch, env)).is_zero()
    assert_that(_main(pwb, ["cache-path"], monkeypatch, env)).is_zero()

    assert_that(capsys.readouterr().out.splitlines()).is_equal_to(
        [FIREFOX_KEY, str(tmp_path)],
    )


def test_main_cache_key_explains_an_empty_key(
    pwb: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """An inexact version prints an empty key and says why on stderr."""
    windows = {"RUNNER_OS": "Windows"}
    code = _main(pwb, ["cache-key", "--version", "unknown"], monkeypatch, windows)

    captured = capsys.readouterr()
    assert_that(code).is_zero()
    assert_that(captured.out).is_equal_to("\n")
    assert_that(captured.err).contains("no exact cache key")


def test_main_cache_path_is_empty_for_node_modules(
    pwb: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """PLAYWRIGHT_BROWSERS_PATH=0 prints an empty path, so nothing is cached."""
    _main(pwb, ["cache-path"], monkeypatch, {"PLAYWRIGHT_BROWSERS_PATH": "0"})

    assert_that(capsys.readouterr().out).is_equal_to("\n")


def test_main_present(
    pwb: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """``present`` exits 0 only when every browser is complete."""
    _browser(tmp_path, "chromium_headless_shell-1200")
    env = {"PLAYWRIGHT_BROWSERS_PATH": str(tmp_path)}

    shell = ["present", "--browsers", "chromium", "--mode", "headless-shell"]
    assert_that(_main(pwb, shell, monkeypatch, env)).is_zero()
    code = _main(pwb, ["present", "--browsers", "chromium"], monkeypatch, env)
    assert_that(code).is_equal_to(1)


def test_main_probe_exit_codes(
    pwb: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``probe`` exits 3 (install) when it cannot decide, and says why."""
    env = {"PLAYWRIGHT_BROWSERS_PATH": str(tmp_path)}

    code = _main(pwb, ["probe", "--browsers", "firefox"], monkeypatch, env)

    assert_that(code).is_equal_to(3)
    assert_that(capsys.readouterr().err).contains("probe undecided")


def test_main_probe_prints_missing_libraries(
    pwb: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``probe`` exits 1 and prints the libraries ldd could not find."""
    _browser(tmp_path, "chromium-1200")
    monkeypatch.setattr(pwb, "probe", lambda **_: ["libnss3.so"])

    env = {"PLAYWRIGHT_BROWSERS_PATH": str(tmp_path)}
    code = _main(pwb, ["probe"], monkeypatch, env)

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().out).is_equal_to("libnss3.so\n")


def test_main_rejects_an_unknown_mode(pwb: ModuleType) -> None:
    """An install mode outside full/headless-shell is a usage error."""
    assert_that(pwb.main).raises(SystemExit).when_called_with(
        ["present", "--mode", "shell-only"],
    ).is_equal_to("2")


def test_missing_libraries_stops_at_its_budget(
    ldd_mod: ModuleType,
    tmp_path: Path,
) -> None:
    """No ldd call starts after LDD_BUDGET_SECONDS: the probe is undecidable instead."""
    browser = _browser(tmp_path, "chromium-1200")
    run, calls = _runner("")
    ticks = iter([0.0, 1.0, ldd_mod.LDD_BUDGET_SECONDS + 1.0])

    assert_that(ldd_mod.missing_libraries).raises(ldd_mod.Undecidable).when_called_with(
        [browser],
        ldd="ldd",
        env={},
        run=run,
        clock=lambda: next(ticks),
    ).contains("budget")
    assert_that(calls).is_length(1)
