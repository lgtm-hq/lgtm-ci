# SPDX-License-Identifier: MIT
"""Tests for ``playwright_browsers.py`` and ``playwright_ldd.py`` (#1433).

Both live in ``scripts/ci/lib``.

The browser install skips the download on an exact cache hit and runs apt only
when ``ldd`` reports a missing library. These tests pin the cache key
composition (nothing unknown may produce a key), the path resolution, presence
(every artifact the dry run lists, exact revisions) and the probe's fail-safe
paths (every doubt is "install").

Fixtures in ``tests/fixtures/playwright-browsers``: ``ldd`` output with every
library resolved, with two missing, and for a static file; an ``os-release``
of Ubuntu 24.04; real ``install --dry-run`` stdout of Playwright 1.56.1
(the 1.57-and-older header format), 1.60.0, 1.61.0 and 1.63.0 (the 1.58+
format) for full chromium, ``--only-shell chromium``, webkit and a chrome
channel (provenance in the fixture directory's README; ``@ROOT@`` is filled in).
"""

from __future__ import annotations

import io
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
FIREFOX_KEY = "playwright-browsers-linux-ubuntu24.04-x64-1.56.1-full-firefox"
# Playwright 1.61.0, full chromium: the browser, FFmpeg, the headless shell.
CHROMIUM = "install-dry-run-1.61.0-chromium.txt"


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
    path = pwb.browsers_path(env, system, Path("/home/u"), Path("/work"))

    assert_that(str(path)).is_equal_to(expected)


@pytest.mark.parametrize(
    ("env", "expected"),
    [
        ({"PLAYWRIGHT_BROWSERS_PATH": ".pw-browsers"}, "/repo/web/.pw-browsers"),
        ({"PLAYWRIGHT_BROWSERS_PATH": "../pw"}, "/repo/pw"),
        ({"PLAYWRIGHT_BROWSERS_PATH": "pw", "INIT_CWD": "/init"}, "/init/pw"),
        ({"XDG_CACHE_HOME": "cache"}, "/repo/web/cache/ms-playwright"),
    ],
)
def test_browsers_path_resolves_relative_paths_like_playwright(
    pwb: ModuleType,
    env: dict[str, str],
    expected: str,
) -> None:
    """A relative result resolves against INIT_CWD, else the working directory."""
    path = pwb.browsers_path(env, "Linux", Path("/home/u"), Path("/repo/web"))

    assert_that(str(path)).is_equal_to(expected)


def test_browsers_path_inside_node_modules_is_not_cached(pwb: ModuleType) -> None:
    """PLAYWRIGHT_BROWSERS_PATH=0 keeps browsers in node_modules: no path."""
    env = {"PLAYWRIGHT_BROWSERS_PATH": "0"}

    assert_that(pwb.browsers_path(env, "Linux", Path("/h"), Path("/w"))).is_none()


# dry-run fixtures


def _dry_run(fixtures_dir: Path, name: str, root: Path) -> str:
    """Return one checked-in install dry run with its root filled in."""
    text = (fixtures_dir / "playwright-browsers" / name).read_text("utf-8")
    return text.replace("@ROOT@", str(root))


# presence


def _chromium_cache(root: Path, *, skip: str = "") -> None:
    """Create the three complete artifacts of a full chromium install."""
    for name in ("chromium-1228", "chromium_headless_shell-1228", "ffmpeg-1011"):
        if name != skip:
            _browser(root, name)


def test_present_with_every_artifact(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
) -> None:
    """Every listed artifact complete: the download may be skipped."""
    _chromium_cache(tmp_path)
    text = _dry_run(fixtures_dir, CHROMIUM, tmp_path)

    assert_that(pwb.present(pwb.install_locations(text))).is_true()


@pytest.mark.parametrize(
    "skip",
    ["chromium_headless_shell-1228", "ffmpeg-1011", "chromium-1228"],
)
def test_present_needs_the_headless_shell_and_ffmpeg(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
    skip: str,
) -> None:
    """A full chromium cache without its shell or FFmpeg is not present."""
    _chromium_cache(tmp_path, skip=skip)
    text = _dry_run(fixtures_dir, CHROMIUM, tmp_path)

    assert_that(pwb.present(pwb.install_locations(text))).is_false()


def test_present_ignores_a_stale_revision(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
) -> None:
    """Another revision of the same browser does not stand in for the expected one."""
    _chromium_cache(tmp_path, skip="chromium-1228")
    _browser(tmp_path, "chromium-1187")
    text = _dry_run(fixtures_dir, CHROMIUM, tmp_path)

    assert_that(pwb.present(pwb.install_locations(text))).is_false()


def test_present_needs_the_completion_marker(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
) -> None:
    """An artifact without INSTALLATION_COMPLETE is an interrupted install."""
    _chromium_cache(tmp_path, skip="ffmpeg-1011")
    _browser(tmp_path, "ffmpeg-1011", complete=False)
    text = _dry_run(fixtures_dir, CHROMIUM, tmp_path)

    assert_that(pwb.present(pwb.install_locations(text))).is_false()


@pytest.mark.parametrize("locations", [None, []])
def test_present_is_false_when_unknown(
    pwb: ModuleType,
    locations: list[tuple[str, Path]] | None,
) -> None:
    """No recognised dry run is never reported present."""
    assert_that(pwb.present(locations)).is_false()


# ldd probe


def _chromium_locations(
    pwb: ModuleType,
    root: Path,
    fixtures_dir: Path,
) -> list[tuple[str, Path]]:
    """Create a complete chromium cache and return its dry-run locations."""
    _chromium_cache(root)
    text = _dry_run(fixtures_dir, CHROMIUM, root)
    return list(pwb.install_locations(text))


def test_probe_reports_nothing_when_every_library_resolves(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
) -> None:
    """Every ELF file of every artifact is checked with its own lib dirs first."""
    locations = _chromium_locations(pwb, tmp_path, fixtures_dir)
    run, calls = _runner(_ldd_output(fixtures_dir, "ldd-resolved.txt"))

    missing = pwb.probe(
        locations=locations,
        env={"LD_LIBRARY_PATH": "/opt/x"},
        which=lambda _: "/usr/bin/ldd",
        run=run,
    )

    assert_that(missing).is_empty()
    shell = tmp_path / "chromium_headless_shell-1228"
    assert_that([argv[1] for argv, _ in calls]).contains(
        str(shell / "chrome"),
        str(tmp_path / "ffmpeg-1011" / "lib" / "libbundled.so"),
    )
    assert_that(calls).is_length(6)
    ffmpeg = tmp_path / "ffmpeg-1011"
    expected = f"{ffmpeg}:{ffmpeg / 'lib'}:/opt/x"
    assert_that(calls[2][1]["LD_LIBRARY_PATH"]).is_equal_to(expected)


def test_probe_lists_the_missing_libraries(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
) -> None:
    """``=> not found`` lines are the missing libraries, de-duplicated and sorted."""
    locations = _chromium_locations(pwb, tmp_path, fixtures_dir)
    run, _ = _runner(_ldd_output(fixtures_dir, "ldd-missing.txt"))

    missing = pwb.probe(locations=locations, env={}, which=lambda _: "ldd", run=run)

    assert_that(missing).is_equal_to(["libatk-1.0.so.0", "libnss3.so"])


def test_probe_accepts_a_static_file(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
) -> None:
    """ldd's non-zero exit for a static file is not a doubt."""
    locations = _chromium_locations(pwb, tmp_path, fixtures_dir)
    run, _ = _runner(_ldd_output(fixtures_dir, "ldd-static.txt"), returncode=1)

    missing = pwb.probe(locations=locations, env={}, which=lambda _: "ldd", run=run)

    assert_that(missing).is_empty()


def test_probe_never_vouches_for_webkit(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
) -> None:
    """WebKit dlopens libraries ldd cannot see: undecidable, even when ldd passes."""
    _browser(tmp_path, "webkit-2311")
    text = _dry_run(fixtures_dir, "install-dry-run-1.61.0-webkit.txt", tmp_path)
    run, calls = _runner(_ldd_output(fixtures_dir, "ldd-resolved.txt"))

    assert_that(pwb.probe).raises(pwb.Undecidable).when_called_with(
        locations=pwb.install_locations(text),
        env={},
        which=lambda _: "ldd",
        run=run,
    ).contains("webkit loads system libraries with dlopen")
    assert_that(calls).is_empty()


def test_probe_fails_safe_without_ldd(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
) -> None:
    """No ldd on PATH: undecidable, so the caller installs."""
    locations = _chromium_locations(pwb, tmp_path, fixtures_dir)

    assert_that(pwb.probe).raises(pwb.Undecidable).when_called_with(
        locations=locations,
        env={},
        which=lambda _: None,
    ).contains("ldd is not on PATH")


@pytest.mark.parametrize("skip", ["chromium_headless_shell-1228", "ffmpeg-1011"])
def test_probe_fails_safe_when_an_artifact_is_missing(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
    skip: str,
) -> None:
    """A listed artifact that is not installed completely is undecidable."""
    _chromium_cache(tmp_path, skip=skip)
    text = _dry_run(fixtures_dir, CHROMIUM, tmp_path)
    run, _ = _runner("")

    assert_that(pwb.probe).raises(pwb.Undecidable).when_called_with(
        locations=pwb.install_locations(text),
        env={},
        which=lambda _: "ldd",
        run=run,
    ).contains("not every listed artifact")


@pytest.mark.parametrize("locations", [None, []])
def test_probe_fails_safe_without_locations(
    pwb: ModuleType,
    locations: list[tuple[str, Path]] | None,
) -> None:
    """An unrecognised dry run is undecidable."""
    assert_that(pwb.probe).raises(pwb.Undecidable).when_called_with(
        locations=locations,
        env={},
    ).contains("listed no artifact")


def test_probe_fails_safe_without_elf_files(pwb: ModuleType, tmp_path: Path) -> None:
    """A complete install that holds no ELF file is undecidable."""
    path = _chromium_without_elf(tmp_path)
    run, _ = _runner("")

    assert_that(pwb.probe).raises(pwb.Undecidable).when_called_with(
        locations=[("chromium", path)],
        env={},
        which=lambda _: "ldd",
        run=run,
    ).contains("no ELF file")


def test_probe_fails_safe_when_ldd_fails(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
) -> None:
    """An ldd error other than "not a dynamic executable" is undecidable."""
    locations = _chromium_locations(pwb, tmp_path, fixtures_dir)
    run, _ = _runner("ldd: error while loading", returncode=127)

    assert_that(pwb.probe).raises(pwb.Undecidable).when_called_with(
        locations=locations,
        env={},
        which=lambda _: "ldd",
        run=run,
    ).contains("exited 127")


def test_probe_fails_safe_when_ldd_hangs(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
) -> None:
    """A timed-out ldd call is undecidable."""
    locations = _chromium_locations(pwb, tmp_path, fixtures_dir)

    def hang(
        argv: Sequence[str],
        env: Mapping[str, str],
    ) -> subprocess.CompletedProcess[str]:
        """Behave like an ldd call that ran into its timeout."""
        raise subprocess.TimeoutExpired(cmd=list(argv), timeout=30)

    assert_that(pwb.probe).raises(pwb.Undecidable).when_called_with(
        locations=locations,
        env={},
        which=lambda _: "ldd",
        run=hang,
    ).contains("timed out")


def test_probe_passes_its_budget_down(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The caller's budget reaches missing_libraries."""
    locations = _chromium_locations(pwb, tmp_path, fixtures_dir)
    seen: dict[str, object] = {}

    def record(_dirs: Sequence[Path], **kwargs: object) -> list[str]:
        """Record the budget missing_libraries was given."""
        seen["budget"] = kwargs["budget"]
        return []

    monkeypatch.setattr(pwb, "missing_libraries", record)

    pwb.probe(locations=locations, env={}, budget=12.0, which=lambda _: "ldd")

    assert_that(seen).is_equal_to({"budget": pwb.Budget(seconds=12.0)})


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


def test_main_cache_path_resolves_in_the_working_directory(
    pwb: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A relative PLAYWRIGHT_BROWSERS_PATH prints absolute, under the cwd."""
    web = tmp_path / "web"
    web.mkdir()
    monkeypatch.chdir(web)
    monkeypatch.delenv("INIT_CWD", raising=False)

    _main(pwb, ["cache-path"], monkeypatch, {"PLAYWRIGHT_BROWSERS_PATH": ".pw"})

    assert_that(capsys.readouterr().out).is_equal_to(f"{web.resolve() / '.pw'}\n")


def test_main_present(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """``present`` reads the dry run on stdin; 0 only with every artifact complete."""
    text = _dry_run(fixtures_dir, CHROMIUM, tmp_path)
    monkeypatch.setattr("sys.stdin", io.StringIO(text))
    _chromium_cache(tmp_path, skip="ffmpeg-1011")
    env = {"PLAYWRIGHT_BROWSERS_PATH": str(tmp_path)}

    assert_that(_main(pwb, ["present"], monkeypatch, env)).is_equal_to(1)

    _browser(tmp_path, "ffmpeg-1011")
    monkeypatch.setattr("sys.stdin", io.StringIO(text))
    assert_that(_main(pwb, ["present"], monkeypatch, env)).is_zero()


def test_main_probe_exit_codes(
    pwb: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``probe`` exits 3 (install) when it cannot decide, and says why."""
    monkeypatch.setattr("sys.stdin", io.StringIO("not a dry run\n"))

    code = _main(pwb, ["probe"], monkeypatch, {})

    assert_that(code).is_equal_to(3)
    assert_that(capsys.readouterr().err).contains("probe undecided")


def test_main_probe_prints_missing_libraries(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """``probe`` exits 1, prints what ldd could not find, and passes its budget."""
    seen: dict[str, object] = {}

    def fake(**kwargs: object) -> list[str]:
        """Record the probe arguments and report one missing library."""
        seen.update(kwargs)
        return ["libnss3.so"]

    monkeypatch.setattr(pwb, "probe", fake)
    text = _dry_run(fixtures_dir, CHROMIUM, tmp_path)
    monkeypatch.setattr("sys.stdin", io.StringIO(text))

    env = {"PLAYWRIGHT_BROWSERS_PATH": str(tmp_path)}
    code = _main(pwb, ["probe", "--budget-seconds", "20"], monkeypatch, env)

    assert_that(code).is_equal_to(1)
    assert_that(capsys.readouterr().out).is_equal_to("libnss3.so\n")
    assert_that(seen).contains_entry({"budget": 20.0})


def test_main_rejects_an_unknown_mode(pwb: ModuleType) -> None:
    """An install mode outside full/headless-shell is a usage error."""
    assert_that(pwb.main).raises(SystemExit).when_called_with(
        ["cache-key", "--version", "1.56.1", "--mode", "shell-only"],
    ).is_equal_to("2")


def test_missing_libraries_stops_at_its_budget(
    ldd_mod: ModuleType,
    tmp_path: Path,
) -> None:
    """No ldd call starts after LDD_BUDGET_SECONDS: the probe is undecidable instead."""
    browser = _browser(tmp_path, "chromium-1200")
    run, calls = _runner("")

    def clock() -> float:
        """Stay in budget through the walk and the first ldd call, then expire."""
        return ldd_mod.LDD_BUDGET_SECONDS + 2.0 if calls else 1.0

    assert_that(ldd_mod.missing_libraries).raises(ldd_mod.Undecidable).when_called_with(
        [browser],
        ldd="ldd",
        env={},
        run=run,
        budget=ldd_mod.Budget(clock=clock),
    ).contains("budget")
    assert_that(calls).is_length(1)


def test_missing_libraries_takes_a_lower_budget_only(
    ldd_mod: ModuleType,
    tmp_path: Path,
) -> None:
    """A caller's budget lowers the limit; it never raises it past the default."""
    browser = _browser(tmp_path, "chromium-1200")
    run, calls = _runner("")
    ticks = iter([0.0, 6.0])

    assert_that(ldd_mod.missing_libraries).raises(ldd_mod.Undecidable).when_called_with(
        [browser],
        ldd="ldd",
        env={},
        run=run,
        budget=ldd_mod.Budget(seconds=5, clock=lambda: next(ticks)),
    ).contains("ran past its 5s budget")
    assert_that(calls).is_empty()
    ticks = iter([0.0, 61.0])
    assert_that(ldd_mod.missing_libraries).raises(ldd_mod.Undecidable).when_called_with(
        [browser],
        ldd="ldd",
        env={},
        run=run,
        budget=ldd_mod.Budget(seconds=500, clock=lambda: next(ticks)),
    ).contains("ran past its 60s budget")


def test_the_file_walk_stops_at_the_deadline(
    ldd_mod: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The deadline is checked per file during the walk, before any read."""
    browser = _browser(tmp_path, "chromium-1228")
    run, calls = _runner("")
    read: list[Path] = []
    real = ldd_mod._is_elf  # pylint: disable=protected-access

    def recording(path: Path) -> bool:
        """Record each file the walk reads."""
        read.append(path)
        return bool(real(path))

    monkeypatch.setattr(ldd_mod, "_is_elf", recording)
    ticks = iter([0.0, 1.0, 61.0])

    assert_that(ldd_mod.missing_libraries).raises(ldd_mod.Undecidable).when_called_with(
        [browser],
        ldd="ldd",
        env={},
        run=run,
        budget=ldd_mod.Budget(clock=lambda: next(ticks)),
    ).contains("ran past its 60s budget")
    assert_that(read).is_length(1)
    assert_that(calls).is_empty()
