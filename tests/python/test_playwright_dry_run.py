# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/lib/playwright_dry_run.py`` (#1433).

The browser cache counts as complete, and the ldd probe trusts its artifact
list, only when ``playwright install --dry-run`` output is read in full. These
tests pin both released header formats against real output and the
all-or-nothing rule: one unrecognised record, orphan location, stray line or
foreign directory makes the whole list unknown ("not present", "cannot
decide"), so a recognised block can never stand in for one that was not.

Fixtures: real ``install --dry-run`` stdout of Playwright 1.56.1 (the 1.57 and
older format) and 1.60.0, 1.61.0 and 1.63.0 (the 1.58+ format) in
``tests/fixtures/playwright-browsers`` (provenance in its README; ``@ROOT@`` is
filled in with a temporary directory).
"""

from __future__ import annotations

import io
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/lib/playwright_browsers.py"
DRY_RUN_PATH = "scripts/ci/lib/playwright_dry_run.py"
# Playwright 1.61.0, full chromium: the browser, FFmpeg, the headless shell.
CHROMIUM = "install-dry-run-1.61.0-chromium.txt"


@pytest.fixture(name="pwb")
def fixture_pwb(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load playwright_browsers.py without running it."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="dry")
def fixture_dry(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load playwright_dry_run.py without running it."""
    return load_script(DRY_RUN_PATH)


def _browser(root: Path, name: str) -> Path:
    """Create a complete (marked) artifact directory ``root/name``."""
    path = root / name
    path.mkdir(parents=True)
    (path / "INSTALLATION_COMPLETE").write_text("", "utf-8")
    return path


def _dry_run(fixtures_dir: Path, name: str, root: Path) -> str:
    """Return one checked-in install dry run with its root filled in."""
    text = (fixtures_dir / "playwright-browsers" / name).read_text("utf-8")
    return text.replace("@ROOT@", str(root))


def _chromium_cache(root: Path) -> None:
    """Create the three complete artifacts of a full 1.61.0 chromium install."""
    for name in ("chromium-1228", "chromium_headless_shell-1228", "ffmpeg-1011"):
        _browser(root, name)


def _main(
    pwb: ModuleType,
    argv: list[str],
    monkeypatch: pytest.MonkeyPatch,
    env: dict[str, str],
) -> int:
    """Run main() with only ``env`` as the relevant environment."""
    for name in ("PLAYWRIGHT_BROWSERS_PATH", "RUNNER_OS", "XDG_CACHE_HOME", "INIT_CWD"):
        monkeypatch.delenv(name, raising=False)
    for name, value in env.items():
        monkeypatch.setenv(name, value)
    return int(pwb.main(argv))


def test_install_locations_list_every_artifact(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
) -> None:
    """Full chromium installs the browser, its headless shell and FFmpeg."""
    text = _dry_run(fixtures_dir, CHROMIUM, tmp_path)

    locations = pwb.install_locations(text)

    assert_that(locations).is_equal_to(
        [
            ("chromium", tmp_path / "chromium-1228"),
            ("ffmpeg", tmp_path / "ffmpeg-1011"),
            ("chromium-headless-shell", tmp_path / "chromium_headless_shell-1228"),
        ],
    )


@pytest.mark.parametrize(
    "text",
    [
        "",
        "Error: Cannot find module 'playwright-core'\n",
        "browser: chromium version 141.0\n",
        "browser: chromium\nbrowser: firefox\n  Install location:    /x/firefox-1\n",
        "browser: firefox\n  Install location:    relative/firefox-1495\n",
    ],
)
def test_install_locations_are_none_when_unrecognised(
    pwb: ModuleType,
    text: str,
) -> None:
    """Empty, foreign, incomplete or relative output is not trusted."""
    assert_that(pwb.install_locations(text)).is_none()


def test_install_locations_refuse_a_system_channel(
    pwb: ModuleType,
    fixtures_dir: Path,
) -> None:
    """A channel such as chrome installs outside the cache: never present."""
    name = "install-dry-run-1.61.0-chrome-channel.txt"
    text = _dry_run(fixtures_dir, name, Path("/x"))

    assert_that(pwb.install_locations(text)).is_none()


# Every released dry-run format, all or nothing (second review of #1433)

# Each real fixture with the artifacts it lists, repeats folded.
FIXTURE_ARTIFACTS = {
    "1.56.1-chromium": [
        ("chromium", "chromium-1194"),
        ("ffmpeg", "ffmpeg-1011"),
        ("chromium-headless-shell", "chromium_headless_shell-1194"),
    ],
    "1.56.1-only-shell-chromium": [
        ("chromium-headless-shell", "chromium_headless_shell-1194"),
        ("ffmpeg", "ffmpeg-1011"),
    ],
    "1.56.1-webkit": [("webkit", "webkit-2215")],
    "1.60.0-chromium": [
        ("chromium", "chromium-1223"),
        ("ffmpeg", "ffmpeg-1011"),
        ("chromium-headless-shell", "chromium_headless_shell-1223"),
    ],
    "1.60.0-only-shell-chromium": [
        ("chromium-headless-shell", "chromium_headless_shell-1223"),
        ("ffmpeg", "ffmpeg-1011"),
    ],
    "1.60.0-webkit": [("webkit", "webkit-2287"), ("ffmpeg", "ffmpeg-1011")],
    "1.61.0-chromium": [
        ("chromium", "chromium-1228"),
        ("ffmpeg", "ffmpeg-1011"),
        ("chromium-headless-shell", "chromium_headless_shell-1228"),
    ],
    "1.61.0-only-shell-chromium": [
        ("chromium-headless-shell", "chromium_headless_shell-1228"),
        ("ffmpeg", "ffmpeg-1011"),
    ],
    "1.61.0-webkit": [("webkit", "webkit-2311"), ("ffmpeg", "ffmpeg-1011")],
    "1.63.0-chromium": [
        ("chromium", "chromium-1243"),
        ("ffmpeg", "ffmpeg-1011"),
        ("chromium-headless-shell", "chromium_headless_shell-1243"),
    ],
    "1.63.0-only-shell-chromium": [
        ("chromium-headless-shell", "chromium_headless_shell-1243"),
        ("ffmpeg", "ffmpeg-1011"),
    ],
    "1.63.0-webkit": [("webkit", "webkit-2359"), ("ffmpeg", "ffmpeg-1011")],
}
MODERN_HEADER = "Chrome for Testing 149.0 (playwright chromium v1228)\n"
LOCATION = "  Install location:    @ROOT@"
MODERN_CHROMIUM = (
    "Chrome for Testing 149.0.7827.55 (playwright chromium v1228)\n"
    "  Install location:    @ROOT@/chromium-1228\n"
)
LEGACY_HEADER = "browser: chromium version 141.0.7390.37\n"
LEGACY_CHROMIUM = LEGACY_HEADER + LOCATION + "/chromium-1194\n"


def _fill(text: str, root: Path) -> str:
    """Fill the @ROOT@ placeholder of an inline dry run."""
    return text.replace("@ROOT@", str(root))


@pytest.mark.parametrize("case", sorted(FIXTURE_ARTIFACTS))
def test_every_released_format_lists_every_artifact(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
    case: str,
) -> None:
    """Real 1.56.1 (legacy) and 1.60/1.61/1.63 (1.58+) output parses in full."""
    text = _dry_run(fixtures_dir, f"install-dry-run-{case}.txt", tmp_path)
    artifacts = FIXTURE_ARTIFACTS[case]
    expected = [(name, tmp_path / directory) for name, directory in artifacts]

    locations = pwb.install_locations(text, tmp_path)

    assert_that(locations).is_equal_to(expected)


@pytest.mark.parametrize("case", sorted(FIXTURE_ARTIFACTS))
def test_every_released_format_is_present_only_when_complete(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
    case: str,
) -> None:
    """A complete cache is present under every format; one missing artifact is not."""
    text = _dry_run(fixtures_dir, f"install-dry-run-{case}.txt", tmp_path)
    directories = [directory for _, directory in FIXTURE_ARTIFACTS[case]]
    for directory in directories[1:]:
        _browser(tmp_path, directory)

    assert_that(pwb.present(pwb.install_locations(text, tmp_path))).is_false()
    _browser(tmp_path, directories[0])
    assert_that(pwb.present(pwb.install_locations(text, tmp_path))).is_true()


@pytest.mark.parametrize("version", ["1.56.1", "1.61.0"])
def test_a_channel_is_never_recognised(
    pwb: ModuleType,
    fixtures_dir: Path,
    version: str,
) -> None:
    """``chrome`` prints ``<system>`` (and ``vundefined`` from 1.58): unknown."""
    name = f"install-dry-run-{version}-chrome-channel.txt"

    text = _dry_run(fixtures_dir, name, Path("/x"))

    assert_that(pwb.install_locations(text)).is_none()


def test_a_recognised_block_then_an_unrecognised_one_is_unknown(
    pwb: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A known chromium block never stands in for an unrecognised WebKit block.

    Without all-or-nothing parsing, chromium alone would satisfy presence and
    the probe would never see WebKit, skipping its dlopen safeguard.
    """
    _browser(tmp_path, "chromium-1228")
    _browser(tmp_path, "webkit-2311")
    text = _fill(
        MODERN_CHROMIUM
        + "\nWebKit 26.5 [playwright webkit r2311]\n"
        + "  Install location:    @ROOT@/webkit-2311\n",
        tmp_path,
    )
    env = {"PLAYWRIGHT_BROWSERS_PATH": str(tmp_path)}

    assert_that(pwb.install_locations(text, tmp_path)).is_none()
    monkeypatch.setattr("sys.stdin", io.StringIO(text))
    assert_that(_main(pwb, ["present"], monkeypatch, env)).is_equal_to(1)
    monkeypatch.setattr("sys.stdin", io.StringIO(text))
    assert_that(_main(pwb, ["probe"], monkeypatch, env)).is_equal_to(3)
    assert_that(capsys.readouterr().err).contains("probe undecided")


def test_both_formats_in_one_output_are_both_read(
    pwb: ModuleType,
    tmp_path: Path,
) -> None:
    """A legacy block and a 1.58+ block are both records; neither is dropped."""
    text = _fill(
        LEGACY_CHROMIUM
        + "\nWebKit 26.5 (playwright webkit v2311)\n"
        + "  Install location:    @ROOT@/webkit-2311\n",
        tmp_path,
    )

    assert_that(pwb.install_locations(text, tmp_path)).is_equal_to(
        [
            ("chromium", tmp_path / "chromium-1194"),
            ("webkit", tmp_path / "webkit-2311"),
        ],
    )


@pytest.mark.parametrize(
    ("text", "reason"),
    [
        (MODERN_CHROMIUM + LOCATION + "/chromium-1228\n", "no record"),
        ("  Install location:    @ROOT@/chromium-1228\n", "no record"),
        (MODERN_CHROMIUM + "\n" + LOCATION + "/ffmpeg-1011\n", "no record"),
        (
            MODERN_HEADER + "\n" + MODERN_CHROMIUM,
            "no install location",
        ),
        (
            MODERN_CHROMIUM + "\nFFmpeg (playwright ffmpeg v1011)\n",
            "no install location",
        ),
        (MODERN_CHROMIUM + "Removing unused browsers\n", "unrecognised line"),
        (
            "Chrome for Testing 149.0 (playwright chromium v1228)\n"
            "  Download url:        https://example.invalid/x.zip\n",
            "unrecognised line",
        ),
        (
            "Firefox 151.0 (playwright firefox v1532)\n"
            "  Install location:    @ROOT@/chromium-1532\n",
            "unexpected install directory",
        ),
        (
            "Chrome for Testing 149.0 (playwright chromium v1228)\n"
            "  Install location:    @ROOT@/chromium-1227\n",
            "unexpected install directory",
        ),
        ("", "no artifact"),
    ],
)
def test_malformed_output_is_rejected_whole(
    dry: ModuleType,
    tmp_path: Path,
    text: str,
    reason: str,
) -> None:
    """Orphan, doubled or missing locations, stray lines, foreign names: all fail."""
    assert_that(dry.parse).raises(dry.Unrecognised).when_called_with(
        _fill(text, tmp_path),
    ).contains(reason)


def test_a_host_override_directory_is_accepted(pwb: ModuleType) -> None:
    """``<name>_<host>_special-<revision>`` is Playwright's override layout."""
    text = (
        "WebKit (playwright webkit v2092)\n"
        "  Install location:    /c/webkit_ubuntu20.04_x64_special-2092\n"
    )

    assert_that(pwb.install_locations(text, Path("/c"))).is_equal_to(
        [("webkit", Path("/c/webkit_ubuntu20.04_x64_special-2092"))],
    )


def test_artifacts_outside_the_browser_directory_are_unknown(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
) -> None:
    """Every location must sit directly in the directory the cache saves."""
    text = _dry_run(fixtures_dir, CHROMIUM, tmp_path / "elsewhere")

    assert_that(pwb.install_locations(text, tmp_path)).is_none()
    assert_that(pwb.install_locations(text, tmp_path / "elsewhere")).is_not_none()


def test_main_without_a_browser_directory_is_never_present(
    pwb: ModuleType,
    tmp_path: Path,
    fixtures_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """PLAYWRIGHT_BROWSERS_PATH=0 (browsers in node_modules) is never a cache hit."""
    _chromium_cache(tmp_path)
    text = _dry_run(fixtures_dir, CHROMIUM, tmp_path)
    monkeypatch.setattr("sys.stdin", io.StringIO(text))

    code = _main(pwb, ["present"], monkeypatch, {"PLAYWRIGHT_BROWSERS_PATH": "0"})

    assert_that(code).is_equal_to(1)
