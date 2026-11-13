# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/bootstrap/sync_inline_blocks.py`` (#1450).

The repository check here is what fails CI when an inline copy drifts from its
source script. The installer's behaviour is exercised in
``tests/bats/contract/test_trivy_acquisition.bats``.
"""

from __future__ import annotations

import shutil
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
import yaml
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/bootstrap/sync_inline_blocks.py"
TRIVY = "install-verified-trivy"
BEGIN = f"# lgtm-ci-inline:begin {TRIVY}"
END = f"# lgtm-ci-inline:end {TRIVY}"
DOCKER_WORKFLOWS = (
    "reusable-docker-build.yml",
    "reusable-docker-multiplatform-publish.yml",
    "reusable-docker-multiplatform-validate.yml",
)


@pytest.fixture(name="sync")
def fixture_sync(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the sync script without running it."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="scratch")
def fixture_scratch(
    sync: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> Path:
    """Copy the marked workflows to a scratch dir and point the sync at it."""
    for name in DOCKER_WORKFLOWS:
        shutil.copy(sync.DEFAULT_WORKFLOWS_DIR / name, tmp_path / name)
    monkeypatch.setenv("WORKFLOWS_DIR", str(tmp_path))
    return tmp_path


def _edit(path: Path, old: str, new: str, count: int = 1) -> None:
    """Replace ``old`` in a file, failing when it is not present."""
    text = path.read_text(encoding="utf-8")
    assert_that(text).contains(old)
    path.write_text(text.replace(old, new, count), encoding="utf-8")


def test_repository_copies_are_in_sync(
    sync: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """``--check`` passes on the committed workflows."""
    monkeypatch.delenv("WORKFLOWS_DIR", raising=False)
    assert_that(sync.main(argv=["--check"])).is_equal_to(0)


def test_every_trivy_step_is_the_marked_source_body(sync: ModuleType) -> None:
    """Each parsed ``Install verified Trivy`` run is markers plus the source body."""
    body = sync.source_body(TRIVY)
    expected = "\n".join([BEGIN, *body, END]) + "\n"
    runs = []
    for name in DOCKER_WORKFLOWS:
        workflow = yaml.safe_load((sync.DEFAULT_WORKFLOWS_DIR / name).read_text())
        for job in workflow["jobs"].values():
            for step in job.get("steps", []):
                if step.get("name") == "Install verified Trivy":
                    runs.append(step["run"])
    assert_that(runs).is_length(sync.BLOCKS[TRIVY].copies)
    for run in runs:
        assert_that(run).is_equal_to(expected)


def test_source_body_excludes_shebang_and_header(sync: ModuleType) -> None:
    """Only lines between the source markers are embedded."""
    body = sync.source_body(TRIVY)
    assert_that(body[0]).starts_with("# Workflow-owned acquisition")
    assert_that("\n".join(body)).does_not_contain("SPDX").does_not_contain("#!/")
    assert_that(body[-1]).contains("GITHUB_PATH")


def test_check_names_a_drifted_copy(
    sync: ModuleType,
    scratch: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A hand-edited copy fails the check and is named."""
    _edit(scratch / DOCKER_WORKFLOWS[2], "version=0.76.2", "version=0.76.3")
    assert_that(sync.main(argv=["--check"])).is_equal_to(1)
    err = capsys.readouterr().err
    assert_that(err).contains("differs from its source", DOCKER_WORKFLOWS[2])
    assert_that(err).does_not_contain(DOCKER_WORKFLOWS[0])


def test_sync_restores_a_drifted_copy(
    sync: ModuleType,
    scratch: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Without ``--check`` the drifted copy is rewritten to the committed one."""
    target = scratch / DOCKER_WORKFLOWS[0]
    _edit(target, "--max-time 120", "--max-time 600", count=-1)
    assert_that(sync.main(argv=[])).is_equal_to(0)
    assert_that(capsys.readouterr().out).contains(f"updated {DOCKER_WORKFLOWS[0]}")
    original = (sync.DEFAULT_WORKFLOWS_DIR / DOCKER_WORKFLOWS[0]).read_text()
    assert_that(target.read_text()).is_equal_to(original)
    assert_that(sync.main(argv=["--check"])).is_equal_to(0)


def test_check_fails_when_a_marker_pair_is_removed(
    sync: ModuleType,
    scratch: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Dropping both markers from one copy leaves too few copies."""
    target = scratch / DOCKER_WORKFLOWS[1]
    _edit(target, f"          {BEGIN}\n", "")
    _edit(target, f"          {END}\n", "")
    assert_that(sync.main(argv=["--check"])).is_equal_to(1)
    err = capsys.readouterr().err
    assert_that(err).contains(f"expected 4 copies of {TRIVY}, found 3")


@pytest.mark.parametrize(
    "case",
    [
        (f"          {END}\n", "", "has no end marker"),
        (f"          {BEGIN}\n", "", "without a matching begin"),
        (BEGIN, "# lgtm-ci-inline:begin no-such-block", "unknown inline block id"),
    ],
    ids=["missing-end", "missing-begin", "unknown-id"],
)
def test_check_fails_on_a_malformed_marker(
    sync: ModuleType,
    scratch: Path,
    capsys: pytest.CaptureFixture[str],
    case: tuple[str, str, str],
) -> None:
    """An unpaired or unknown marker fails and names the file."""
    old, new, message = case
    _edit(scratch / DOCKER_WORKFLOWS[2], old, new)
    assert_that(sync.main(argv=["--check"])).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(DOCKER_WORKFLOWS[2], message)


def test_render_reindents_to_the_marker_and_keeps_blank_lines_bare(
    sync: ModuleType,
) -> None:
    """Body lines take the begin marker's indent; empty lines get none."""
    text = f"a:\n    {BEGIN}\n    stale\n    {END}\nb: 1\n"
    updated, counts = sync.render(text, {TRIVY: ["one", "", "  two"]})
    expected = f"a:\n    {BEGIN}\n    one\n\n      two\n    {END}\nb: 1\n"
    assert_that(updated).is_equal_to(expected)
    assert_that(counts).is_equal_to({TRIVY: 1})


def test_render_rejects_a_nested_begin(sync: ModuleType) -> None:
    """A second begin before the end is an error."""
    text = f"{BEGIN}\n{BEGIN}\n{END}\n"
    with pytest.raises(sync.MarkerError, match="inside open"):
        sync.render(text, {TRIVY: []})


def test_source_without_markers_is_an_error(
    sync: ModuleType,
    tmp_path: Path,
) -> None:
    """A source script missing its marker pair cannot be embedded."""
    script = tmp_path / sync.BLOCKS[TRIVY].script
    script.parent.mkdir(parents=True)
    script.write_text("#!/usr/bin/env bash\necho hi\n", encoding="utf-8")
    with pytest.raises(sync.MarkerError, match="exactly one begin/end"):
        sync.source_body(TRIVY, root=tmp_path)


def test_check_fails_on_a_crlf_line_in_a_copy(
    sync: ModuleType,
    scratch: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A CRLF line ending inside a copy is drift, not a match."""
    target = scratch / DOCKER_WORKFLOWS[1]
    data = target.read_bytes()
    assert_that(data.count(b"version=0.76.2\n")).is_greater_than(0)
    target.write_bytes(data.replace(b"version=0.76.2\n", b"version=0.76.2\r\n", 1))
    assert_that(sync.main(argv=["--check"])).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(DOCKER_WORKFLOWS[1])


def test_sync_leaves_bytes_outside_the_markers_alone(
    sync: ModuleType,
    scratch: Path,
) -> None:
    """Syncing a CRLF file rewrites only the marked body, nothing before or after."""
    target = scratch / DOCKER_WORKFLOWS[2]
    crlf = target.read_bytes().replace(b"\n", b"\r\n")
    drifted = crlf.replace(b"version=0.76.2", b"version=0.76.3", 1)
    target.write_bytes(drifted)
    begin = b"# lgtm-ci-inline:begin install-verified-trivy"
    end = b"# lgtm-ci-inline:end install-verified-trivy"

    assert_that(sync.main(argv=[])).is_equal_to(0)

    synced = target.read_bytes()
    assert_that(synced.split(begin)[0]).is_equal_to(crlf.split(begin)[0])
    assert_that(synced.split(end)[-1]).is_equal_to(crlf.split(end)[-1])
    assert_that(synced).does_not_contain(b"version=0.76.3")
