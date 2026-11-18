# SPDX-License-Identifier: MIT
"""Scratch repositories and workflow text for the inline-shell check tests (#1624).

``tests/python/test_validate_inline_shell.py`` and
``tests/python/test_inline_shell_bypasses.py`` build small repositories with
these helpers and run ``scripts/ci/quality/validate_inline_shell.py`` on them.
"""

from __future__ import annotations

import shutil
from pathlib import Path
from types import ModuleType

ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = "scripts/ci/quality/validate_inline_shell.py"
SCRIPT = "scripts/ci/actions/example.sh"
HEADER = "jobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n"
# A reusable workflow: only another workflow calls it, so its inputs are the
# caller's choice (the caller-chosen script exception).
CALLED_HEADER = "on:\n  workflow_call:\n" + HEADER
PRESET = "fail-unknown-egress-preset"
PRESET_SOURCE = "scripts/ci/bootstrap/fail-unknown-egress-preset.sh"


def make_repo(root: Path) -> Path:
    """Create a scratch repository with one script and one action script.

    The source of the ``fail-unknown-egress-preset`` generated block is
    copied in, so a correct copy of it can be checked against its source.

    Args:
        root: An empty directory.

    Returns:
        The same directory.
    """
    (root / "scripts" / "ci" / "actions").mkdir(parents=True)
    (root / SCRIPT).write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    action = root / ".github" / "actions" / "demo"
    action.mkdir(parents=True)
    (action / "own.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (root / ".github" / "workflows").mkdir(parents=True)
    source = root / PRESET_SOURCE
    source.parent.mkdir(parents=True)
    shutil.copy(ROOT / PRESET_SOURCE, source)
    return root


def step(
    run: str,
    name: str = "Step",
    env: dict[str, str] | None = None,
    *,
    shell: str | None = "bash",
    extra: str = "",
) -> str:
    """Return one workflow step running ``run`` as a literal block.

    Args:
        run: The script text.
        name: The step name.
        env: The step's ``env:``, written as given.
        shell: The ``shell:`` value, or None to leave it out.
        extra: More step keys, each line indented as a step key
            (``working-directory: sub``).

    Returns:
        The step's YAML.
    """
    body = "".join(f"          {line}\n" if line else "\n" for line in run.split("\n"))
    env_text = ""
    if env:
        pairs = "".join(f"          {k}: {v}\n" for k, v in env.items())
        env_text = f"        env:\n{pairs}"
    shell_text = f"        shell: {shell}\n" if shell is not None else ""
    extra_text = "".join(f"        {line}\n" for line in extra.splitlines())
    head = f"      - name: {name}\n{shell_text}{extra_text}{env_text}"
    return f"{head}        run: |\n{body}"


def write_workflow(
    repo: Path,
    *steps: str,
    name: str = "w.yml",
    header: str = HEADER,
) -> None:
    """Write a workflow with the given steps."""
    path = repo / ".github" / "workflows" / name
    path.write_text(header + "".join(steps), encoding="utf-8")


def preset_copy(sync: ModuleType) -> str:
    """Return a correct ``run:`` text for the ``fail-unknown-egress-preset`` block."""
    lines = [
        f"# lgtm-ci-inline:begin {PRESET}",
        *sync.generated_body(PRESET),
        f"# lgtm-ci-inline:end {PRESET}",
    ]
    return "\n".join(lines)


def problems(check: ModuleType, repo: Path) -> list[str]:
    """Return the report lines for a scratch repository."""
    steps, errors = check.check(repo)
    lines: list[str] = check.report(steps, errors)
    return lines


def categories(check: ModuleType, repo: Path) -> list[str]:
    """Return the class of each step, in file order."""
    steps, _ = check.check(repo)
    return [str(s.category) for s in steps]
