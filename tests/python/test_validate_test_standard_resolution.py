# SPDX-License-Identifier: MIT
"""Tests for how the test-standard check resolves bases and collects tests (#1625).

``scripts/ci/quality/validate_test_standard.py`` follows imports, module
aliases and attribute chains to decide which classes derive from
``unittest.TestCase``, applies Python's scoping rules (parameters and other
local bindings shadow outer names; class-level names are not visible inside
methods), and treats a test method a collected class inherits as collected.
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that
from standard_check_support import SCRIPT_PATH, empty_repo, rendered, source, write

TEST_A = "tests/python/test_a.py"
NO_DOC = "has no docstring saying what it proves"
UNITTEST = "is a unittest.TestCase; use pytest functions"

pytestmark = pytest.mark.usefixtures("no_github_ci")


@pytest.fixture(name="check", scope="module")
def fixture_check(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the validator."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="repo")
def fixture_repo(tmp_path: Path) -> Path:
    """Return an empty repository root with a ``tests/`` directory."""
    empty_repo(tmp_path)
    return tmp_path


@pytest.mark.parametrize(
    ("header", "base"),
    [
        pytest.param("from unittest import case as c", "c.TestCase", id="case-alias"),
        pytest.param("from unittest import case", "case.TestCase", id="case"),
        pytest.param(
            "from unittest import async_case",
            "async_case.IsolatedAsyncioTestCase",
            id="async-case",
        ),
        pytest.param("import unittest\nU = unittest", "U.TestCase", id="module-bound"),
        pytest.param(
            "import unittest as u\nC = u.case",
            "C.TestCase",
            id="submodule-bound",
        ),
        pytest.param("import unittest.case", "unittest.case.TestCase", id="dotted"),
    ],
)
def test_unittest_submodule_bases_are_reported(
    check: ModuleType,
    repo: Path,
    header: str,
    base: str,
) -> None:
    """A base reached through a unittest submodule or a bound module counts."""
    write(repo, TEST_A, source(header, f"class Cases({base}):", "    pass"))
    line = header.count("\n") + 2
    assert_that(rendered(check, repo)).is_equal_to(
        [f"{TEST_A}:{line}: [unittest-class] class Cases {UNITTEST}"],
    )


@pytest.mark.parametrize(
    ("header", "base"),
    [
        pytest.param("from tests.base import Outer as O", "O.Inner", id="aliased"),
        pytest.param("from base import Outer", "Outer.Inner", id="sibling"),
        pytest.param("import tests.base as b", "b.Outer.Inner", id="module"),
        pytest.param("from tests.base import Alias", "Alias", id="class-attribute"),
    ],
)
def test_nested_case_class_reached_through_an_import_is_reported(
    check: ModuleType,
    repo: Path,
    header: str,
    base: str,
) -> None:
    """An attribute chain on an imported class or module is followed."""
    shared = source(
        "import unittest",
        "class Outer:",
        "    class Inner(unittest.TestCase):",
        "        pass",
        "Alias = Outer.Inner",
    )
    write(repo, "tests/base.py", shared)
    write(repo, "tests/test_x.py", source(header, f"class Cases({base}):", "    pass"))
    assert_that(rendered(check, repo)).is_equal_to(
        [
            f"tests/base.py:3: [unittest-class] class Inner {UNITTEST}",
            f"tests/test_x.py:2: [unittest-class] class Cases {UNITTEST}",
        ],
    )


def test_inherited_methods_follow_python_method_order(
    check: ModuleType,
    repo: Path,
) -> None:
    """In a diamond, the method pytest collects is the one C3 order picks."""
    text = source(
        "class Root:",
        "    pass",
        "class Middle(Root):",
        "    def test_x(self):",
        "        pass",
        "class Left(Middle):",
        "    pass",
        "class Right(Root):",
        "    def test_x(self):",
        '        """Doc."""',
        "class TestConcrete(Left, Right):",
        "    pass",
    )
    write(repo, "tests/test_x.py", text)
    assert_that(rendered(check, repo)).is_equal_to(
        [f"tests/test_x.py:4: [missing-docstring] test_x {NO_DOC}"],
    )


def test_inherited_test_method_is_reported_once_where_defined(
    check: ModuleType,
    repo: Path,
) -> None:
    """A test method collected through subclasses is reported at its definition."""
    base = source(
        "class SharedTests:",
        "    def test_shared(self):",
        "        pass",
    )
    write(repo, "tests/helpers/shared.py", base)
    text = source(
        "from shared import SharedTests",
        "class BaseTests:",
        "    def test_inherited(self):",
        "        pass",
        "    def test_overridden(self):",
        "        pass",
        "class TestOne(BaseTests):",
        "    def test_overridden(self):",
        '        """Doc."""',
        "class TestTwo(BaseTests, SharedTests):",
        "    pass",
    )
    write(repo, "tests/helpers/test_x.py", text)
    assert_that(rendered(check, repo)).is_equal_to(
        [
            f"tests/helpers/shared.py:2: [missing-docstring] test_shared {NO_DOC}",
            f"tests/helpers/test_x.py:3: [missing-docstring] test_inherited {NO_DOC}",
            f"tests/helpers/test_x.py:5: [missing-docstring] test_overridden {NO_DOC}",
        ],
    )


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        pytest.param(
            source(
                "class Cases:",
                "    __test__ = True",
                "    def test_x(self):",
                "        pass",
            ),
            [f"{TEST_A}:3: [missing-docstring] test_x {NO_DOC}"],
            id="explicit-true",
        ),
        pytest.param(
            source(
                "class TestOff:",
                "    __test__ = False",
                "    def test_x(self):",
                "        pass",
            ),
            [],
            id="explicit-false",
        ),
    ],
)
def test_explicit_test_flag_decides_collection(
    check: ModuleType,
    repo: Path,
    text: str,
    expected: list[str],
) -> None:
    """``__test__`` turns collection on for any class name, or off."""
    write(repo, TEST_A, text)
    assert_that(rendered(check, repo)).is_equal_to(expected)


@pytest.mark.parametrize(
    "signature",
    [
        pytest.param("Base", id="positional"),
        pytest.param("*, Base", id="keyword-only"),
        pytest.param("Base, /", id="positional-only"),
        pytest.param("*Base", id="vararg"),
        pytest.param("**Base", id="kwarg"),
    ],
)
def test_function_parameter_shadows_an_outer_alias(
    check: ModuleType,
    repo: Path,
    signature: str,
) -> None:
    """A factory's parameter named like a unittest alias is not that alias."""
    text = source(
        "from unittest import TestCase as Base",
        f"def build({signature}):",
        "    class Plain(Base):",
        "        pass",
        "    return Plain",
    )
    write(repo, TEST_A, text)
    assert_that(rendered(check, repo)).is_empty()


def test_function_local_binding_shadows_an_outer_alias(
    check: ModuleType,
    repo: Path,
) -> None:
    """A name bound in a function, even by a loop, is that function's own."""
    text = source(
        "from unittest import TestCase as Base",
        "def build(kinds):",
        "    for Base in kinds:",
        "        class Plain(Base):",
        "            pass",
        "    return Plain",
    )
    write(repo, TEST_A, text)
    assert_that(rendered(check, repo)).is_empty()


def test_class_level_names_are_not_visible_in_methods(
    check: ModuleType,
    repo: Path,
) -> None:
    """A class attribute names a base for the class body, not for its methods."""
    text = source(
        "import unittest",
        "class Holder:",
        "    Base = unittest.TestCase",
        "    class Inner(Base):",
        "        pass",
        "    def build(self):",
        "        class Plain(Base):",
        "            pass",
        "        return Plain",
    )
    write(repo, TEST_A, text)
    assert_that(rendered(check, repo)).is_equal_to(
        [f"{TEST_A}:4: [unittest-class] class Inner {UNITTEST}"],
    )


@pytest.mark.parametrize(
    "text",
    [
        pytest.param(
            source(
                "class TestBuilder:",
                "    if True:",
                "        def __init__(self):",
                "            pass",
                "    def test_x(self):",
                "        pass",
            ),
            id="conditional",
        ),
        pytest.param(
            source(
                "class Builder:",
                "    def __init__(self):",
                "        pass",
                "class TestBuilder(Builder):",
                "    def test_x(self):",
                "        pass",
            ),
            id="inherited",
        ),
    ],
)
def test_class_with_a_constructor_is_not_collected(
    check: ModuleType,
    repo: Path,
    text: str,
) -> None:
    """A constructor anywhere in the class body or its bases stops collection."""
    write(repo, TEST_A, text)
    assert_that(rendered(check, repo)).is_empty()
