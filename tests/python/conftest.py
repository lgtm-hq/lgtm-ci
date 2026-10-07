# SPDX-License-Identifier: MIT
"""Shared pytest fixtures for the standalone scripts under ``scripts/ci``.

The scripts use hyphenated filenames (their invocation contract), so they are
loaded by path through :mod:`importlib` rather than imported as packages.
"""

from __future__ import annotations

import importlib.util
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
    spec.loader.exec_module(module)
    sys.modules[name] = module
    return module


@pytest.fixture(scope="session")
def fixtures_dir() -> Path:
    """Return the committed ``tests/fixtures`` directory."""
    return FIXTURES_DIR


@pytest.fixture(scope="session")
def load_script() -> Callable[[str], ModuleType]:
    """Return the script loader so test modules need no conftest import."""
    return load_script_module
