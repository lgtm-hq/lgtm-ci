# SPDX-License-Identifier: MIT
"""The Cobertura rate reader, ``scripts/ci/lib/testing/cobertura_rates.py`` (#1692).

It prints the line and branch rates of the document root of one untrusted
Cobertura file as percentages, ``absent`` or ``invalid``, with the XML safety
of ``junit_cases.py`` and kcov's inert DOCTYPE allowed. ``extract.sh`` and
its bats tests cover the comment, summary, merge, threshold and badge use.
"""

from __future__ import annotations

import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

PROJECT_ROOT = Path(__file__).resolve().parents[2]
READER_PATH = "scripts/ci/lib/testing/cobertura_rates.py"
HEAD = '<?xml version="1.0" ?>\n'
KCOV_DOCTYPE = "<!DOCTYPE coverage SYSTEM 'http://cobertura.sourceforge.net/xml/coverage-04.dtd'>\n"


#: coverage.py 7.x and kcov v43 roots (kcov writes the inert DOCTYPE).
COVERAGE_PY_DOC = f'{HEAD}<coverage line-rate="0.85" branch-rate="0.80"></coverage>'
KCOV_DOC = f'{HEAD}{KCOV_DOCTYPE}<coverage line-rate="0.950" branch-rate="1.0"/>'


@pytest.fixture(name="reader", scope="module")
def fixture_reader(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the reader module by path, as python3 -I runs it."""
    return load_script(READER_PATH)


def _run(path: Path) -> subprocess.CompletedProcess[str]:
    """Run the reader the way extract.sh does: python3 -I."""
    return subprocess.run(
        [sys.executable, "-I", str(PROJECT_ROOT / READER_PATH), str(path)],
        capture_output=True,
        text=True,
        check=False,
    )


def _rates(tmp_path: Path, document: str | bytes) -> tuple[str, str]:
    """Return (stdout line, stderr) for one document."""
    path = tmp_path / "coverage.xml"
    if isinstance(document, str):
        path.write_text(document, encoding="utf-8")
    else:
        path.write_bytes(document)
    result = _run(path)
    assert_that(result.returncode).is_equal_to(0)
    return result.stdout.strip(), result.stderr


@pytest.mark.parametrize(
    ("document", "expected"),
    [
        pytest.param(
            COVERAGE_PY_DOC,
            "85.00 80.00",
            id="coverage-py",
        ),
        pytest.param(
            KCOV_DOC,
            "95.00 100.00",
            id="kcov-v43-doctype",
        ),
        pytest.param(
            f'{HEAD}<coverage line-rate="0.9"/>',
            "90.00 absent",
            id="no-branch",
        ),
        pytest.param(
            f'{HEAD}<coverage branch-rate="0.9"/>',
            "absent 90.00",
            id="no-line",
        ),
        pytest.param(
            f'{HEAD}<coverage line-rate="1.234e-05" branch-rate="5E-1"/>',
            "0.00 50.00",
            id="scientific",
        ),
        pytest.param(
            f"{HEAD}<coverage line-rate='0.5' branch-rate = '0.25'/>",
            "50.00 25.00",
            id="single-quotes",
        ),
        pytest.param(
            f'{HEAD}<coverage line-rate="" branch-rate="1.5"/>',
            "invalid invalid",
            id="empty-and-above-one",
        ),
        pytest.param(
            f'{HEAD}<coverage line-rate="-0.1" branch-rate="nan"/>',
            "invalid invalid",
            id="signed-and-nan",
        ),
        pytest.param(
            f'{HEAD}<!-- <coverage line-rate="1"> --><coverage line-rate="0.1"/>',
            "10.00 absent",
            id="comment-is-not-the-root",
        ),
    ],
)
def test_reads_the_root_rates(tmp_path: Path, document: str, expected: str) -> None:
    """The root's attributes are read, checked and turned into percentages."""
    assert_that(_rates(tmp_path, document)[0]).is_equal_to(expected)


@pytest.mark.parametrize(
    ("document", "reason"),
    [
        pytest.param(
            f'{HEAD}<report><coverage line-rate="1"/></report>',
            "root element <report> is not <coverage>",
            id="wrong-root",
        ),
        pytest.param(
            f'{HEAD}<coverage line-rate="1"/><coverage line-rate="0.1"/>',
            "not well-formed XML",
            id="two-roots",
        ),
        pytest.param(
            f'{HEAD}<!DOCTYPE coverage [<!ENTITY x SYSTEM "file:///etc/passwd">]>'
            '<coverage line-rate="1">&x;</coverage>',
            "DOCTYPE that is not the Cobertura DTD",
            id="entity-declaration",
        ),
        pytest.param(
            f'{HEAD}<!DOCTYPE coverage SYSTEM "http://example.invalid/x.dtd">'
            '<coverage line-rate="1"/>',
            "DOCTYPE that is not the Cobertura DTD",
            id="unknown-dtd",
        ),
        pytest.param(
            f'{HEAD}{KCOV_DOCTYPE}{KCOV_DOCTYPE}<coverage line-rate="1"/>',
            "not well-formed XML",
            id="two-doctypes",
        ),
        pytest.param(
            f'{HEAD}<!DOCTYPE coverage PUBLIC "-//x//EN" '
            '"http://cobertura.sourceforge.net/xml/coverage-04.dtd">'
            '<coverage line-rate="1"/>',
            "DOCTYPE that is not the Cobertura DTD",
            id="public-identifier",
        ),
        pytest.param(
            f'{HEAD}{KCOV_DOCTYPE}<coverage line-rate="1">&undeclared;</coverage>',
            "declares a DOCTYPE or an entity",
            id="undeclared-entity",
        ),
        pytest.param(
            '<?xml version="1.0" encoding="ISO-8859-1"?><coverage line-rate="1"/>',
            "declares an encoding other than UTF-8",
            id="other-encoding",
        ),
    ],
)
def test_refuses_what_is_not_one_safe_coverage_root(
    tmp_path: Path,
    document: str,
    reason: str,
) -> None:
    """A wrong root, a malformed document or a declaration is unreadable."""
    line, stderr = _rates(tmp_path, document)
    assert_that(line).is_equal_to("invalid invalid")
    assert_that(stderr).contains(reason)


def test_refuses_bytes_that_are_not_utf8(tmp_path: Path) -> None:
    """A NUL byte or invalid UTF-8 is unreadable, never decoded loosely."""
    for raw in (b'<coverage line-rate="1"/>\x00', b'\xff<coverage line-rate="1"/>'):
        assert_that(_rates(tmp_path, raw)[0]).is_equal_to("invalid invalid")


def test_refuses_deep_nesting(tmp_path: Path) -> None:
    """Elements nested deeper than the limit make the file unreadable."""
    depth = 70
    nested = "<a>" * depth + "</a>" * depth
    document = f'<coverage line-rate="1">{nested}</coverage>'
    line, stderr = _rates(tmp_path, document)
    assert_that(line).is_equal_to("invalid invalid")
    assert_that(stderr).contains("nested deeper than")


def test_refuses_a_file_over_the_size_limit(
    reader: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A file larger than the limit is never parsed."""
    path = tmp_path / "coverage.xml"
    path.write_text('<coverage line-rate="1"/>', encoding="utf-8")
    monkeypatch.setattr(reader, "MAX_FILE_BYTES", 8)
    with pytest.raises(reader.Unreadable, match="larger than 8 bytes"):
        reader.read_rates(path)


def test_a_missing_file_and_a_usage_error(tmp_path: Path) -> None:
    """A file that cannot be opened is unreadable; a wrong call exits 2."""
    line, stderr = _rates(tmp_path, "")
    assert_that(line).is_equal_to("invalid invalid")
    result = _run(tmp_path / "absent.xml")
    assert_that(result.stdout.strip()).is_equal_to("invalid invalid")
    assert_that(result.stderr).contains("cannot be read")
    usage = subprocess.run(
        [sys.executable, "-I", str(PROJECT_ROOT / READER_PATH)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert_that(usage.returncode).is_equal_to(2)
    assert_that(stderr).contains("not well-formed XML")


def test_percent_of_rates(reader: ModuleType) -> None:
    """Rates as written turn into two-decimal percentages, absent or invalid."""
    cases = {
        None: "absent",
        "1": "100.00",
        "0.1234": "12.34",
        "1.": "invalid",
        "0,5": "invalid",
    }
    for rate, expected in cases.items():
        assert_that(reader.percent(rate)).is_equal_to(expected)
