# SPDX-License-Identifier: MIT
"""Data-only Cargo manifest reads for the rust release updater (#1558).

``rust.sh`` uses ``read-cargo-manifest.py`` to tell a member that inherits
its version (``version.workspace = true``) from one with its own, to read
the root's ``[workspace.package] version``, to list the packages in
``cargo metadata`` output that inherit it, and to set a version as an edit
of that one value. None of it runs cargo.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest
from assertpy import assert_that

PROJECT_ROOT = Path(__file__).resolve().parents[2]
ECOSYSTEMS = PROJECT_ROOT / "scripts" / "ci" / "release" / "ecosystems"
READ = ECOSYSTEMS / "read-cargo-manifest.py"
# A multiline description holding lines that look like TOML syntax.
DECOY = 'description = """\nversion = "documentation"\n[workspace.package]\n"""'
VIRTUAL_ROOT = '[workspace]\nmembers = []\n\n[workspace.package]\nversion = "1.0.0"\n'


def run_read(*args: str) -> subprocess.CompletedProcess[str]:
    """Run the reader isolated, as rust.sh does."""
    return subprocess.run(
        [sys.executable, "-I", str(READ), *args],
        capture_output=True,
        text=True,
        check=False,
    )


def write(path: Path, text: str) -> Path:
    """Write ``text`` to ``path``, creating parents, and return it."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


@pytest.mark.parametrize(
    ("manifest", "expected"),
    [
        ('[package]\nname = "a"\nversion = "1.0.0"\n', "literal"),
        ('[package]\nname = "a"\nversion.workspace = true\n', "workspace"),
        ('[package]\nname = "a"\nversion = { workspace = true }\n', "workspace"),
        ('[package]\nname = "a"\n\n[package.version]\nworkspace = true\n', "workspace"),
        ('[package]\nname = "a"\n', "literal"),
        (VIRTUAL_ROOT, "literal"),
    ],
)
def test_version_source(tmp_path: Path, manifest: str, expected: str) -> None:
    """Inherited versions are told apart from literal or absent ones."""
    result = run_read("version-source", str(write(tmp_path / "Cargo.toml", manifest)))
    assert_that(result.returncode).is_equal_to(0)
    assert_that(result.stdout).is_equal_to(f"{expected}\n")


@pytest.mark.parametrize(
    "manifest",
    [
        '[package]\nname = "a"\nversion.workspace = false\n',
        '[package]\nname = "a"\nversion = 1\n',
        "[package\n",
    ],
)
def test_version_source_fails_closed(tmp_path: Path, manifest: str) -> None:
    """A version that is neither a string nor inherited is an error."""
    result = run_read("version-source", str(write(tmp_path / "Cargo.toml", manifest)))
    assert_that(result.returncode).is_equal_to(4)
    assert_that(result.stdout).is_empty()


def test_workspace_version(tmp_path: Path) -> None:
    """The root's [workspace.package] version is printed."""
    root = write(
        tmp_path / "Cargo.toml",
        '[workspace]\nmembers = []\n\n[workspace.package]\nversion = "1.2.3"\n',
    )
    result = run_read("workspace-version", str(root))
    assert_that(result.returncode).is_equal_to(0)
    assert_that(result.stdout).is_equal_to("1.2.3\n")


@pytest.mark.parametrize(
    "manifest",
    [
        "[workspace]\nmembers = []\n",
        '[workspace]\nmembers = []\n\n[workspace.package]\nedition = "2021"\n',
        '[package]\nname = "a"\nversion = "1.0.0"\n',
    ],
)
def test_workspace_version_missing(tmp_path: Path, manifest: str) -> None:
    """A root without [workspace.package] version exits 5."""
    root = write(tmp_path / "Cargo.toml", manifest)
    result = run_read("workspace-version", str(root))
    assert_that(result.returncode).is_equal_to(5)
    assert_that(result.stderr).contains("no [workspace.package] version")


def test_inheriting_lists_only_inheriting_packages(tmp_path: Path) -> None:
    """Only packages whose manifest inherits are listed, with cargo's version."""
    app = write(
        tmp_path / "app/Cargo.toml",
        '[package]\nname = "app"\nversion.workspace = true\n',
    )
    lib = write(
        tmp_path / "lib/Cargo.toml",
        '[package]\nname = "lib"\nversion = { workspace = true }\n',
    )
    own = write(
        tmp_path / "own/Cargo.toml",
        '[package]\nname = "own"\nversion = "0.3.0"\n',
    )
    metadata = {
        "workspace_root": str(tmp_path),
        "packages": [
            {"name": "app", "version": "2.0.0", "manifest_path": str(app)},
            {"name": "lib", "version": "2.0.0", "manifest_path": str(lib)},
            {"name": "own", "version": "0.3.0", "manifest_path": str(own)},
        ],
    }
    metadata_file = write(tmp_path / "m.json", json.dumps(metadata))
    result = run_read("inheriting", str(metadata_file))
    assert_that(result.returncode).is_equal_to(0)
    assert_that(result.stdout).is_equal_to("app 2.0.0\nlib 2.0.0\n")


@pytest.mark.parametrize(
    "metadata",
    ["not json", '{"packages": [{"name": "a"}]}', '{"packages": 1}'],
)
def test_inheriting_rejects_malformed_metadata(tmp_path: Path, metadata: str) -> None:
    """Metadata that is not what cargo prints fails closed."""
    result = run_read("inheriting", str(write(tmp_path / "m.json", metadata)))
    assert_that(result.returncode).is_equal_to(4)
    assert_that(result.stdout).is_empty()


def test_usage_error() -> None:
    """An unknown subcommand is a usage error."""
    result = run_read("bogus", "x")
    assert_that(result.returncode).is_equal_to(1)
    assert_that(result.stderr).contains("Usage:")


@pytest.mark.parametrize(
    "line",
    [
        '"version" = {workspace=true}',
        '"version".workspace=true',
        'version . "workspace" = true',
        "version = { workspace = true }",
    ],
)
def test_version_source_spellings(tmp_path: Path, line: str) -> None:
    """Quoted and dotted spellings of the inherited key are all detected."""
    manifest = f'[ "package" ]\nname = "a"\n{DECOY}\n{line}\n'
    result = run_read("version-source", str(write(tmp_path / "Cargo.toml", manifest)))
    assert_that(result.stdout).is_equal_to("workspace\n")


@pytest.mark.parametrize(
    "manifest",
    [
        '["package"."version"]\nworkspace = true\n\n[package]\nname = "a"\n',
        'package = { name = "a", version.workspace = true }\n',
        'package = { name = "a", version = { workspace = true } }\n',
    ],
)
def test_version_source_tables(tmp_path: Path, manifest: str) -> None:
    """Table and inline-table spellings of the inherited key are detected."""
    result = run_read("version-source", str(write(tmp_path / "Cargo.toml", manifest)))
    assert_that(result.stdout).is_equal_to("workspace\n")


@pytest.mark.parametrize(
    ("manifest", "expected"),
    [
        ('[package]\nname = "a"\nversion = "1.0.0"\n', "package\n"),
        (VIRTUAL_ROOT, "workspace.package\n"),
        (
            '[package]\nname = "a"\nversion = "1.0.0"\n\n' + VIRTUAL_ROOT,
            "package\nworkspace.package\n",
        ),
    ],
)
def test_literal_tables(tmp_path: Path, manifest: str, expected: str) -> None:
    """The tables setting a string version are listed."""
    result = run_read("literal-tables", str(write(tmp_path / "Cargo.toml", manifest)))
    assert_that(result.returncode).is_equal_to(0)
    assert_that(result.stdout).is_equal_to(expected)


def test_literal_tables_none(tmp_path: Path) -> None:
    """A manifest without any string version exits 5."""
    manifest = "[workspace]\nmembers = []\n"
    result = run_read("literal-tables", str(write(tmp_path / "Cargo.toml", manifest)))
    assert_that(result.returncode).is_equal_to(5)


def set_version(path: Path, *tables: str, version: str = "2.0.0") -> bytes:
    """Run ``set-version`` and return its stdout, requiring success."""
    result = subprocess.run(
        [sys.executable, "-I", str(READ), "set-version", str(path), version, *tables],
        capture_output=True,
        check=False,
    )
    assert_that(result.returncode).described_as(result.stderr.decode()).is_equal_to(
        0,
    )
    return result.stdout


@pytest.mark.parametrize(
    ("table", "header"),
    [
        ("package", "[package]"),
        ("package", '[ "package" ]'),
        ("workspace.package", "[workspace.package]"),
        ("workspace.package", "[ workspace . 'package' ]"),
    ],
)
def test_set_version_skips_multiline_decoys(
    tmp_path: Path,
    table: str,
    header: str,
) -> None:
    """Only the real key changes, never one inside a multiline string."""
    before = (
        f"{header}\n{DECOY}\n"
        "notes = '''\nversion = 'literal'\n[package]\n'''\n"
        'escaped = "version = \\"x\\""\n'
        'version   =  "1.0.0"   # keep\n'
        "other = 1979-05-27 07:32:00Z\n"
        '[dependencies]\nx = { version = "1.0.0" }\n'
    )
    path = write(tmp_path / "Cargo.toml", before)
    after = set_version(path, table).decode()
    assert_that(after).is_equal_to(
        before.replace('"1.0.0"   # keep', '"2.0.0"   # keep'),
    )


def test_set_version_allows_nan_elsewhere(tmp_path: Path) -> None:
    """A TOML nan elsewhere (NaN != NaN) does not count as a change."""
    before = (
        '[workspace.package]\nversion = "1.0.0"\n'
        "[workspace.metadata]\nx = nan\ny = [nan, { z = -nan }]\n"
    )
    path = write(tmp_path / "Cargo.toml", before)
    after = set_version(path, "workspace.package").decode()
    assert_that(after).is_equal_to(before.replace('"1.0.0"', '"2.0.0"'))


@pytest.mark.parametrize("quote", ['"""', "'''"])
def test_set_version_keeps_triple_quotes(tmp_path: Path, quote: str) -> None:
    """A triple-quoted version keeps its delimiters."""
    before = f'[package]\nname = "a"\nversion = {quote}1.0.0{quote}\n'
    path = write(tmp_path / "Cargo.toml", before)
    after = set_version(path, "package").decode()
    assert_that(after).is_equal_to(
        before.replace(f"{quote}1.0.0{quote}", f"{quote}2.0.0{quote}"),
    )


def test_set_version_same_version_is_byte_identical(tmp_path: Path) -> None:
    """A version already at the target leaves the decoy and file as they are."""
    before = f'[package]\nname = "a"\n{DECOY}\nversion = "2.0.0"\n'
    path = write(tmp_path / "Cargo.toml", before)
    assert_that(set_version(path, "package").decode()).is_equal_to(before)


def test_set_version_keeps_crlf_and_literal_quotes(tmp_path: Path) -> None:
    """CRLF line endings and a literal-string version keep their form."""
    before = b"[package]\r\nname = 'a'\r\nversion = '1.0.0'\r\n\r\n[x]\r\ny = 1\r\n"
    path = tmp_path / "Cargo.toml"
    path.write_bytes(before)
    after = set_version(path, "package")
    assert_that(after).is_equal_to(before.replace(b"'1.0.0'", b"'2.0.0'"))


def test_set_version_both_tables_and_inline(tmp_path: Path) -> None:
    """Both tables are set; a version in an inline table is found too."""
    before = 'package = { name = "a", version = "1.0.0" }\n\n'
    before += '[workspace.package]\nversion = "1.0.0"\n'
    path = write(tmp_path / "Cargo.toml", before)
    after = set_version(path, "package", "workspace.package").decode()
    assert_that(after).is_equal_to(before.replace("1.0.0", "2.0.0"))


def test_set_version_rustume_root_matches_line_rewrite(tmp_path: Path) -> None:
    """A Rustume-style root comes out as the old line rewrite left it."""
    before = (
        '[workspace]\nresolver = "2"\nmembers = ["crates/core"]\n\n'
        '# Shared package metadata\n[workspace.package]\nversion = "1.0.0"\n'
        'edition = "2021"\n\n[workspace.dependencies]\n'
        'core = { path = "crates/core", version = "1.0.0" }\n'
    )
    path = write(tmp_path / "Cargo.toml", before)
    after = set_version(path, "workspace.package").decode()
    assert_that(after).is_equal_to(
        before.replace('version = "1.0.0"\nedition', 'version = "2.0.0"\nedition'),
    )


@pytest.mark.parametrize(
    ("manifest", "version", "code"),
    [
        ('[package]\nname = "a"\nversion.workspace = true\n', "2.0.0", 5),
        ('[package]\nname = "a"\nversion = "1.0.0"\n', '2.0.0"', 7),
        ('[package]\nname = "a"\nversion = "1.0.0"\n', "2.0.0\n", 7),
        ("[package\n", "2.0.0", 4),
    ],
)
def test_set_version_fails_closed(
    tmp_path: Path,
    manifest: str,
    version: str,
    code: int,
) -> None:
    """No string version, an unusable version or bad TOML print nothing."""
    path = write(tmp_path / "Cargo.toml", manifest)
    result = run_read("set-version", str(path), version, "package")
    assert_that(result.returncode).is_equal_to(code)
    assert_that(result.stdout).is_empty()


def test_set_version_usage(tmp_path: Path) -> None:
    """An unknown table is a usage error."""
    path = write(tmp_path / "Cargo.toml", VIRTUAL_ROOT)
    result = run_read("set-version", str(path), "2.0.0", "dependencies")
    assert_that(result.returncode).is_equal_to(1)


@pytest.mark.skipif(
    sys.version_info >= (3, 15),
    reason="Python >= 3.15 parses TOML 1.1 multiline inline tables",
)
def test_toml11_multiline_inline_table_fails_closed(tmp_path: Path) -> None:
    """TOML 1.1 syntax is unparseable here, with the Python requirement named."""
    manifest = '[package]\nname = "a"\nversion = {\n  workspace = true,\n}\n'
    result = run_read("version-source", str(write(tmp_path / "Cargo.toml", manifest)))
    assert_that(result.returncode).is_equal_to(4)
    assert_that(result.stderr).contains("TOML 1.1 syntax")
    assert_that(result.stderr).contains("needs Python >= 3.15")
