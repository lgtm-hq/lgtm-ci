# SPDX-License-Identifier: MIT
"""Ratchet on inline shell in workflow and action YAML (#1450).

A ``run:`` block longer than ``MAX_INLINE_LINES`` lines is shell that nothing
shellchecks, formats, tests or covers. New logic belongs in ``scripts/ci/``.
Every block over the limit must be listed in ``ALLOWED`` with a reason, and
every listed block must still exist and still be over the limit, so the list
only ever shrinks.

A block is keyed by ``(file, job, step)``: the file relative to ``.github``,
the job id (``(composite)`` for a composite action) and the step name, else
its id, else its index.
"""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
import yaml
from assertpy import assert_that

GITHUB_DIR = Path(__file__).resolve().parents[2] / ".github"
MAX_INLINE_LINES = 3
COMPOSITE = "(composite)"

BlockKey = tuple[str, str, str]

# Reasons, so each entry says why it is still inline. Every remaining block is
# workflow-owned (it runs before, or must not trust, the tooling checkout), so
# it is generated from one tested source script instead of being extracted.
GENERATED = (
    "generated from a tested script under scripts/ci/bootstrap/ and "
    "drift-checked by sync_inline_blocks.py (#1450)"
)

GUARD = "Refuse a diverging tooling-ref"
TRIVY = "Install verified Trivy"
APP = "Select GitHub App credential"
EXTRACT = "Verify and extract lgtm-ci tooling"
DOCKER_VALIDATE = "workflows/reusable-docker-multiplatform-validate.yml"


def _entries(reason: str, *blocks: str) -> dict[BlockKey, str]:
    """Map each ``"file|job|step"`` block to ``reason``."""
    result: dict[BlockKey, str] = {}
    for block in blocks:
        file, job, step = block.split("|")
        result[(file, job, step)] = reason
    return result


_TWINS = (
    "workflows/reusable-release-version-pr.yml",
    "workflows/reusable-release-multi-ecosystem.yml",
)

ALLOWED: dict[BlockKey, str] = {
    **_entries(
        GENERATED,
        f"workflows/reusable-docker-build.yml|build|{TRIVY}",
        f"workflows/reusable-docker-build.yml|scan|{TRIVY}",
        f"workflows/reusable-docker-multiplatform-publish.yml|scan|{TRIVY}",
        f"{DOCKER_VALIDATE}|build-per-platform|{TRIVY}",
        f"workflows/reusable-build-rust-binaries.yml|build|{GUARD}",
        f"workflows/reusable-main-failure-notifier.yml|notify|{GUARD}",
        f"workflows/reusable-publish-rust-release.yml|verify-tag|{GUARD}",
        f"workflows/reusable-publish-rust-release.yml|github-release|{GUARD}",
        f"workflows/reusable-release-auto-tag.yml|auto-tag|{GUARD}",
        f"workflows/reusable-release-auto-tag.yml|report-release-failure|{GUARD}",
        f"workflows/reusable-release-failure-notifier.yml|notify|{GUARD}",
        "workflows/reusable-sbom-release-upload.yml" f"|upload-release-assets|{GUARD}",
        f"workflows/reusable-sbom.yml|validate|{GUARD}",
        f"workflows/reusable-release-auto-tag.yml|auto-tag|{APP}",
        # The release twins' copies too: generating them is not #1356 work,
        # which de-duplicates the whole twin reusables.
        *(
            f"{twin}|{block}"
            for twin in _TWINS
            for block in (
                f"prepare|{GUARD}",
                f"prepare|{APP}",
                f"version-update-hook|{EXTRACT}",
                f"version-pr|{GUARD}",
                f"version-pr|{APP}",
                f"report-release-failure|{GUARD}",
            )
        ),
    ),
}


def _yaml_files(github_dir: Path) -> Iterator[Path]:
    """Yield every workflow and composite action file, sorted."""
    yield from sorted((github_dir / "workflows").glob("*.y*ml"))
    yield from sorted((github_dir / "actions").rglob("action.y*ml"))


def _step_groups(document: dict[str, Any]) -> Iterator[tuple[str, list[Any]]]:
    """Yield ``(job id, steps)`` for each job, or the composite action."""
    for job_id, job in (document.get("jobs") or {}).items():
        if isinstance(job, dict):
            yield str(job_id), job.get("steps") or []
    runs = document.get("runs")
    if isinstance(runs, dict):
        yield COMPOSITE, runs.get("steps") or []


def _line_count(script: str) -> int:
    """Count the lines of a ``run:`` script, ignoring surrounding blank lines."""
    return len(script.strip().splitlines())


def long_run_blocks(github_dir: Path = GITHUB_DIR) -> dict[BlockKey, int]:
    """Map each ``run:`` block over the limit to its line count.

    Args:
        github_dir: The ``.github`` directory to scan.

    Returns:
        ``{(file, job, step): lines}`` for every block over ``MAX_INLINE_LINES``.

    Raises:
        ValueError: When two over-limit blocks share a key, which would let one
            allowlist entry cover both, or when a ``run:`` is not a string.
    """
    blocks: dict[BlockKey, int] = {}
    for path in _yaml_files(github_dir):
        document = yaml.safe_load(path.read_text("utf-8")) or {}
        relative = path.relative_to(github_dir).as_posix()
        for job_id, steps in _step_groups(document):
            for index, step in enumerate(steps):
                if not isinstance(step, dict) or "run" not in step:
                    continue
                if not isinstance(step["run"], str):
                    # e.g. `run: !!binary` loads as bytes; refuse rather than skip.
                    raise ValueError(f"{relative} {job_id}: run: is not a string")
                lines = _line_count(step["run"])
                if lines <= MAX_INLINE_LINES:
                    continue
                label = step.get("name") or step.get("id") or index
                key = (relative, job_id, str(label))
                if key in blocks:
                    raise ValueError(
                        f"two long run: blocks share the key {key}; name them apart",
                    )
                blocks[key] = lines
    return blocks


def test_no_unlisted_long_run_blocks() -> None:
    """A new ``run:`` block over the limit must move to ``scripts/ci/``."""
    unlisted = sorted(set(long_run_blocks()) - set(ALLOWED))
    assert_that(unlisted).described_as(
        f"run: blocks over {MAX_INLINE_LINES} lines; move the logic to scripts/ci/ "
        "(or, with a reason, add the block to ALLOWED in this file)",
    ).is_empty()


def test_allowlist_has_no_stale_entries() -> None:
    """An extracted or shortened block must leave the allowlist."""
    stale = sorted(set(ALLOWED) - set(long_run_blocks()))
    assert_that(stale).described_as(
        "ALLOWED entries that are gone or within the limit; remove them",
    ).is_empty()


REASONS = (GENERATED,)
GENERATED_MARKER = "# lgtm-ci-inline:begin "


def test_allowlist_uses_only_the_named_reasons() -> None:
    """Each entry gives one of the named reasons, never an ad-hoc string."""
    assert_that(sorted(set(ALLOWED.values()) - set(REASONS))).is_empty()


def _run_scripts(github_dir: Path = GITHUB_DIR) -> dict[BlockKey, str]:
    """Map every ``run:`` step to its script, keyed like :func:`long_run_blocks`."""
    scripts: dict[BlockKey, str] = {}
    for path in _yaml_files(github_dir):
        document = yaml.safe_load(path.read_text("utf-8")) or {}
        relative = path.relative_to(github_dir).as_posix()
        for job_id, steps in _step_groups(document):
            for index, step in enumerate(steps):
                if isinstance(step, dict) and isinstance(step.get("run"), str):
                    label = step.get("name") or step.get("id") or index
                    scripts[(relative, job_id, str(label))] = step["run"]
    return scripts


def test_generated_entries_carry_sync_markers() -> None:
    """A block listed as generated really is a marked, drift-checked copy."""
    scripts = _run_scripts()
    generated = sorted(key for key, reason in ALLOWED.items() if reason == GENERATED)
    unmarked = [key for key in generated if GENERATED_MARKER not in scripts[key]]
    assert_that(generated).is_not_empty()
    assert_that(unmarked).is_empty()
    # The whole run: is generated: hand-written logic around the markers would
    # ride on the allowlist entry without being drift-checked.
    outside = {key: _outside_markers(scripts[key]) for key in generated}
    extra = {key: lines for key, lines in outside.items() if lines}
    assert_that(extra).is_empty()


def _outside_markers(script: str) -> list[str]:
    """Return the non-blank lines of a run: script outside its sync markers."""
    outside: list[str] = []
    inside = False
    for line in script.splitlines():
        text = line.strip()
        if text.startswith("# lgtm-ci-inline:begin "):
            inside = True
        elif text.startswith("# lgtm-ci-inline:end "):
            inside = False
        elif text and not inside:
            outside.append(text)
    return outside


def test_outside_markers_finds_hand_written_lines() -> None:
    """Lines before, between or after marked blocks are reported."""
    script = (
        "echo before\n"
        "# lgtm-ci-inline:begin x\n"
        "generated\n"
        "# lgtm-ci-inline:end x\n"
        "\n"
        "echo after\n"
    )
    assert_that(_outside_markers(script)).is_equal_to(["echo before", "echo after"])


# A four-line run: body at workflow-step indentation.
FOUR = "".join(f"          {letter}\n" for letter in "abcd")


def _write(root: Path, relative: str, text: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, "utf-8")


def test_scanner_finds_workflow_and_composite_blocks(tmp_path: Path) -> None:
    """The scanner keys long blocks by file, job and step, and skips short ones."""
    _write(
        tmp_path,
        "workflows/w.yml",
        "jobs:\n  build:\n    steps:\n"
        f"      - name: Long\n        run: |\n{FOUR}"
        "      - name: Short\n        run: |\n          a\n          b\n          c\n"
        "      - id: by-id\n        run: |\n"
        "          a\n          b\n          c\n          d\n          e\n"
        "      - uses: actions/checkout@v4\n",
    )
    _write(
        tmp_path,
        "actions/a/action.yml",
        "runs:\n  using: composite\n  steps:\n"
        "    - run: |\n        a\n        b\n        c\n        d\n      shell: bash\n",
    )

    assert_that(long_run_blocks(tmp_path)).is_equal_to(
        {
            ("workflows/w.yml", "build", "Long"): 4,
            ("workflows/w.yml", "build", "by-id"): 5,
            ("actions/a/action.yml", COMPOSITE, "0"): 4,
        },
    )


def test_scanner_rejects_two_blocks_with_one_key(tmp_path: Path) -> None:
    """Two long blocks under one step name cannot share an allowlist entry."""
    step = f"      - name: Same\n        run: |\n{FOUR}"
    _write(tmp_path, "workflows/w.yml", "jobs:\n  j:\n    steps:\n" + step + step)

    with pytest.raises(ValueError, match="share the key"):
        long_run_blocks(tmp_path)


def test_scanner_rejects_a_non_string_run(tmp_path: Path) -> None:
    """A tagged ``run:`` (``!!binary`` loads as bytes) cannot slip past."""
    # base64 of "uname\\npwd\\nwhoami\\nls\\n", split over four lines.
    chunks = ("dW5hbWUK", "cHdkCndo", "b2FtaQps", "cwo=")
    body = "".join(f"          {chunk}\n" for chunk in chunks)
    head = "jobs:\n  j:\n    steps:\n      - name: Tagged\n"
    _write(tmp_path, "workflows/w.yml", f"{head}        run: !!binary |\n{body}")

    with pytest.raises(ValueError, match="is not a string"):
        long_run_blocks(tmp_path)
