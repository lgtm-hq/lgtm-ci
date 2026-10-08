# SPDX-License-Identifier: MIT
"""Shared pytest fixtures for the standalone scripts under ``scripts/ci``.

The scripts use hyphenated filenames (their invocation contract), so they are
loaded by path through :mod:`importlib` rather than imported as packages.
"""

from __future__ import annotations

import importlib.util
import shutil
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest

PROJECT_ROOT = Path(__file__).resolve().parents[2]
FIXTURES_DIR = PROJECT_ROOT / "tests" / "fixtures"


def load_script_module(relative_path: str) -> ModuleType:
    """Load a hyphenated script from ``scripts/ci`` as a module.

    Args:
        relative_path: Script path relative to the project root, for example
            ``scripts/ci/security/format-security-comment.py``.

    Returns:
        The executed module object.

    Raises:
        ImportError: When the path does not resolve to a loadable module.
    """
    path = PROJECT_ROOT / relative_path
    if not path.is_file():
        raise ImportError(f"no script at {path}")
    name = path.stem.replace("-", "_")
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    # Register before executing: dataclasses resolve string annotations through
    # sys.modules[cls.__module__] at class-creation time (Python 3.14+).
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except Exception:
        sys.modules.pop(name, None)
        raise
    return module


@pytest.fixture(scope="session")
def fixtures_dir() -> Path:
    """Return the committed ``tests/fixtures`` directory."""
    return FIXTURES_DIR


@pytest.fixture(scope="session")
def load_script() -> Callable[[str], ModuleType]:
    """Return the script loader so test modules need no conftest import."""
    return load_script_module


@pytest.fixture(scope="session")
def formatter() -> ModuleType:
    """Load ``format-security-comment.py`` once per session."""
    return load_script_module("scripts/ci/security/format-security-comment.py")


@pytest.fixture
def workspace(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Return an empty working directory and make it the cwd.

    The security scripts read ``.osv-scanner.toml`` relative to the cwd,
    which in CI is the audited working directory.
    """
    monkeypatch.chdir(tmp_path)
    return tmp_path


@pytest.fixture
# pytest injects the `workspace` fixture by parameter name; the shadowing is
# the mechanism, not a mistake.
def install_fixture(
    workspace: Path,  # pylint: disable=redefined-outer-name
) -> Callable[[str, str], Path]:
    """Return a copier from ``tests/fixtures`` into the workspace.

    The returned callable takes the fixture path relative to
    ``tests/fixtures`` and the destination name inside the workspace.
    """

    def _install(relative: str, dest_name: str) -> Path:
        dest = workspace / dest_name
        shutil.copyfile(src=FIXTURES_DIR / relative, dst=dest)
        return dest

    return _install


PERMISSIONS_VALIDATOR = "scripts/ci/docs/validate-caller-permissions.py"


@pytest.fixture(scope="session")
def permissions_validator() -> ModuleType:
    """Load ``validate-caller-permissions.py`` once per session."""
    return load_script_module(PERMISSIONS_VALIDATOR)


@pytest.fixture
def caller_repo(tmp_path: Path) -> Callable[[dict[str, str]], Path]:
    """Return a builder for a caller-permissions fixture repository.

    The returned callable writes each ``file name: YAML`` pair under
    ``.github/workflows``, creates empty ``docs/`` and ``examples/``
    directories, and returns the repository root.
    """

    def _build(workflows: dict[str, str]) -> Path:
        workflows_dir = tmp_path / ".github" / "workflows"
        workflows_dir.mkdir(parents=True)
        for name, body in workflows.items():
            (workflows_dir / name).write_text(body, encoding="utf-8")
        (tmp_path / "docs").mkdir()
        (tmp_path / "examples").mkdir()
        return tmp_path

    return _build


@pytest.fixture
# pytest injects the `permissions_validator` fixture by parameter name.
def run_validator(
    permissions_validator: ModuleType,  # pylint: disable=redefined-outer-name
) -> Callable[..., int]:
    """Return a runner: ``run_validator(repo, *paths)`` gives the exit code."""

    def _run(repo: Path, *paths: str) -> int:
        code: int = permissions_validator.main(argv=["--repo-root", str(repo), *paths])
        return code

    return _run
