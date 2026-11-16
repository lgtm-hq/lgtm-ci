# SPDX-License-Identifier: MIT
"""Fixtures for the governance tests (#1082): script modules and a demo repo."""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from governance_helpers import (  # pylint: disable=import-error
    CATALOG,
    LEGACY_WORKFLOW,
    PREVIEW_WORKFLOW,
    STABLE_WORKFLOW,
    consumers_yaml,
    git,
)


@pytest.fixture(scope="session")
def deprecations(
    load_script: Callable[[str], ModuleType],
) -> ModuleType:
    """Load ``deprecations.py`` once per session."""
    return load_script("scripts/ci/catalog/deprecations.py")


@pytest.fixture(scope="session")
def validate(
    load_script: Callable[[str], ModuleType],
) -> ModuleType:
    """Load the catalog ``validate.py`` once per session."""
    return load_script("scripts/ci/catalog/validate.py")


@pytest.fixture(scope="session")
def release_notes(
    load_script: Callable[[str], ModuleType],
) -> ModuleType:
    """Load ``release_notes.py`` once per session."""
    return load_script("scripts/ci/catalog/release_notes.py")


@pytest.fixture(name="catalog_tree")
def fixture_catalog_tree(
    tmp_path: Path,
) -> Path:
    """Write the demo catalog tree to disk, without a git repository."""
    root = tmp_path / "repo"
    workflows = root / ".github" / "workflows"
    workflows.mkdir(parents=True)
    (root / "catalog").mkdir()
    (workflows / "reusable-demo.yml").write_text(STABLE_WORKFLOW, encoding="utf-8")
    (workflows / "reusable-preview.yml").write_text(PREVIEW_WORKFLOW, encoding="utf-8")
    (workflows / "reusable-legacy.yml").write_text(LEGACY_WORKFLOW, encoding="utf-8")
    (root / "catalog" / "catalog.yml").write_text(CATALOG, encoding="utf-8")
    (root / "catalog" / "consumers.yml").write_text(
        consumers_yaml([]),
        encoding="utf-8",
    )
    (root / "catalog" / "deprecation-exceptions.yml").write_text(
        "---\nschema-version: 1\nexceptions: []\n",
        encoding="utf-8",
    )
    return root


@pytest.fixture
def repo(
    catalog_tree: Path,
) -> Path:
    """Build a repository whose ``main`` has the demo catalog committed."""
    git(catalog_tree, "init", "-q", "-b", "main")
    git(catalog_tree, "add", "-A")
    git(catalog_tree, "commit", "-q", "-m", "base")
    return catalog_tree


@pytest.fixture(scope="session")
def consumer_scan(
    load_script: Callable[[str], ModuleType],
) -> ModuleType:
    """Load ``consumer_scan.py`` once per session."""
    return load_script("scripts/ci/catalog/consumer_scan.py")


@pytest.fixture(scope="session")
def governance(
    load_script: Callable[[str], ModuleType],
) -> ModuleType:
    """Load ``governance_checks.py`` once per session."""
    return load_script("scripts/ci/catalog/governance_checks.py")
