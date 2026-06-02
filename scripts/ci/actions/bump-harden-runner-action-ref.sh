#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Ensure reusables use the local harden-runner composite (same-repo pattern)
#
# GitHub resolves ./.github/actions/harden-runner from the ref used to invoke the
# reusable workflow (branch/tag/SHA). A remote lgtm-hq/lgtm-ci/...@<sha> pin fails on
# PR branches ("unable to find version"). See docs/workflow-contract.md.
#
# Usage:
#   bash scripts/ci/actions/bump-harden-runner-action-ref.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
USES_LINE="uses: ./.github/actions/harden-runner"

python3 - "$REPO_ROOT" "$USES_LINE" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
uses_line = sys.argv[2]

uses_pattern = re.compile(
    r"^(\s*)uses:\s*(?:\./\.lgtm-ci-egress/)?\.?/?\.github/actions/harden-runner\s*(?:#.*)?$|"
    r"^(\s*)uses:\s*lgtm-hq/lgtm-ci/\.github/actions/harden-runner@[^\s]+(?:\s+#.*)?$",
    re.MULTILINE,
)
egress_block = re.compile(
    r"\n      - name: Checkout egress action\n"
    r"        uses: actions/checkout@[^\n]+\n"
    r"(?:        with:\n(?:          [^\n]+\n)+)",
    re.MULTILINE,
)

DEFAULT_CHECKOUT_BLOCK = """      - name: Checkout repository
        # Pinned to SHA for supply chain security
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          persist-credentials: false

"""


def split_step_blocks(steps_body: str) -> list[str]:
    """Split the lines under a steps: key into per-step chunks."""
    positions = [m.start() for m in re.finditer(r"^      - ", steps_body, re.MULTILINE)]
    if not positions:
        return [steps_body] if steps_body.strip() else []
    if positions[0] != 0:
        positions = [0, *positions]
    blocks = []
    for i, pos in enumerate(positions):
        end = positions[i + 1] if i + 1 < len(positions) else len(steps_body)
        blocks.append(steps_body[pos:end])
    return blocks


def join_step_blocks(blocks: list[str]) -> str:
    return "".join(blocks)


def is_harden_block(block: str) -> bool:
    return "harden-runner" in block and "- name: harden runner" in block.lower()


def _checkout_path_is_workspace_root(block: str) -> bool:
    """True when checkout uses the job workspace root (not a subdirectory)."""
    for line in block.splitlines():
        stripped = line.strip()
        if not stripped.startswith("path:"):
            continue
        value = stripped.split(":", 1)[1].strip().strip("'\"")
        return value in (".", "./")
    return True


def is_repo_checkout_block(block: str) -> bool:
    if "- name: Checkout repository" not in block:
        return False
    if "repository:" in block:
        return False
    return _checkout_path_is_workspace_root(block)


def normalize_step_blocks(blocks: list[str]) -> list[str]:
    """One default repo checkout immediately before each harden step."""
    out: list[str] = []
    i = 0
    while i < len(blocks):
        block = blocks[i]
        if not is_harden_block(block):
            out.append(block)
            i += 1
            continue

        prev_repo = out and is_repo_checkout_block(out[-1])
        if prev_repo:
            out.append(block)
            i += 1
            if i < len(blocks) and is_repo_checkout_block(blocks[i]):
                i += 1
            continue

        if i + 1 < len(blocks) and is_repo_checkout_block(blocks[i + 1]):
            out.append(blocks[i + 1])
            out.append(block)
            i += 2
            continue

        out.append(DEFAULT_CHECKOUT_BLOCK)
        out.append(block)
        i += 1

    deduped: list[str] = []
    for block in out:
        if (
            deduped
            and is_repo_checkout_block(block)
            and is_repo_checkout_block(deduped[-1])
            and block.strip() == deduped[-1].strip()
        ):
            continue
        deduped.append(block)
    return deduped


def extract_steps_body(body: str) -> tuple[str, str]:
    """Return step list lines (6-space ` - name`) and remainder of job/file."""
    lines = body.splitlines(keepends=True)
    consumed: list[str] = []
    i = 0
    while i < len(lines) and lines[i].startswith("      #"):
        consumed.append(lines[i])
        i += 1
    while i < len(lines):
        line = lines[i]
        if line.startswith("      - ") or (
            consumed and line.startswith("      #")
        ):
            consumed.append(line)
            i += 1
            continue
        if consumed and (line.startswith("        ") or line.strip() == ""):
            consumed.append(line)
            i += 1
            continue
        break
    return "".join(consumed), "".join(lines[i:])


def normalize_workflow(text: str, workflow_path: pathlib.Path) -> str:
    def replace_uses(match: re.Match[str]) -> str:
        indent = match.group(1)
        if indent is None:
            indent = match.group(2)
        return f"{indent}{uses_line}"

    new_text = uses_pattern.sub(replace_uses, text)
    new_text = egress_block.sub("\n", new_text)

    steps_header = re.compile(r"^(    )steps:\s*\n", re.MULTILINE)
    parts: list[str] = []
    last = 0
    for match in steps_header.finditer(new_text):
        parts.append(new_text[last : match.start()])
        body_start = match.end()
        steps_body, _tail = extract_steps_body(new_text[body_start:])
        blocks = split_step_blocks(steps_body)
        normalized = normalize_step_blocks(blocks) if blocks else []
        normalized_body = join_step_blocks(normalized)
        orig_steps = len(re.findall(r"^      - ", steps_body, re.MULTILINE))
        new_steps = len(re.findall(r"^      - ", normalized_body, re.MULTILINE))
        if blocks and new_steps < orig_steps:
            raise SystemExit(
                f"step normalization dropped steps in {workflow_path}: "
                f"{orig_steps} -> {new_steps}"
            )
        parts.append(f"{match.group(1)}steps:\n")
        parts.append(normalized_body)
        last = body_start + len(steps_body)
    parts.append(new_text[last:])
    return "".join(parts)


updated = 0
for path in sorted((root / ".github/workflows").glob("*.yml")):
    text = path.read_text()
    new_text = normalize_workflow(text, path)
    if new_text != text:
        path.write_text(new_text)
        updated += 1

print(f"updated {updated} workflow files")
PY

echo "All reusables use ${USES_LINE}"
