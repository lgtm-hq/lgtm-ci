# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/workflows/sync_ai_review_matrix.py``.

The generator renders the auth defaults, egress allow-list and review steps of
``reusable-ai-review.yml`` and the capability table of
``docs/reusable-workflows.md`` from the shell capability matrix. ``--check``
prints a diff and exits 1 on drift without writing; without it, drifted files
are rewritten.
"""

from __future__ import annotations

import json
import re
import runpy
import shutil
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

SCRIPT = "scripts/ci/workflows/sync_ai_review_matrix.py"
PROJECT_ROOT = Path(__file__).resolve().parents[2]
# provider, transport, auth, default, slot, cli, cli-bare, egress
MATRIX = [
    ["acme", "api", "api_key", "yes", "ACME_API_KEY", "", "", "api.acme.test:443"],
    ["acme", "cli", "oauth", "yes", "ACME_OAUTH", "acme", "never", "o.acme.test:443"],
    ["acme", "cli", "api_key", "no", "ACME_API_KEY", "acme", "always", "c.test:443"],
    ["zeta", "cli", "oauth", "yes", "CODEX_AUTH_JSON", "codex", "", "z.test:443"],
]
WORKFLOW_TEXT = (
    "jobs:\n  review:\n    env:\n"
    "      # ai-review-defaults:begin\n      stale\n      # ai-review-defaults:end\n"
    "    steps:\n      - with:\n"
    "          # ai-review-egress:begin\n          stale\n"
    "          # ai-review-egress:end\n"
    "      # ai-review-steps:begin\n      stale\n      # ai-review-steps:end\n"
    "      - name: after\n"
)
DOC_TEXT = (
    "# Doc\n\n<!-- ai-review-capabilities:begin -->\nstale\n"
    "<!-- ai-review-capabilities:end -->\n\nTail ünïcode.\n"
)


@pytest.fixture(name="sync", scope="module")
def fixture_sync(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the generator once per module."""
    return load_script(SCRIPT)


@pytest.fixture(name="targets")
def fixture_targets(
    sync: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> tuple[Path, Path]:
    """Point the generator at copies of the real workflow and doc."""
    workflow = tmp_path / "reusable-ai-review.yml"
    doc = tmp_path / "reusable-workflows.md"
    shutil.copyfile(sync.WORKFLOW, workflow)
    shutil.copyfile(sync.DOC, doc)
    monkeypatch.setattr(sync, "WORKFLOW", workflow)
    monkeypatch.setattr(sync, "DOC", doc)
    return workflow, doc


@pytest.fixture(name="minimal")
def fixture_minimal(
    sync: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> tuple[Path, Path]:
    """Point the generator at small marker-only workflow and doc files."""
    workflow = tmp_path / "workflow.yml"
    doc = tmp_path / "doc.md"
    workflow.write_text(WORKFLOW_TEXT, encoding="utf-8")
    doc.write_text(DOC_TEXT, encoding="utf-8")
    monkeypatch.setattr(sync, "WORKFLOW", workflow)
    monkeypatch.setattr(sync, "DOC", doc)
    return workflow, doc


def run_main(
    sync: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    *args: str,
) -> int:
    """Run ``main`` with ``args`` as the command line and return its status."""
    monkeypatch.setattr(sys, "argv", ["sync_ai_review_matrix.py", *args])
    status: int = sync.main()
    return status


def block(text: str, name: str) -> str:
    """Return the text between the ``name`` begin and end markers."""
    match = re.search(
        rf"ai-review-{name}:begin[^\n]*\n(.*?)\n[^\n]*ai-review-{name}:end", text, re.S
    )
    assert match is not None
    return match.group(1)


def edit_inside_block(text: str, old: str, new: str) -> str:
    """Replace the first ``old`` that sits inside a generated block.

    Searching the whole file would hit hand-written text as soon as the same
    string appears above the block, and the edit would no longer be drift.
    """
    pattern = r"ai-review-[\w-]+:begin[^\n]*\n(.*?)\n[^\n]*ai-review-[\w-]+:end"
    for match in re.finditer(pattern, text, re.S):
        if old in match.group(1):
            edited = match.group(1).replace(old, new, 1)
            return text[: match.start(1)] + edited + text[match.end(1) :]
    raise AssertionError(f"{old!r} is not inside any generated block")


# --- main against the repository


def test_repository_blocks_are_current(
    sync: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Ported from tests/bats/integration/test_reusable_ai_review.bats."""
    assert_that(run_main(sync, monkeypatch, "--check")).is_equal_to(0)
    assert_that(capsys.readouterr().out).is_equal_to(
        "OK: AI review matrix blocks are current\n",
    )


def test_check_reports_drift_without_writing(
    sync: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    targets: tuple[Path, Path],
) -> None:
    """A hand edit inside a generated block fails ``--check`` with a diff."""
    _, doc = targets
    drifted = edit_inside_block(
        doc.read_text(encoding="utf-8"),
        "| — |",
        "| hand-edited |",
    )
    doc.write_text(drifted, encoding="utf-8")

    status = run_main(sync, monkeypatch, "--check")

    out = capsys.readouterr().out
    assert_that(status).is_equal_to(1)
    assert_that(out).contains(f"--- {doc}", "+++ generated", "hand-edited")
    assert_that(out).does_not_contain("OK:")
    assert_that(doc.read_text(encoding="utf-8")).is_equal_to(drifted)


def test_without_check_rewrites_drifted_files(
    sync: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    targets: tuple[Path, Path],
) -> None:
    """Without ``--check`` the generated text replaces the drift."""
    workflow, doc = targets
    original = workflow.read_text(encoding="utf-8")
    workflow.write_text(
        edit_inside_block(original, "Run OAuth AI review", "Renamed by hand"),
        encoding="utf-8",
    )
    doc_before = doc.read_text(encoding="utf-8")

    assert_that(run_main(sync, monkeypatch)).is_equal_to(0)

    assert_that(capsys.readouterr().out).contains("OK: AI review matrix")
    assert_that(workflow.read_text(encoding="utf-8")).is_equal_to(original)
    assert_that(doc.read_text(encoding="utf-8")).is_equal_to(doc_before)
    assert_that(run_main(sync, monkeypatch, "--check")).is_equal_to(0)


def test_oauth_step_has_no_api_key_slots(sync: ModuleType) -> None:
    """Ported from tests/bats/integration/test_reusable_ai_review.bats."""
    workflow = sync.rendered(sync.matrix_rows())[sync.WORKFLOW]
    steps = block(workflow, "steps")
    oauth = steps[steps.index("- name: Run OAuth AI review") :]

    assert_that(oauth).contains("CODEX_AUTH_JSON:", "CLAUDE_CODE_OAUTH_TOKEN:")
    for slot in ("CODEX_API_KEY:", "OPENAI_API_KEY:", "ANTHROPIC_API_KEY:"):
        assert_that(oauth).does_not_contain(slot)


def test_runs_as_a_script(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Run as ``__main__`` with ``--check``, a current repository exits 0."""
    monkeypatch.setattr(sys, "argv", ["sync_ai_review_matrix.py", "--check"])

    with pytest.raises(SystemExit) as exc_info:
        runpy.run_path(str(PROJECT_ROOT / SCRIPT), run_name="__main__")

    assert_that(exc_info.value.code).is_equal_to(0)
    assert_that(capsys.readouterr().out).contains("OK:")


# --- rendered with a synthetic matrix


def test_rendered_writes_every_block(
    sync: ModuleType,
    minimal: tuple[Path, Path],
) -> None:
    """Every marker gets a body; text outside the markers is kept."""
    workflow, doc = minimal

    result = sync.rendered(MATRIX)

    assert_that(result).contains_only(workflow, doc)
    text = result[workflow]
    assert_that(text).does_not_contain("stale").ends_with("      - name: after\n")
    assert_that(block(text, "defaults")).starts_with("      AI_REVIEW_AUTH: >-\n")
    assert_that(block(text, "egress")).starts_with(
        "          allowed-endpoints: >-\n",
    )
    assert_that(block(text, "steps")).starts_with("      - name: Run AI review\n")
    assert_that(result[doc]).starts_with("# Doc\n\n").ends_with("\nTail ünïcode.\n")


def test_default_auth_comes_from_default_rows(
    sync: ModuleType,
    minimal: tuple[Path, Path],
) -> None:
    """Only rows marked default feed the provider/transport auth lookup."""
    workflow, _ = minimal

    defaults = block(sync.rendered(MATRIX)[workflow], "defaults")

    expected = {"acme/api": "api_key", "acme/cli": "oauth", "zeta/cli": "oauth"}
    assert_that(" ".join(defaults.split())).contains(
        f"fromJSON('{json.dumps(expected)}')",
        "AI_REVIEW_AUTH_SOURCE: >-",
    )


def test_egress_adds_each_tuple_endpoints_behind_its_condition(
    sync: ModuleType,
    minimal: tuple[Path, Path],
) -> None:
    """Each row's endpoints are allowed only when its tuple is selected."""
    workflow, _ = minimal

    egress = " ".join(block(sync.rendered(MATRIX)[workflow], "egress").split())

    for row in MATRIX:
        assert_that(egress).contains(
            f"{sync.condition(row, 'env')} && '{row[7]}' || ''",
        )


def test_capability_table(sync: ModuleType, minimal: tuple[Path, Path]) -> None:
    """The doc table shows defaults, bindings, cli-bare and CLI per row."""
    _, doc = minimal

    table = block(sync.rendered(MATRIX)[doc], "capabilities").splitlines()

    assert_that(table[0]).starts_with("| Provider | Transport | Auth | Default |")
    never, always = "`LINTRO_CLI_BARE=never`", "`LINTRO_CLI_BARE=always`"
    assert_that(table[2:]).is_equal_to(
        [
            "| acme | api | api_key | yes | `ACME_API_KEY` | — |",
            "| acme | cli | oauth | yes | `ACME_OAUTH` + " + never + " | acme |",
            "| acme | cli | api_key | — | `ACME_API_KEY` + " + always + " | acme |",
            "| zeta | cli | oauth | yes | `CODEX_AUTH_JSON` → isolated"
            " `CODEX_HOME/auth.json` | codex |",
        ],
    )


def test_missing_marker_fails(
    sync: ModuleType,
    minimal: tuple[Path, Path],
) -> None:
    """A workflow without its markers is an error, not a silent no-op.

    The error is an unhandled ``ValueError`` today; a clean non-zero exit
    would be just as acceptable.
    """
    workflow, _ = minimal
    workflow.write_text("jobs: {}\n", encoding="utf-8")

    with pytest.raises((ValueError, SystemExit)) as exc_info:
        sync.rendered(MATRIX)

    if isinstance(exc_info.value, SystemExit):
        assert_that(exc_info.value.code).is_not_equal_to(0)


# --- review_steps


def test_review_steps_split_slots_by_auth(sync: ModuleType) -> None:
    """API-key slots go to the API-key step, OAuth slots to the OAuth step."""
    steps = sync.review_steps(MATRIX)
    api_step, oauth_step = steps.split("      - name: Run OAuth AI review\n")

    assert_that(api_step).contains("id: review\n", "auth == 'api_key'")
    assert_that(api_step).contains("ACME_API_KEY: >-").does_not_contain("ACME_OAUTH")
    assert_that(oauth_step).contains("id: review-oauth\n", "auth == 'oauth'")
    assert_that(oauth_step).contains("ACME_OAUTH: >-", "CODEX_AUTH_JSON: >-")
    assert_that(oauth_step).does_not_contain("ACME_API_KEY")
    runner = "run: python3 -I .lgtm-ci-tooling/scripts/ci/"
    assert_that(steps.count(runner)).is_equal_to(2)


def test_shared_slot_is_bound_once_for_every_tuple(sync: ModuleType) -> None:
    """A slot used by two tuples is one env entry gated on either tuple."""
    api_step = sync.review_steps(MATRIX).split("Run OAuth AI review")[0]

    assert_that(api_step.count("ACME_API_KEY: >-")).is_equal_to(1)
    gate = " ".join(api_step.split("ACME_API_KEY: >-")[1].split())
    for row in (MATRIX[0], MATRIX[2]):
        assert_that(gate).contains(f"({sync.condition(row, 'steps')})")
    assert_that(gate).contains("&& secrets.ACME_API_KEY || ''")


# --- small helpers


def test_expression_wraps_without_evaluating(sync: ModuleType) -> None:
    """The value is wrapped in a literal ``${{ }}``."""
    assert_that(sync.expression("inputs.x")).is_equal_to("${{ inputs.x }}")


@pytest.mark.parametrize(
    ("context", "expected"),
    [
        (
            "env",
            "env.AI_REVIEW_PROVIDER == 'p' && env.AI_REVIEW_TRANSPORT == 't'"
            " && env.AI_REVIEW_AUTH == 'a'",
        ),
        (
            "steps",
            "steps.resolve.outputs.provider == 'p'"
            " && steps.resolve.outputs.transport == 't'"
            " && steps.resolve.outputs.auth == 'a'",
        ),
    ],
)
def test_condition(sync: ModuleType, context: str, expected: str) -> None:
    """The tuple is matched in the env or in the resolve step outputs."""
    assert_that(sync.condition(["p", "t", "a", "yes", "S"], context)).is_equal_to(
        expected,
    )


def test_folded_wraps_long_values_without_splitting_words(sync: ModuleType) -> None:
    """A folded scalar keeps each word whole and the value intact."""
    words = [f"word-{index}" for index in range(40)] + ["x" * 120]
    value = " ".join(words)

    rendered = sync.folded(key="k", value=value, indent=4)

    head, *body = rendered.split("\n")
    assert_that(head).is_equal_to("    k: >-")
    assert_that(len(body)).is_greater_than(1)
    for line in body:
        assert_that(line).starts_with("      ")
    assert_that(" ".join(line.strip() for line in body)).is_equal_to(value)
    assert_that(body[-1].strip()).is_equal_to("x" * 120)


def test_replace_block_keeps_the_end_marker_indent(sync: ModuleType) -> None:
    """The end marker is re-indented like the begin marker."""
    text = "a\n    # ai-review-x:begin\n    old\n# ai-review-x:end\nz\n"

    result = sync.replace_block(text, "x", "    new")

    assert_that(result).is_equal_to(
        "a\n    # ai-review-x:begin\n    new\n    # ai-review-x:end\nz\n",
    )
