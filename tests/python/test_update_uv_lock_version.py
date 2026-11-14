# SPDX-License-Identifier: MIT
"""uv.lock own-package rewrite for the release version PR (#1545).

``python.sh`` no longer runs ``uv lock`` in the token-holding job; it calls
``update-uv-lock-version.py``, which must pick the project's own entry by
source identity and fail closed on anything ambiguous. These tests run here,
not only in bats, because the shell-tests job has no tomlkit: the bats
copies skip there, while the ``test`` extra installs it for this suite.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path
from typing import Any

import pytest
from assertpy import assert_that

PROJECT_ROOT = Path(__file__).resolve().parents[2]
ECOSYSTEMS = PROJECT_ROOT / "scripts" / "ci" / "release" / "ecosystems"
UPDATE = ECOSYSTEMS / "update-uv-lock-version.py"
READ = ECOSYSTEMS / "read-uv-lock-version.py"
HOSTILE = PROJECT_ROOT / "tests" / "fixtures" / "release" / "hostile-caller"

SINGLE_LOCAL = """\
version = 1
revision = 3
requires-python = ">=3.11"

[[package]]
name = "demo"
version = "1.0.0"
source = { editable = "." }
dependencies = [
    { name = "requests" },
]

[package.metadata]
requires-dist = [{ name = "requests", specifier = ">=2" }]

[[package]]
name = "requests"
version = "2.32.3"
source = { registry = "https://pypi.org/simple" }
"""

# A workspace whose root app takes `demo` from the member on most platforms
# and from PyPI on Windows. uv keeps two `demo` entries and pins every
# reference to them by version and source.
PLATFORM_SOURCES = """\
version = 1
revision = 3
requires-python = ">=3.11"
resolution-markers = [
    "sys_platform == 'win32'",
    "sys_platform != 'win32'",
]

[manifest]
members = [
    "app",
    "demo",
]

[[package]]
name = "app"
version = "0.1.0"
source = { virtual = "." }
dependencies = [
    { name = "demo", version = "0.9.0", source = { registry = "https://pypi.org/simple" }, marker = "sys_platform == 'win32'" },
    { name = "demo", version = "1.0.0", source = { editable = "packages/demo" }, marker = "sys_platform != 'win32'" },
]

[package.optional-dependencies]
extra = [
    { name = "demo", version = "1.0.0", source = { editable = "packages/demo" }, marker = "sys_platform != 'win32'" },
]

[[package]]
name = "demo"
version = "0.9.0"
source = { registry = "https://pypi.org/simple" }
resolution-markers = [
    "sys_platform == 'win32'",
]
sdist = { url = "https://files.pythonhosted.org/demo-0.9.0.tar.gz", hash = "sha256:00", size = 1 }

[[package]]
name = "demo"
version = "1.0.0"
source = { editable = "packages/demo" }
resolution-markers = [
    "sys_platform != 'win32'",
]
"""  # noqa: E501 - uv writes each dependency table on one line


def run_update(
    lock: Path,
    *extra: str,
    name: str = "demo",
    version: str = "2.0.0",
) -> subprocess.CompletedProcess[str]:
    """Run update-uv-lock-version.py on ``lock``."""
    return subprocess.run(
        [sys.executable, str(UPDATE), str(lock), name, version, *extra],
        capture_output=True,
        text=True,
        check=False,
    )


def write_lock(tmp_path: Path, content: str) -> Path:
    """Write ``content`` as ``tmp_path/uv.lock`` and return its path."""
    lock = tmp_path / "uv.lock"
    lock.write_text(content, encoding="utf-8")
    return lock


def load(lock: Path) -> dict[str, Any]:
    """Parse ``lock`` with tomllib."""
    with lock.open("rb") as handle:
        return tomllib.load(handle)


def versions(lock: Path, name: str = "demo") -> dict[str, str]:
    """Map each ``name`` entry's source (as a string) to its version."""
    entries = [p for p in load(lock)["package"] if p["name"] == name]
    return {str(p.get("source")): p["version"] for p in entries}


def test_single_local_entry_is_updated_and_nothing_else(tmp_path: Path) -> None:
    """A single local entry is bumped and nothing else changes."""
    lock = write_lock(tmp_path, SINGLE_LOCAL)
    result = run_update(lock)
    assert_that(result.returncode).described_as(result.stderr).is_equal_to(0)
    expected = SINGLE_LOCAL.replace(
        'name = "demo"\nversion = "1.0.0"',
        'name = "demo"\nversion = "2.0.0"',
    )
    assert_that(lock.read_text(encoding="utf-8")).is_equal_to(expected)


def test_virtual_root_entry_is_updated(tmp_path: Path) -> None:
    """A virtual workspace root entry is bumped."""
    lock = write_lock(
        tmp_path,
        SINGLE_LOCAL.replace('{ editable = "." }', '{ virtual = "." }'),
    )
    assert_that(run_update(lock).returncode).is_equal_to(0)
    assert_that(versions(lock)).is_equal_to({"{'virtual': '.'}": "2.0.0"})


def test_platform_sources_update_only_the_member_and_its_references(
    tmp_path: Path,
) -> None:
    """Only the member entry and the references pinning it change."""
    lock = write_lock(tmp_path, PLATFORM_SOURCES)
    member = tmp_path / "packages" / "demo"
    member.mkdir(parents=True)
    result = run_update(lock, "--project-dir", str(member))
    assert_that(result.returncode).described_as(result.stderr).is_equal_to(0)

    assert_that(versions(lock)).is_equal_to(
        {
            "{'registry': 'https://pypi.org/simple'}": "0.9.0",
            "{'editable': 'packages/demo'}": "2.0.0",
        },
    )
    app = next(p for p in load(lock)["package"] if p["name"] == "app")
    refs = [*app["dependencies"], *app["optional-dependencies"]["extra"]]
    pinned = {(str(r["source"]), r["version"]) for r in refs}
    assert_that(pinned).is_equal_to(
        {
            ("{'registry': 'https://pypi.org/simple'}", "0.9.0"),
            ("{'editable': 'packages/demo'}", "2.0.0"),
        },
    )
    # Exactly the three member version strings changed.
    before = PLATFORM_SOURCES.splitlines()
    after = lock.read_text(encoding="utf-8").splitlines()
    changed = [a for b, a in zip(before, after, strict=True) if a != b]
    assert_that(changed).is_length(3)


def test_reference_without_source_follows_a_unique_version(tmp_path: Path) -> None:
    """A sourceless reference follows the bump when its version is unique."""
    content = PLATFORM_SOURCES.replace(
        '{ name = "demo", version = "1.0.0", source = { editable = "packages/demo" }, '
        "marker = \"sys_platform != 'win32'\" },\n]\n\n[package.optional",
        '{ name = "demo", version = "1.0.0", '
        "marker = \"sys_platform != 'win32'\" },\n]\n\n[package.optional",
    )
    assert_that(content).is_not_equal_to(PLATFORM_SOURCES)
    lock = write_lock(tmp_path, content)
    member = tmp_path / "packages" / "demo"
    member.mkdir(parents=True)
    assert_that(run_update(lock, "--project-dir", str(member)).returncode).is_zero()
    app = next(p for p in load(lock)["package"] if p["name"] == "app")
    assert_that([r["version"] for r in app["dependencies"]]).is_equal_to(
        ["0.9.0", "2.0.0"],
    )


@pytest.mark.parametrize(
    ("content", "project", "message"),
    [
        pytest.param(
            SINGLE_LOCAL.replace('{ editable = "." }', '{ registry = "https://x" }'),
            ".",
            "no 'demo' entry has a local source at '.'",
            id="no-local-entry",
        ),
        pytest.param(
            SINGLE_LOCAL,
            "sub",
            "no 'demo' entry has a local source at 'sub'",
            id="local-entry-elsewhere",
        ),
        pytest.param(
            SINGLE_LOCAL + '\n[[package]]\nname = "demo"\nversion = "1.0.1"\n'
            'source = { directory = "./" }\n',
            ".",
            "2 'demo' entries have a local source at '.'",
            id="two-local-entries",
        ),
        pytest.param(
            SINGLE_LOCAL.replace('name = "demo"', 'name = "else"'),
            ".",
            "package 'demo' not found",
            id="target-missing",
        ),
        pytest.param(
            PLATFORM_SOURCES.replace('version = "0.9.0"', 'version = "1.0.0"').replace(
                '{ name = "demo", version = "1.0.0", source = { editable = '
                '"packages/demo" }, marker = "sys_platform != \'win32\'" },\n]\n\n'
                "[package.optional",
                '{ name = "demo", version = "1.0.0", '
                "marker = \"sys_platform != 'win32'\" },\n]\n\n[package.optional",
            ),
            "packages/demo",
            "pins 'demo' 1.0.0 without a source, and 2 entries carry that version",
            id="ambiguous-reference",
        ),
    ],
)
def test_fails_closed_without_writing(
    tmp_path: Path,
    content: str,
    project: str,
    message: str,
) -> None:
    """Ambiguous or missing targets exit non-zero and leave the lock."""
    lock = write_lock(tmp_path, content)
    (tmp_path / project).mkdir(parents=True, exist_ok=True)
    result = run_update(lock, "--project-dir", str(tmp_path / project))
    assert_that(result.returncode).is_equal_to(1)
    assert_that(result.stderr).contains(message)
    assert_that(lock.read_text(encoding="utf-8")).is_equal_to(content)
    assert_that([p.name for p in tmp_path.iterdir() if p.suffix == ".tmp"]).is_empty()


def test_read_with_project_dir_reads_the_same_entry(tmp_path: Path) -> None:
    """read-uv-lock-version.py --project-dir reads the rewritten entry."""
    lock = write_lock(tmp_path, PLATFORM_SOURCES)
    member = tmp_path / "packages" / "demo"
    member.mkdir(parents=True)
    result = subprocess.run(
        [sys.executable, str(READ), str(lock), "demo", "--project-dir", str(member)],
        capture_output=True,
        text=True,
        check=True,
    )
    assert_that(result.stdout.strip()).is_equal_to("1.0.0")
    result = subprocess.run(
        [sys.executable, str(READ), str(lock), "demo", "--project-dir", str(tmp_path)],
        capture_output=True,
        text=True,
        check=True,
    )
    assert_that(result.stdout.strip()).is_empty()


@pytest.mark.skipif(shutil.which("bash") is None, reason="bash not available")
def test_python_sh_rewrites_without_running_uv_or_a_caller_venv(
    tmp_path: Path,
) -> None:
    """python.sh end to end in a hostile checkout, with tomlkit available.

    The bats copy of this test skips in the shell-tests job, which has no
    tomlkit; here the interpreter running pytest (which has it) is first on
    PATH as ``python3``.
    """
    for name in ("tomlkit.py", "pip.py", "pyproject.toml"):
        shutil.copy(HOSTILE / f"{name}.fixture", tmp_path / name)
    venv_bin = tmp_path / ".venv" / "bin"
    venv_bin.mkdir(parents=True)
    shutil.copy(HOSTILE / "venv-python.fixture", venv_bin / "python")
    (venv_bin / "python").chmod(0o755)
    (venv_bin / "python3").symlink_to("python")
    write_lock(
        tmp_path,
        'version = 1\nrevision = 3\nrequires-python = ">=3.9"\n\n'
        '[[package]]\nname = "hostile-caller"\nversion = "1.0.0"\n'
        'source = { editable = "." }\n',
    )

    tools = tmp_path.parent / f"{tmp_path.name}-tools"
    tools.mkdir()
    # A wrapper, not a symlink: a symlinked venv interpreter loses its venv.
    python3 = tools / "python3"
    python3.write_text(f'#!/bin/sh\nexec "{sys.executable}" "$@"\n', encoding="utf-8")
    python3.chmod(0o755)
    calls = tmp_path.parent / f"{tmp_path.name}-calls"
    uv = tools / "uv"
    uv.write_text(f'#!/bin/sh\necho "uv $*" >>"{calls}"\n', encoding="utf-8")
    uv.chmod(0o755)
    marker = tmp_path.parent / f"{tmp_path.name}-marker"

    env = {
        **os.environ,
        "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}",
        "NEXT_VERSION": "2.0.0",
        "ECOSYSTEM_CONFIG_JSON": "{}",
        "HOSTILE_IMPORT_MARKER": str(marker),
    }
    env.pop("VIRTUAL_ENV", None)
    result = subprocess.run(
        ["bash", str(ECOSYSTEMS / "python.sh")],
        cwd=tmp_path,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    output = result.stdout + result.stderr
    assert_that(result.returncode).described_as(output).is_equal_to(0)
    assert_that(output).contains("Updating own-package version in")
    assert_that(calls.exists()).described_as("uv was run").is_false()
    assert_that(marker.exists()).described_as("caller code ran").is_false()
    assert_that(versions(tmp_path / "uv.lock", "hostile-caller")).is_equal_to(
        {"{'editable': '.'}": "2.0.0"},
    )
