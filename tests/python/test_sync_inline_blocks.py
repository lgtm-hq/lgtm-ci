# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/bootstrap/sync_inline_blocks.py`` (#1450).

The repository check here is what fails CI when an inline copy drifts from its
source script. The installer's behaviour is exercised in
``tests/bats/contract/test_trivy_acquisition.bats``; the tooling-ref guard's in
``tests/bats/unit/actions/test_check_tooling_ref_divergence.bats`` (source) and
``tests/bats/integration/test_tooling_ref_divergence_guard.bats`` (every copy);
the App credential selector's in
``tests/bats/unit/release/test_select_app_credential.bats`` (source) and
``tests/bats/integration/test_release_app_credential_select.bats`` (every
copy); the hook tooling extractor's in
``tests/bats/unit/release/test_verify_extract_hook_tooling.bats``; the
harden-runner agent check's in
``tests/bats/unit/security/test_verify_harden_runner_agent.bats``, with its
placement pinned by ``tests/python/test_harden_runner_verify_contract.py``.
"""

from __future__ import annotations

import shutil
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

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
GUARD = "refuse-diverging-tooling-ref"
GUARD_STEP = "Refuse a diverging tooling-ref"
GUARD_WORKFLOW = "reusable-sbom.yml"
APP = "select-app-credential"
APP_STEP = "Select GitHub App credential"
EXTRACT = "verify-extract-hook-tooling"
EXTRACT_STEP = "Verify and extract lgtm-ci tooling"
# The version-pr job's copy restores the tooling it moved out before PR
# creation (#1622).
RESTORE_STEP = "Restore tooling for post-PR steps"
RELEASE = "reusable-release-version-pr.yml"
VERIFY = "verify-harden-runner-agent"
VERIFY_STEP = "Verify harden-runner agent"
RECHECK = "recheck-harden-runner-agent"
RECHECK_STEP = "Recheck harden-runner agent"
# The recheck is every verified job's last step, so its end marker is the
# file's last one.
RECHECK_END = f"# lgtm-ci-inline:end {RECHECK}"
PRESET = "fail-unknown-egress-preset"
PRESET_STEP = "Fail on unknown egress-preset"


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
    """Copy the marked workflows to scratch dirs and point the sync at them."""
    examples = tmp_path / "examples"
    examples.mkdir()
    for source, target in (
        (sync.DEFAULT_WORKFLOWS_DIR, tmp_path),
        (sync.DEFAULT_EXAMPLES_DIR, examples),
    ):
        for path in source.glob("*.y*ml"):
            if "# lgtm-ci-inline:begin " in path.read_text(encoding="utf-8"):
                shutil.copy(path, target / path.name)
    monkeypatch.setenv("WORKFLOWS_DIR", str(tmp_path))
    monkeypatch.setenv("EXAMPLES_DIR", str(examples))
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
    monkeypatch.delenv("EXAMPLES_DIR", raising=False)
    assert_that(sync.main(argv=["--check"])).is_equal_to(0)


def _step_runs(sync: ModuleType, step_name: str | tuple[str, ...]) -> list[str]:
    """Return the ``run:`` of every workflow or example step with this name.

    ``"<name> before <step>"`` counts too: the pre-publish copies of the
    recheck (#1551) are named after the step they guard. A tuple names every
    step that carries the block.
    """
    names = (step_name,) if isinstance(step_name, str) else step_name
    prefixes = tuple(f"{name} before " for name in names)
    runs = []
    paths = [
        *sorted(sync.DEFAULT_WORKFLOWS_DIR.glob("*.y*ml")),
        *sorted(sync.DEFAULT_EXAMPLES_DIR.glob("*.y*ml")),
    ]
    for path in paths:
        workflow = yaml.safe_load(path.read_text(encoding="utf-8"))
        for job in (workflow.get("jobs") or {}).values():
            for step in job.get("steps") or []:
                name = str(step.get("name", ""))
                if name in names or name.startswith(prefixes):
                    runs.append(step["run"])
    return runs


@pytest.mark.parametrize(
    ("block_id", "step_name"),
    [
        (TRIVY, "Install verified Trivy"),
        (GUARD, GUARD_STEP),
        (APP, APP_STEP),
        (EXTRACT, (EXTRACT_STEP, RESTORE_STEP)),
        (VERIFY, VERIFY_STEP),
        (RECHECK, RECHECK_STEP),
        (PRESET, PRESET_STEP),
    ],
    ids=[TRIVY, GUARD, APP, EXTRACT, VERIFY, RECHECK, PRESET],
)
def test_every_generated_step_is_the_marked_source_body(
    sync: ModuleType,
    block_id: str,
    step_name: str | tuple[str, ...],
) -> None:
    """Each step of a generated block is markers, the header and the source body."""
    body = sync.generated_body(block_id)
    begin = f"# lgtm-ci-inline:begin {block_id}"
    end = f"# lgtm-ci-inline:end {block_id}"
    expected = "\n".join([begin, *body, end]) + "\n"
    runs = _step_runs(sync, step_name)
    assert_that(runs).is_length(sync.BLOCKS[block_id].copies)
    for run in runs:
        assert_that(run).is_equal_to(expected)


def test_guard_body_is_workflow_owned(sync: ModuleType) -> None:
    """The guard body never runs a script from the tree it judges."""
    body = sync.source_body(GUARD)
    joined = "\n".join(body)
    assert_that(body[0]).starts_with("# Workflow-owned")
    assert_that(joined).does_not_contain("SPDX").does_not_contain("#!/")
    assert_that(joined).does_not_contain("check-tooling-ref-divergence.sh")
    assert_that(joined).does_not_contain("exec ").does_not_contain("source ")
    assert_that(body[-1]).is_equal_to("exit 1")


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


def test_check_names_a_drifted_guard_copy(
    sync: ModuleType,
    scratch: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A hand-edited guard copy fails the check and is named."""
    hatch = '"${ALLOW_DIVERGENCE:-}" == '
    _edit(scratch / GUARD_WORKFLOW, f'{hatch}"true"', f'{hatch}"yes"')
    assert_that(sync.main(argv=["--check"])).is_equal_to(1)
    err = capsys.readouterr().err
    assert_that(err).contains("differs from its source", GUARD_WORKFLOW)
    assert_that(sync.main(argv=[])).is_equal_to(0)
    original = (sync.DEFAULT_WORKFLOWS_DIR / GUARD_WORKFLOW).read_text()
    assert_that((scratch / GUARD_WORKFLOW).read_text()).is_equal_to(original)


def test_check_fails_when_a_guard_marker_pair_is_removed(
    sync: ModuleType,
    scratch: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Dropping one guard copy's markers leaves too few copies."""
    target = scratch / GUARD_WORKFLOW
    _edit(target, f"          # lgtm-ci-inline:begin {GUARD}\n", "")
    _edit(target, f"          # lgtm-ci-inline:end {GUARD}\n", "")
    assert_that(sync.main(argv=["--check"])).is_equal_to(1)
    err = capsys.readouterr().err
    assert_that(err).contains(f"expected 12 copies of {GUARD}, found 11")


@pytest.mark.parametrize(
    "case",
    [
        (APP, "set RELEASE_APP_CLIENT_ID or RELEASE_APP_ID", "set RELEASE_APP_ID"),
        (EXTRACT, "--no-same-owner ", ""),
    ],
    ids=[APP, EXTRACT],
)
def test_check_names_a_drifted_release_copy(
    sync: ModuleType,
    scratch: Path,
    capsys: pytest.CaptureFixture[str],
    case: tuple[str, str, str],
) -> None:
    """A hand-edited release copy fails the check and sync restores it."""
    block_id, old, new = case
    assert_that("\n".join(sync.source_body(block_id))).contains(old)
    _edit(scratch / RELEASE, old, new)
    assert_that(sync.main(argv=["--check"])).is_equal_to(1)
    err = capsys.readouterr().err
    assert_that(err).contains("differs from its source", RELEASE)
    assert_that(sync.main(argv=[])).is_equal_to(0)
    original = (sync.DEFAULT_WORKFLOWS_DIR / RELEASE).read_text()
    assert_that((scratch / RELEASE).read_text()).is_equal_to(original)


@pytest.mark.parametrize(
    ("block_id", "copies"),
    [(APP, 3), (EXTRACT, 2)],
    ids=[APP, EXTRACT],
)
def test_check_fails_when_a_release_marker_pair_is_removed(
    sync: ModuleType,
    scratch: Path,
    capsys: pytest.CaptureFixture[str],
    block_id: str,
    copies: int,
) -> None:
    """Dropping one release copy's markers leaves too few copies."""
    assert_that(sync.BLOCKS[block_id].copies).is_equal_to(copies)
    target = scratch / RELEASE
    _edit(target, f"          # lgtm-ci-inline:begin {block_id}\n", "")
    _edit(target, f"          # lgtm-ci-inline:end {block_id}\n", "")
    assert_that(sync.main(argv=["--check"])).is_equal_to(1)
    err = capsys.readouterr().err
    assert_that(err).contains(
        f"expected {copies} copies of {block_id}, found {copies - 1}",
    )


@pytest.mark.parametrize(
    "case",
    [
        # The file's last end marker (the edit hits the last occurrence): an
        # earlier one is reported as the next begin inside the open block.
        (f"          {RECHECK_END}\n", "", "has no end marker"),
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
    target = scratch / DOCKER_WORKFLOWS[2]
    text = target.read_text(encoding="utf-8")
    assert_that(text).contains(old)
    head, _, tail = text.rpartition(old)
    target.write_text(head + new + tail, encoding="utf-8")
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


TOOLING_APP_FLAGS = "tooling-app-flags"
TOOLING_APP_MINT = "tooling-app-mint"
TOOLING_APP_PILOT = "reusable-semantic-pr-title.yml"


def _minting_jobs(sync: ModuleType) -> list[dict[str, Any]]:
    """Return every workflow job that has a ``tooling-app-token`` step."""
    jobs = []
    for path in sorted(sync.DEFAULT_WORKFLOWS_DIR.glob("*.y*ml")):
        text = path.read_text(encoding="utf-8")
        if "tooling-app-token" not in text:
            continue
        for job in (yaml.safe_load(text).get("jobs") or {}).values():
            ids = [step.get("id") for step in job.get("steps") or []]
            if "tooling-app-token" in ids:
                jobs.append(job)
    return jobs


def test_tooling_app_blocks_are_workflow_yaml(sync: ModuleType) -> None:
    """The App blocks are YAML: job env entries and two whole steps (#1622)."""
    flags = yaml.safe_load("\n".join(sync.source_body(TOOLING_APP_FLAGS)))
    steps = yaml.safe_load("\n".join(sync.source_body(TOOLING_APP_MINT)))
    assert_that(sorted(flags)).is_equal_to(
        ["LGTM_CI_TOOLING_APP_ID_SET", "LGTM_CI_TOOLING_APP_KEY_SET"],
    )
    assert_that([step["id"] for step in steps]).is_equal_to(
        ["tooling-app-target", "tooling-app-token"],
    )
    jobs = _minting_jobs(sync)
    assert_that(jobs).is_length(sync.BLOCKS[TOOLING_APP_MINT].copies)
    assert_that(sync.BLOCKS[TOOLING_APP_FLAGS].copies).is_equal_to(
        sync.BLOCKS[TOOLING_APP_MINT].copies,
    )
    ids = ("tooling-app-target", "tooling-app-token")
    for job in jobs:
        for name, value in flags.items():
            assert_that(job["env"]).contains_entry({name: value})
        found = [step for step in job["steps"] if step.get("id") in ids]
        assert_that(found).is_equal_to(steps)


@pytest.mark.parametrize(
    ("block_id", "indent"),
    [(TOOLING_APP_FLAGS, "      "), (TOOLING_APP_MINT, "      ")],
    ids=[TOOLING_APP_FLAGS, TOOLING_APP_MINT],
)
def test_check_fails_when_a_tooling_app_marker_pair_is_removed(
    sync: ModuleType,
    scratch: Path,
    capsys: pytest.CaptureFixture[str],
    block_id: str,
    indent: str,
) -> None:
    """Dropping the pilot's markers leaves one copy too few (#1622)."""
    # The expected count is the number of minting jobs, not a second number
    # kept by hand: each rollout slice raises only `copies`.
    copies = sync.BLOCKS[block_id].copies
    assert_that(copies).is_equal_to(len(_minting_jobs(sync)))
    target = scratch / TOOLING_APP_PILOT
    _edit(target, f"{indent}# lgtm-ci-inline:begin {block_id}\n", "")
    _edit(target, f"{indent}# lgtm-ci-inline:end {block_id}\n", "")
    assert_that(sync.main(argv=["--check"])).is_equal_to(1)
    assert_that(capsys.readouterr().err).contains(
        f"expected {copies} copies of {block_id}, found {copies - 1}",
    )


def test_check_names_a_widened_mint(
    sync: ModuleType,
    scratch: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A hand-widened mint step is drift from its source (#1622)."""
    _edit(
        scratch / TOOLING_APP_PILOT,
        "          permission-contents: read\n",
        "          permission-contents: write\n",
    )
    assert_that(sync.main(argv=["--check"])).is_equal_to(1)
    err = capsys.readouterr().err
    assert_that(err).contains("differs from its source", TOOLING_APP_PILOT)


# Headers (#1624): every copy says it is generated, names its source and why
# it is inline.


def test_every_block_gives_a_reason(sync: ModuleType) -> None:
    """A block without a reason could not explain why it is inline."""
    reasons = {block_id: block.reason for block_id, block in sync.BLOCKS.items()}
    missing = [block_id for block_id, reason in reasons.items() if not reason.strip()]
    assert_that(missing).is_empty()


@pytest.mark.parametrize("block_id", [TRIVY, GUARD, PRESET, "tooling-app-mint"])
def test_header_names_source_and_reason(sync: ModuleType, block_id: str) -> None:
    """The header is comment lines naming the source, the generator and the reason."""
    header = sync.header_lines(block_id)
    text = " ".join(line.removeprefix("# ") for line in header)
    block = sync.BLOCKS[block_id]
    assert_that(header).is_not_empty()
    assert_that(all(line.startswith("# ") for line in header)).is_true()
    assert_that(all(len(line) <= sync.HEADER_WIDTH for line in header)).is_true()
    generated = f"Generated from {block.script} by sync_inline_blocks.py"
    assert_that(text).starts_with(generated)
    assert_that(text).contains("edit the source, not this copy")
    assert_that(text).ends_with(f"Inline because {block.reason}.")


def test_generated_body_is_header_then_source(sync: ModuleType) -> None:
    """What the generator writes is the header followed by the source body."""
    assert_that(sync.generated_body(PRESET)).is_equal_to(
        [*sync.header_lines(PRESET), *sync.source_body(PRESET)],
    )


def test_every_copy_in_the_tree_starts_with_its_header(sync: ModuleType) -> None:
    """Each begin marker in every workflow is followed by the block's header."""
    missing: list[str] = []
    copies = 0
    for directory in (sync.DEFAULT_WORKFLOWS_DIR, sync.DEFAULT_EXAMPLES_DIR):
        for path in sorted(directory.glob("*.y*ml")):
            lines = path.read_text(encoding="utf-8").splitlines()
            for index, line in enumerate(lines):
                match = sync.MARKER.match(line)
                if match is None or match["kind"] != "begin":
                    continue
                copies += 1
                header = sync.header_lines(match["id"])
                after = lines[index + 1 : index + 1 + len(header)]
                found = [text.strip() for text in after]
                if found != header:
                    missing.append(f"{path.name}:{index + 1}")
    assert_that(copies).is_equal_to(sum(block.copies for block in sync.BLOCKS.values()))
    assert_that(missing).is_empty()


def test_check_names_a_stale_header(
    sync: ModuleType,
    scratch: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A copy whose header was edited by hand fails --check, which names it.

    Without ``--check`` the generator writes the header back.
    """
    target = next(
        path
        for path in sorted(scratch.glob("*.y*ml"))
        if f"# lgtm-ci-inline:begin {PRESET}" in path.read_text(encoding="utf-8")
    )
    committed = target.read_text(encoding="utf-8")
    _edit(
        target,
        "# Generated from scripts/ci/bootstrap/fail-unknown",
        "# Hand-written from scripts/ci/bootstrap/fail-unknown",
    )
    assert_that(sync.main(argv=["--check"])).is_equal_to(1)
    err = capsys.readouterr().err
    assert_that(err).contains("differs from its source", target.name)
    assert_that(sync.main(argv=[])).is_equal_to(0)
    assert_that(target.read_text(encoding="utf-8")).is_equal_to(committed)
