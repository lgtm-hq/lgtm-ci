# SPDX-License-Identifier: MIT
"""Unit tests for ``scripts/ci/bootstrap/render-egress-profile.py`` (#1597).

Small fixture workflows exercise each rewrite of the audit and none profiles
and the command line: marker, stale files, refusals and symlink safety.
``test_egress_profile_contract.py`` renders the real tree.
"""

from __future__ import annotations

import json
import os
import shutil
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
import yaml
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/bootstrap/render-egress-profile.py"
ROOT = Path(__file__).resolve().parents[2]
MARKER = ".lgtm-ci-egress-profile.json"

# One reusable workflow job as the source writes it: an input, the harden
# step, the verify step, runner policy, a pre-publish recheck, the publish,
# the end recheck; then a job that calls another reusable.
SOURCE = """\
on:
  workflow_call:
    inputs:
      egress-policy:
        description: "harden-runner egress policy (block only; audit rejected)"
        required: false
        type: string
        default: "block"
      egress-preset:
        description: >-
          Selected at job start, so it is enforced (#913).
        type: string
        default: "github-tooling"
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - name: Harden runner
        uses: step-security/harden-runner@0000000000000000000000000000000000000000
        with:
          egress-policy: ${{ inputs.egress-policy }}
      - name: Verify harden-runner agent
        id: verify-harden-runner
        # Every runner (#1203): rejects non-block egress; VERIFY_COMMENT_TAIL
        shell: bash
        env:
          EGRESS_POLICY: ${{ inputs.egress-policy }}
          REPOSITORY_PRIVATE: ${{ github.event.repository.private }}
        run: |
          # lgtm-ci-inline:begin verify-harden-runner-agent
          stale verify body
          # lgtm-ci-inline:end verify-harden-runner-agent
      - name: Fail on unknown egress-preset
        if: inputs.egress-preset == 'nope'
        run: exit 1
      - name: Validate runner policy
        uses: ./.lgtm-ci-tooling/.github/actions/validate-runner-policy
        with:
          tier: strict
          egress-policy: block
      # Publishes the package.
      - name: Recheck harden-runner agent before Publish
        # Pre-publish tripwire (#1551): a stopped agent skips the next step.
        if: ${{ success() && steps.verify-harden-runner.outcome == 'success' }}
        shell: bash
        run: |
          # lgtm-ci-inline:begin recheck-harden-runner-agent

          stale recheck body
          # lgtm-ci-inline:end recheck-harden-runner-agent
      - name: Publish
        if: inputs.publish
        run: echo publish
      - name: Summarize blocked egress
        if: ${{ failure() }}
        env:
          STEP: summarize-blocked-egress
        run: echo scan
      - name: Recheck harden-runner agent
        if: ${{ !cancelled() && steps.verify-harden-runner.outcome == 'success' }}
        shell: bash
        run: |
          # lgtm-ci-inline:begin recheck-harden-runner-agent
          stale recheck body
          # lgtm-ci-inline:end recheck-harden-runner-agent

  call:
    uses: ./.github/workflows/other.yml
    with:
      egress-policy: block
""".replace("VERIFY_COMMENT_TAIL", "checks the agent on hosted Linux.")


@pytest.fixture(name="render")
def fixture_render(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the renderer without running it."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="bodies")
def fixture_bodies(render: ModuleType) -> dict[str, list[str]]:
    """Inline bodies as the renderer reads them from this repository."""
    bodies: dict[str, list[str]] = render.REWRITE.inline_bodies()
    return bodies


def _run(
    render: ModuleType,
    bodies: dict[str, list[str]],
    text: str,
    profile: str,
) -> str:
    rendered, _counts = render.REWRITE.rewrite(text, render.Profile(profile), bodies)
    return str(rendered)


def test_audit_rewrites_one_job(
    render: ModuleType,
    bodies: dict[str, list[str]],
) -> None:
    """Notice in place of verify, rechecks and summary gone, policy set to audit."""
    rendered, counts = render.REWRITE.rewrite(SOURCE, render.Profile.AUDIT, bodies)
    assert_that(counts.notices).is_equal_to(1)
    assert_that(counts.removed).is_equal_to(
        {"recheck": 2, "advice assumes blocked egress": 1},
    )
    document = yaml.safe_load(rendered)
    steps = document["jobs"]["publish"]["steps"]
    assert_that([s["name"] for s in steps]).is_equal_to(
        [
            "Harden runner",
            "Report egress not enforced",
            "Fail on unknown egress-preset",
            "Validate runner policy",
            "Publish",
        ],
    )
    notice = steps[1]
    assert_that(notice["id"]).is_equal_to("verify-harden-runner")
    assert_that(notice["env"]).is_equal_to(
        {
            "EGRESS_PROFILE": "audit",
            "EGRESS_POLICY": "${{ inputs.egress-policy }}",
            "REPOSITORY_PRIVATE": "${{ github.event.repository.private }}",
        },
    )
    assert_that(notice["run"]).contains("\n".join(bodies["egress-profile-notice"]))
    policy = {"tier": "permissive", "egress-policy": "audit"}
    assert_that(steps[3]["with"]).is_equal_to(policy)
    inputs = document[True]["workflow_call"]["inputs"]
    assert_that(inputs["egress-policy"]["default"]).is_equal_to("audit")
    assert_that(inputs["egress-policy"]["description"]).ends_with(
        "(audit only in this generated copy)",
    )
    assert_that(inputs["egress-preset"]["description"]).contains(
        "enforced only in a block-profile copy (#913)",
    )
    call = document["jobs"]["call"]["with"]
    assert_that(call).is_equal_to({"egress-policy": "audit"})
    assert_that(rendered.splitlines()[0]).contains("egress profile audit")


def test_none_rewrites_one_job(
    render: ModuleType,
    bodies: dict[str, list[str]],
) -> None:
    """harden-runner and its configuration steps go; the notice stays."""
    rendered, counts = render.REWRITE.rewrite(SOURCE, render.Profile.NONE, bodies)
    assert_that(counts.notices).is_equal_to(1)
    assert_that(sum((counts.removed or {}).values())).is_equal_to(6)
    document = yaml.safe_load(rendered)
    steps = document["jobs"]["publish"]["steps"]
    assert_that([s["name"] for s in steps]).is_equal_to(
        ["Report egress not enforced", "Publish"],
    )
    assert_that(steps[0]["env"]).is_equal_to(
        {
            "EGRESS_PROFILE": "none",
            "EGRESS_POLICY": "none",
            "REPOSITORY_PRIVATE": "${{ github.event.repository.private }}",
        },
    )
    inputs = document[True]["workflow_call"]["inputs"]
    assert_that(inputs["egress-policy"]["default"]).is_equal_to("none")
    for name in ("egress-policy", "egress-preset"):
        assert_that(inputs[name]["description"]).starts_with("Ignored in this copy")
        assert_that(inputs[name]["description"]).does_not_contain("enforced")
    assert_that(document["jobs"]["call"]["with"]).is_equal_to({"egress-policy": "none"})
    assert_that(rendered).does_not_contain("step-security/harden-runner")


@pytest.mark.parametrize("profile", ["audit", "none"])
def test_rewrite_keeps_comments_layout_and_the_1552_env(
    render: ModuleType,
    bodies: dict[str, list[str]],
    profile: str,
) -> None:
    """The publish comment, the blank line before a job and REPOSITORY_PRIVATE stay."""
    rendered = _run(render, bodies, SOURCE, profile)
    assert_that(rendered).contains("      # Publishes the package.\n")
    assert_that(rendered).contains("        run: echo publish\n\n  call:\n")
    assert_that(rendered).does_not_contain("Recheck")
    assert_that(rendered).contains(
        "          REPOSITORY_PRIVATE: ${{ github.event.repository.private }}\n",
    )


@pytest.mark.parametrize("profile", ["audit", "none"])
def test_rewrite_keeps_crlf_line_endings(
    render: ModuleType,
    bodies: dict[str, list[str]],
    profile: str,
) -> None:
    """A CRLF source yields CRLF output, header and generated body included."""
    rendered = _run(render, bodies, SOURCE.replace("\n", "\r\n"), profile)
    assert_that(rendered.replace("\r\n", "")).does_not_contain("\n")


def test_example_comment_points_at_the_notice_source(
    render: ModuleType,
    bodies: dict[str, list[str]],
) -> None:
    """A caller-owned example's provenance comment names the notice script."""
    text = SOURCE.replace(
        "        shell: bash\n        env:\n          EGRESS_POLICY: $",
        "        # Generated from scripts/ci/bootstrap/verify-harden-runner-agent.sh\n"
        "        shell: bash\n        env:\n          EGRESS_POLICY: $",
        1,
    )
    rendered = _run(render, bodies, text, "audit")
    assert_that(rendered).contains(
        "# Generated from scripts/ci/bootstrap/egress-profile-notice.sh",
    )


def test_literal_block_policy_becomes_audit(
    render: ModuleType,
    bodies: dict[str, list[str]],
) -> None:
    """Literal ``block`` in a harden step and in the verify env both change."""
    text = SOURCE.replace("${{ inputs.egress-policy }}", "block")
    document = yaml.safe_load(_run(render, bodies, text, "audit"))
    steps = document["jobs"]["publish"]["steps"]
    assert_that(steps[0]["with"]).is_equal_to({"egress-policy": "audit"})
    assert_that(steps[1]["env"]["EGRESS_POLICY"]).is_equal_to("audit")


@pytest.mark.parametrize("profile", ["block", "audit", "none"])
@pytest.mark.parametrize(
    "spelling",
    [
        "egress-policy: 'block'",
        'egress-policy: "block"',
        "egress-policy: block # comment",
        "egress-policy: ${{ 'block' }}",
        "egress-policy: blocked",
    ],
)
def test_unsupported_policy_spellings_fail_with_file_and_line(
    render: ModuleType,
    bodies: dict[str, list[str]],
    profile: str,
    spelling: str,
) -> None:
    """A value the rewrite does not recognise fails, naming file and line."""
    text = SOURCE.replace(
        "    with:\n      egress-policy: block\n", f"    with:\n      {spelling}\n"
    )
    with pytest.raises(render.ProfileError, match=r"^w\.yml:\d+: egress-policy "):
        render.REWRITE.rewrite(text, render.Profile(profile), bodies, "w.yml")


@pytest.mark.parametrize("profile", ["block", "audit", "none"])
def test_flow_mapping_policy_fails(
    render: ModuleType,
    bodies: dict[str, list[str]],
    profile: str,
) -> None:
    """``with: {egress-policy: block}`` is refused, not passed through."""
    text = SOURCE.replace(
        "    with:\n      egress-policy: block\n",
        "    with: {egress-policy: block}\n",
    )
    expected = r"^w\.yml:\d+: egress-policy in a flow"
    with pytest.raises(render.ProfileError, match=expected):
        render.REWRITE.rewrite(text, render.Profile(profile), bodies, "w.yml")


@pytest.mark.parametrize("profile", ["audit", "none"])
def test_single_quoted_input_default_fails(
    render: ModuleType,
    bodies: dict[str, list[str]],
    profile: str,
) -> None:
    """``default: 'block'`` is not rewritten, so the check refuses it."""
    text = SOURCE.replace('default: "block"', "default: 'block'")
    with pytest.raises(render.ProfileError, match=r"^w\.yml:9: egress-policy default"):
        render.REWRITE.rewrite(text, render.Profile(profile), bodies, "w.yml")


def test_rejects_a_verify_step_without_markers(
    render: ModuleType,
    bodies: dict[str, list[str]],
) -> None:
    """A verify step the rewrite does not recognise is an error, not a guess."""
    text = SOURCE.replace("# lgtm-ci-inline:begin verify-harden-runner-agent", "x")
    with pytest.raises(render.ProfileError, match="lacks exactly one"):
        render.REWRITE.rewrite(text, render.Profile.AUDIT, bodies)


def test_rejects_a_check_block_outside_its_step(
    render: ModuleType,
    bodies: dict[str, list[str]],
) -> None:
    """A recheck body under another step name would survive; refuse it."""
    recheck = "- name: Recheck harden-runner agent\n"
    text = SOURCE.replace(recheck, "- name: Final check\n")
    with pytest.raises(render.ProfileError, match="recheck-harden-runner-agent"):
        render.REWRITE.rewrite(text, render.Profile.AUDIT, bodies)


def test_rejects_a_renamed_blocked_egress_summary(
    render: ModuleType,
    bodies: dict[str, list[str]],
) -> None:
    """The summary step under another name would still advise; refuse it."""
    text = SOURCE.replace("- name: Summarize blocked egress", "- name: Explain failure")
    with pytest.raises(render.ProfileError, match="summarize-blocked-egress"):
        render.REWRITE.rewrite(text, render.Profile.AUDIT, bodies)


def test_leaves_other_text_alone(
    render: ModuleType,
    bodies: dict[str, list[str]],
) -> None:
    """``block`` in prose, other tiers and other defaults are not touched."""
    text = (
        "jobs:\n"
        "  a:\n"
        "    steps:\n"
        "      # egress-policy: block stays in a comment\n"
        "      - name: Other\n"
        "        uses: ./x/other-action\n"
        "        with:\n"
        "          tier: strict\n"
        "      - name: Unrelated\n"
        "        run: |\n"
        "          echo 'egress-policy: block'\n"
        "        with:\n"
        "          default: block\n"
    )
    rendered = _run(render, bodies, text, "audit")
    assert_that(rendered.split("\n", 1)[1]).is_equal_to(text)


def test_block_profile_returns_the_text_unchanged(
    render: ModuleType,
    bodies: dict[str, list[str]],
) -> None:
    """The block profile is the source, byte for byte."""
    assert_that(_run(render, bodies, SOURCE, "block")).is_equal_to(SOURCE)


def test_extent_stops_before_trailing_blank_lines(render: ModuleType) -> None:
    """A node ends at its last indented line; following blanks stay outside."""
    lines = ["  - a\n", "    b\n", "\n", "    c\n", "\n", "  - d\n"]
    assert_that(render.REWRITE.extent(lines, 0)).is_equal_to(4)
    assert_that(render.REWRITE.extent(lines, 5)).is_equal_to(6)


# --- command line -------------------------------------------------------------


# The two steps only the ``none`` profile removes by name that SOURCE lacks; a
# tree render fails unless every such step is found somewhere (#1597).
DOCKER_SOURCE = """\
name: docker
on:
  workflow_call:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Refuse block egress on runners that cannot enforce it
        run: exit 1
      - name: Wait for hardener Docker readiness
        run: echo wait
      - name: Summarize blocked egress
        if: ${{ failure() }}
        run: echo scan
      - name: Build
        run: echo build
"""


def _scratch(tmp_path: Path) -> Path:
    """Copy the files the renderer reads into a scratch source tree."""
    root = tmp_path / "src"
    for relative in ("scripts/ci/bootstrap", ".github/actions/checkout-and-harden"):
        shutil.copytree(ROOT / relative, root / relative)
    (root / ".github/workflows").mkdir(parents=True)
    (root / ".github/workflows/w.yml").write_text(SOURCE, encoding="utf-8")
    (root / ".github/workflows/docker.yml").write_text(
        DOCKER_SOURCE,
        encoding="utf-8",
    )
    (root / ".github/actionlint.yaml").write_text("---\n", encoding="utf-8")
    (root / "examples/nested").mkdir(parents=True)
    (root / "examples/nested/caller.yml").write_text(SOURCE, encoding="utf-8")
    (root / "schemas").mkdir()
    (root / "scripts/ci/bootstrap/__pycache__").mkdir(exist_ok=True)
    (root / "scripts/ci/bootstrap/__pycache__/x.pyc").write_bytes(b"\0")
    return root


def test_a_step_removed_by_name_must_exist_somewhere(
    render: ModuleType,
    tmp_path: Path,
) -> None:
    """A renamed step would be kept silently, so the whole render fails."""
    root = _scratch(tmp_path)
    workflow = root / ".github/workflows/docker.yml"
    workflow.write_text(
        DOCKER_SOURCE.replace(
            "Wait for hardener Docker readiness",
            "Wait for the hardener",
        ),
        encoding="utf-8",
    )
    with pytest.raises(
        render.ProfileError,
        match="no step has the name: Wait for hardener Docker readiness",
    ):
        render.render_tree(render.Profile.NONE, root)
    # audit does not remove that step, so it does not need to find it.
    assert_that(render.render_tree(render.Profile.AUDIT, root)).contains_key(
        ".github/workflows/docker.yml",
    )


def test_rewrite_errors_name_the_file(
    render: ModuleType,
    bodies: dict[str, list[str]],
) -> None:
    """An error raised while rewriting steps carries the file path."""
    text = SOURCE.replace(
        "        env:\n          EGRESS_POLICY",
        "        with:\n          EGRESS_POLICY",
        1,
    )
    assert_that(text).is_not_equal_to(SOURCE)
    with pytest.raises(render.ProfileError, match=r"^some/file\.yml: "):
        render.REWRITE.rewrite(text, render.Profile.AUDIT, bodies, "some/file.yml")


def test_rejects_a_verify_step_that_starts_with_another_key(
    render: ModuleType,
    bodies: dict[str, list[str]],
) -> None:
    """``- id:`` first would lose the id and duplicate the name; refuse it."""
    text = SOURCE.replace(
        "      - name: Verify harden-runner agent\n        id: verify-harden-runner\n",
        "      - id: verify-harden-runner\n        name: Verify harden-runner agent\n",
        1,
    )
    assert_that(yaml.safe_load(text)["jobs"]["publish"]["steps"][1]["id"]).is_equal_to(
        "verify-harden-runner",
    )
    for profile in (render.Profile.AUDIT, render.Profile.NONE):
        with pytest.raises(render.ProfileError, match="does not start with its name"):
            render.REWRITE.rewrite(text, profile, bodies)


@pytest.mark.parametrize(
    ("old", "new", "token"),
    [
        (
            "      - name: Harden runner\n",
            "      - &hardener\n        name: Harden runner\n",
            "&hardener",
        ),
        (
            "      - name: Publish\n",
            "      - *hardener\n      - name: Publish\n",
            r"\*hardener",
        ),
        (
            "        with:\n          tier: strict\n",
            "        with: &tier\n          tier: strict\n",
            "&tier",
        ),
    ],
)
def test_rejects_yaml_anchors_and_aliases(
    render: ModuleType,
    bodies: dict[str, list[str]],
    old: str,
    new: str,
    token: str,
) -> None:
    """Removing an anchored step would leave its aliases undefined."""
    text = SOURCE.replace(old, new, 1)
    assert_that(text).is_not_equal_to(SOURCE)
    for profile in (render.Profile.AUDIT, render.Profile.NONE):
        with pytest.raises(render.ProfileError, match=f"anchor or alias '{token}'"):
            render.REWRITE.rewrite(text, profile, bodies)
    # block copies the file as it is.
    rendered, _counts = render.REWRITE.rewrite(text, render.Profile.BLOCK, bodies)
    assert_that(rendered).is_equal_to(text)


def test_a_hard_linked_destination_is_refused(
    render: ModuleType,
    tmp_path: Path,
) -> None:
    """A destination hard-linked elsewhere must not carry the write there."""
    root = _scratch(tmp_path)
    out = tmp_path / "out"
    render.write_tree(render.render_tree(render.Profile.BLOCK, root), out, root)
    victim = tmp_path / "victim.yml"
    target = out / ".github/workflows/w.yml"
    target.unlink()
    victim.write_text("untouched\n", encoding="utf-8")
    os.link(victim, target)
    tree = render.render_tree(render.Profile.AUDIT, root)
    with pytest.raises(render.UnsafeOutputError, match="more than one hard link"):
        render.write_tree(tree, out, root)
    assert_that(victim.read_text(encoding="utf-8")).is_equal_to("untouched\n")


def test_a_write_replaces_the_file_instead_of_opening_it(
    render: ModuleType,
    tmp_path: Path,
) -> None:
    """Even past the checks, a linked destination is replaced, not written."""
    victim = tmp_path / "victim"
    victim.write_text("untouched\n", encoding="utf-8")
    target = tmp_path / "target"
    os.link(victim, target)
    render.write_file(target, b"new\n", 0o644)
    assert_that(victim.read_text(encoding="utf-8")).is_equal_to("untouched\n")
    assert_that(target.read_bytes()).is_equal_to(b"new\n")
    assert_that(sorted(p.name for p in tmp_path.iterdir())).is_equal_to(
        ["target", "victim"],
    )


def test_an_output_that_is_the_source_under_another_spelling_is_refused(
    render: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Overlap is judged by file identity, not by how the path is spelled."""
    root = _scratch(tmp_path)
    alias = tmp_path / "alias"
    try:
        os.link(root, alias)
    except OSError:
        # Directory hard links are not allowed; use a case alias where the
        # volume folds case (macOS), else there is nothing to test.
        alias = tmp_path / "SRC"
        if not alias.exists():
            pytest.skip("no second spelling of a directory on this filesystem")
    before = _snapshot(root)
    for out in (alias, alias / ".git/copy"):
        code = render.main(["--profile", "audit", "--out", str(out)], root)
        assert_that(code).is_equal_to(2)
        assert_that(capsys.readouterr().err).contains("overlaps the source tree")
    assert_that(_snapshot(root)).is_equal_to(before)


def _snapshot(directory: Path) -> dict[str, bytes]:
    return {
        p.relative_to(directory).as_posix(): p.read_bytes()
        for p in sorted(directory.rglob("*"))
        if p.is_file() and not p.is_symlink()
    }


def test_main_writes_and_checks_a_copy(
    render: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Write, check clean, then report a changed, a missing and a stale file."""
    root = _scratch(tmp_path)
    out = tmp_path / "out"
    args = ["--profile", "audit", "--out", str(out)]
    assert_that(render.main(args, root=root)).is_equal_to(0)
    assert_that(capsys.readouterr().err).contains("prod.app-api.stepsecurity.io")
    assert_that(render.main([*args, "--check"], root=root)).is_equal_to(0)
    assert_that(str(out / "scripts/ci/bootstrap/__pycache__")).does_not_exist()
    script = out / "scripts/ci/bootstrap/egress-profile-notice.sh"
    assert_that(script.stat().st_mode & 0o111).is_not_zero()
    workflow = out / ".github/workflows/w.yml"
    assert_that(workflow.read_text(encoding="utf-8")).contains("Report egress")
    nested = (out / "examples/nested/caller.yml").read_text(encoding="utf-8")
    assert_that(nested).contains("Report egress").does_not_contain("Recheck")
    workflow.write_text("changed\n", encoding="utf-8")
    script.unlink()
    (out / "scripts/stale.sh").write_text("", encoding="utf-8")
    assert_that(render.main([*args, "--check"], root=root)).is_equal_to(1)
    problems = render.check_tree(render.render_tree(render.Profile.AUDIT, root), out)
    assert_that(problems).contains(
        ".github/workflows/w.yml: differs",
        "scripts/ci/bootstrap/egress-profile-notice.sh: missing",
        "scripts/stale.sh: not generated (stale file)",
    )


def test_marker_records_the_profile_without_a_timestamp(
    render: ModuleType,
    tmp_path: Path,
) -> None:
    """The marker is stable across runs, and --check compares it."""
    root = _scratch(tmp_path)
    out = tmp_path / "out"
    args = ["--profile", "none", "--out", str(out)]
    assert_that(render.main(args, root=root)).is_equal_to(0)
    marker = json.loads((out / MARKER).read_text(encoding="utf-8"))
    assert_that(marker).is_equal_to(
        {
            "generator": "lgtm-ci scripts/ci/bootstrap/render-egress-profile.py",
            "profile": "none",
            "source-commit": "unknown",
        },
    )
    first = _snapshot(out)
    assert_that(render.main(args, root=root)).is_equal_to(0)
    assert_that(_snapshot(out)).is_equal_to(first)
    # The same files with another profile's marker are not this copy.
    assert_that(
        render.main(["--profile", "audit", "--out", str(out), "--check"], root=root),
    ).is_equal_to(1)
    (out / MARKER).unlink()
    problems = render.check_tree(render.render_tree(render.Profile.NONE, root), out)
    assert_that(problems).contains(f"{MARKER}: missing")


def test_regenerating_removes_files_no_longer_produced(
    render: ModuleType,
    tmp_path: Path,
) -> None:
    """Stale surface files go; files outside the surface stay."""
    root = _scratch(tmp_path)
    out = tmp_path / "out"
    args = ["--profile", "none", "--out", str(out)]
    assert_that(render.main(args, root=root)).is_equal_to(0)
    (out / "scripts/ci/gone").mkdir()
    (out / "scripts/ci/gone/old.sh").write_text("old\n", encoding="utf-8")
    (out / "examples/nested/old.yml").write_text("old\n", encoding="utf-8")
    (out / "README.md").write_text("adopter's own\n", encoding="utf-8")
    (out / "docs").mkdir()
    (out / "docs/own.md").write_text("adopter's own\n", encoding="utf-8")
    assert_that(render.main([*args, "--check"], root=root)).is_equal_to(1)
    assert_that(render.main(args, root=root)).is_equal_to(0)
    assert_that(str(out / "scripts/ci/gone")).does_not_exist()
    assert_that(str(out / "examples/nested/old.yml")).does_not_exist()
    assert_that(str(out / "README.md")).exists()
    assert_that(str(out / "docs/own.md")).exists()
    assert_that(render.main([*args, "--check"], root=root)).is_equal_to(0)


def test_refuses_a_non_empty_output_without_marker(
    render: ModuleType,
    tmp_path: Path,
) -> None:
    """A directory this generator did not write is never written into."""
    root = _scratch(tmp_path)
    out = tmp_path / "out"
    (out / "scripts").mkdir(parents=True)
    (out / "scripts/keep.sh").write_text("mine\n", encoding="utf-8")
    assert_that(render.main(["--out", str(out)], root=root)).is_equal_to(2)
    assert_that(_snapshot(out)).is_equal_to({"scripts/keep.sh": b"mine\n"})
    (out / MARKER).write_text('{"generator": "something else"}\n', encoding="utf-8")
    assert_that(render.main(["--out", str(out)], root=root)).is_equal_to(2)


def test_refuses_a_non_block_copy_as_source(render: ModuleType, tmp_path: Path) -> None:
    """--profile block from inside an audit copy would write an audit tree."""
    root = _scratch(tmp_path)
    audit = tmp_path / "audit"
    code = render.main(["--profile", "audit", "--out", str(audit)], root=root)
    assert_that(code).is_equal_to(0)
    actions = ".github/actions"
    shutil.copytree(root / actions, audit / actions, dirs_exist_ok=True)
    again = tmp_path / "again"
    code = render.main(["--profile", "block", "--out", str(again)], root=audit)
    assert_that(code).is_equal_to(2)
    assert_that(str(again)).does_not_exist()
    block = tmp_path / "block"
    assert_that(render.main(["--out", str(block)], root=root)).is_equal_to(0)
    shutil.copytree(root / actions, block / actions, dirs_exist_ok=True)
    assert_that(render.main(["--out", str(tmp_path / "b2")], root=block)).is_equal_to(0)


def test_symlinked_directory_below_out_is_refused(
    render: ModuleType,
    tmp_path: Path,
) -> None:
    """Regression: out/.github/workflows linked to the source must not be written.

    Before the fix, generating audit output rewrote the source workflows.
    Now nothing is written at all, the source included.
    """
    root = _scratch(tmp_path)
    out = tmp_path / "out"
    (out / ".github").mkdir(parents=True)
    (out / ".github/workflows").symlink_to(root / ".github/workflows")
    (out / MARKER).write_text(
        json.dumps({"generator": render.GENERATOR}),
        encoding="utf-8",
    )
    before = _snapshot(root)
    code = render.main(["--profile", "audit", "--out", str(out)], root=root)
    assert_that(code).is_equal_to(2)
    assert_that(_snapshot(root)).is_equal_to(before)
    assert_that(sorted(_snapshot(out))).is_equal_to([MARKER])


def test_check_does_not_read_through_a_link_to_the_source(
    render: ModuleType,
    tmp_path: Path,
) -> None:
    """A block copy whose workflows link back to the source must not pass --check."""
    root = _scratch(tmp_path)
    out = tmp_path / "out"
    assert_that(render.main(["--out", str(out)], root=root)).is_equal_to(0)
    shutil.rmtree(out / ".github/workflows")
    (out / ".github/workflows").symlink_to(root / ".github/workflows")
    code = render.main(["--out", str(out), "--check"], root=root)
    assert_that(code).is_equal_to(1)


@pytest.mark.parametrize("where", ["file", "elsewhere", "parent"])
def test_symlinked_destinations_are_refused(
    render: ModuleType,
    tmp_path: Path,
    where: str,
) -> None:
    """A linked file, or a linked directory pointing anywhere, stops the write."""
    root = _scratch(tmp_path)
    out = tmp_path / "out"
    args = ["--profile", "none", "--out", str(out)]
    assert_that(render.main(args, root=root)).is_equal_to(0)
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    victim = elsewhere / "victim.yml"
    victim.write_text("victim\n", encoding="utf-8")
    if where == "file":
        (out / ".github/workflows/w.yml").unlink()
        (out / ".github/workflows/w.yml").symlink_to(victim)
    elif where == "elsewhere":
        shutil.rmtree(out / "examples/nested")
        (out / "examples/nested").symlink_to(elsewhere)
    else:
        shutil.rmtree(out / ".github/actions")
        (out / ".github/actions").symlink_to(elsewhere)
    before = _snapshot(out)
    assert_that(render.main(args, root=root)).is_equal_to(2)
    assert_that(victim.read_text(encoding="utf-8")).is_equal_to("victim\n")
    assert_that(_snapshot(out)).is_equal_to(before)
    assert_that(render.main([*args, "--check"], root=root)).is_equal_to(1)


def test_check_destination_refuses_paths_outside_out(
    render: ModuleType,
    tmp_path: Path,
) -> None:
    """``..`` and absolute paths never reach a write."""
    out = tmp_path / "out"
    out.mkdir()
    for relative in ("../x", "/etc/x", "a/../../x"):
        with pytest.raises(render.UnsafeOutputError):
            render.check_destination(out, relative, tmp_path / "src")


def test_main_block_profile_copies_unchanged(
    render: ModuleType,
    tmp_path: Path,
) -> None:
    """The default profile writes every surface file byte for byte."""
    root = _scratch(tmp_path)
    out = tmp_path / "out"
    assert_that(render.main(["--out", str(out)], root=root)).is_equal_to(0)
    for relative in render.surface_files(root):
        copied = (out / relative).read_bytes()
        assert_that(copied).is_equal_to((root / relative).read_bytes())


@pytest.mark.parametrize("where", ["root", "inside", "parent"])
def test_main_refuses_an_output_overlapping_the_source(
    render: ModuleType,
    tmp_path: Path,
    where: str,
) -> None:
    """The source tree is never written: --out must lie outside it."""
    root = _scratch(tmp_path)
    out = {"root": root, "inside": root / "copy", "parent": tmp_path}[where]
    assert_that(render.main(["--out", str(out)], root=root)).is_equal_to(2)
    assert_that(str(root / "copy")).does_not_exist()


def test_main_rejects_an_unknown_profile(render: ModuleType, tmp_path: Path) -> None:
    """Only the three profiles exist."""
    with pytest.raises(SystemExit):
        render.main(["--profile", "off", "--out", str(tmp_path / "o")])
