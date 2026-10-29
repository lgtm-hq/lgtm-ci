#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Render literal tuple bindings, auth defaults, egress and docs from one matrix."""

from __future__ import annotations

import argparse
import difflib
import json
import sys
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github/workflows/reusable-ai-review.yml"
DOC = ROOT / "docs/reusable-workflows.md"
sys.path.insert(0, str(ROOT / "scripts/ci/lib"))
# Shared standalone script library lives outside the package search path.
# pylint: disable-next=wrong-import-position
from ai_review_capabilities import matrix_rows  # noqa: E402


def expression(value: str) -> str:
    """Wrap a literal workflow expression without evaluating it."""
    return f"${{{{ {value} }}}}"


def folded(key: str, value: str, indent: int) -> str:
    """Render a folded scalar to keep generated expressions within YAML limits."""
    prefix = " " * indent
    lines = textwrap.wrap(
        value,
        width=100 - indent,
        break_long_words=False,
        break_on_hyphens=False,
    )
    return f"{prefix}{key}: >-\n" + "\n".join(prefix + "  " + line for line in lines)


def condition(row: list[str], context: str) -> str:
    """Build a literal expression gated on every tuple component."""
    fields = ("provider", "transport", "auth")
    prefix = "env.AI_REVIEW_" if context == "env" else "steps.resolve.outputs."
    return " && ".join(
        f"{prefix}{key.upper() if context == 'env' else key} == '{value}'"
        for key, value in zip(fields, row[:3], strict=True)
    )


def review_steps(matrix: list[list[str]]) -> str:
    """Use separate steps so API-key env slots are entirely absent under OAuth."""
    lines: list[str] = []
    for auth, title, ident in (
        ("api_key", "Run AI review", "review"),
        ("oauth", "Run OAuth AI review", "review-oauth"),
    ):
        lines.extend(
            [
                f"      - name: {title}",
                f"        id: {ident}",
                "        if: >-",
                "          steps.preflight.outputs.should-run == 'true'",
                f"          && steps.resolve.outputs.auth == '{auth}'",
                "          && steps.size.outputs.skip-size != 'true'",
                "        shell: bash",
                "        env:",
            ]
        )
        env = {
            "GH_TOKEN": expression("github.token"),
            "GITHUB_TOKEN": expression("steps.lintro-review-app.outputs.token"),
            "GITHUB_REPOSITORY": expression("github.repository"),
            "PR_NUMBER": expression("github.event.pull_request.number"),
            "BLOCKING": expression("inputs.blocking"),
            "JOB_TIMEOUT_MINUTES": expression("inputs.timeout-minutes"),
            "JOB_STARTED_AT": expression("steps.preflight.outputs.started-at"),
            "MAX_DIFF_LINES": expression("inputs.max-diff-lines"),
            "VENV_DIR": "${{ runner.temp }}/ai-review-venv",
            "AI_TOOLS_PREFIX": "${{ runner.temp }}/ai-tools",
            "REVIEW_NODE_BIN": expression("steps.install-lintro.outputs.node-bin"),
            "LINTRO_AI_PROVIDER": expression("steps.resolve.outputs.provider"),
            "LINTRO_AI_TRANSPORT": expression("steps.resolve.outputs.transport"),
            "AI_REVIEW_AUTH": expression("steps.resolve.outputs.auth"),
            "LINTRO_CLI_BARE": expression("steps.resolve.outputs.cli-bare"),
            "LINTRO_AI_MODEL": expression("steps.resolve.outputs.model"),
            "LINTRO_AI_MAX_COST_USD": expression("steps.resolve.outputs.max-cost-usd"),
            "LINTRO_AI_ENABLED": '"1"',
            "LINTRO_AI_REVIEW": '"1"',
        }
        lines.extend(f"          {key}: {value}" for key, value in env.items())
        slots = dict.fromkeys(row[4] for row in matrix if row[2] == auth)
        for slot in slots:
            candidates = [row for row in matrix if row[2] == auth]
            choices = [condition(row, "steps") for row in candidates if row[4] == slot]
            gate = " || ".join(f"({choice})" for choice in choices)
            value = expression(f"({gate}) && secrets.{slot} || ''")
            lines.append(folded(key=slot, value=value, indent=10))
        runner_path = ".lgtm-ci-tooling/scripts/ci/actions/ai_review_auth.py"
        lines.append(f"        run: python3 -I {runner_path}")
    return "\n".join(lines)


def replace_block(text: str, name: str, body: str) -> str:
    """Replace a marked region while retaining its marker indentation."""
    prefix = "<!--" if name == "capabilities" else "#"
    suffix = " -->" if prefix == "<!--" else ""
    start = f"{prefix} ai-review-{name}:begin{suffix}"
    end = f"{prefix} ai-review-{name}:end{suffix}"
    before, rest = text.split(start, 1)
    _, after = rest.split(end, 1)
    indent = before.rsplit("\n", 1)[-1]
    return before + start + "\n" + body + "\n" + indent + end + after


def rendered(matrix: list[list[str]]) -> dict[Path, str]:
    """Compute every derived block from the capability rows."""
    defaults = {"/".join(row[:2]): row[2] for row in matrix if row[3] == "yes"}
    selector = (
        "format('{0}/{1}', inputs.provider || vars.LINTRO_AI_PROVIDER, "
        "inputs.transport || vars.LINTRO_AI_TRANSPORT)"
    )
    auth_expression = "inputs.auth || vars.LINTRO_AI_AUTH || "
    auth_expression += f"fromJSON('{json.dumps(defaults)}')[{selector}]"
    source_expression = "inputs.auth != '' && 'input' || "
    source_expression += "vars.LINTRO_AI_AUTH != '' && 'var' || 'default'"
    env = folded(key="AI_REVIEW_AUTH", value=expression(auth_expression), indent=6)
    env += "\n" + folded(
        key="AI_REVIEW_AUTH_SOURCE",
        value=expression(source_expression),
        indent=6,
    )
    egress_value = (
        "${{ (inputs.allowed-endpoints-mode != 'append' && "
        "inputs.allowed-endpoints != '') && inputs.allowed-endpoints "
        "|| format('{0} {1}', "
        "fromJSON(env.LGTM_CI_EGRESS_PRESETS)[inputs.egress-preset || 'ai-review'], "
        "inputs.allowed-endpoints) }} "
    )
    extras = []
    for row in matrix:
        extras.append(expression(f"{condition(row, 'env')} && '{row[7]}' || ''"))
    egress_value += " ".join(extras)
    egress = folded(key="allowed-endpoints", value=egress_value, indent=10)
    workflow = replace_block(WORKFLOW.read_text(), "defaults", env)
    workflow = replace_block(workflow, "egress", egress)
    workflow = replace_block(workflow, "steps", review_steps(matrix))
    table = [
        "| Provider | Transport | Auth | Default | Secret slot / child binding | CLI |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for row in matrix:
        binding = f"`{row[4]}`"
        if row[4] == "CODEX_AUTH_JSON":
            binding += " → isolated `CODEX_HOME/auth.json`"
        if row[6]:
            binding += f" + `LINTRO_CLI_BARE={row[6]}`"
        default = "yes" if row[3] == "yes" else "—"
        cells = [*row[:3], default, binding, row[5] or "—"]
        table.append("| " + " | ".join(cells) + " |")
    return {
        WORKFLOW: workflow,
        DOC: replace_block(DOC.read_text(), "capabilities", "\n".join(table)),
    }


def main() -> int:
    """Write generated blocks, or report drift without modifying files."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    dirty = False
    for path, expected in rendered(matrix_rows()).items():
        current = path.read_text()
        if expected == current:
            continue
        dirty = True
        if args.check:
            print(
                "".join(
                    difflib.unified_diff(
                        current.splitlines(True),
                        expected.splitlines(True),
                        fromfile=str(path),
                        tofile="generated",
                    )
                )
            )
        else:
            path.write_text(expected)
    if args.check and dirty:
        return 1
    print("OK: AI review matrix blocks are current")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
