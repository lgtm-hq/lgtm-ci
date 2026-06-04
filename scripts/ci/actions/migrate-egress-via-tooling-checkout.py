#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Migrate egress composites to ./.lgtm-ci-tooling after checkout (#279)."""

from __future__ import annotations

import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
WORKFLOWS = REPO_ROOT / ".github/workflows"

CHECKOUT_SHA = "de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2"
EGRESS_ACTIONS = (
    ".github/actions/harden-runner",
    ".github/actions/resolve-egress-allowlist",
)

RESOLVE_USES_RE = re.compile(
    r"^(\s*)uses:\s*(?:\./\.github/actions/|\.?/?\.lgtm-ci-tooling/\.github/actions/|"
    r"lgtm-hq/lgtm-ci/\.github/actions/)resolve-egress-allowlist(?:@.*)?\s*$",
    re.MULTILINE,
)
HARDEN_USES_RE = re.compile(
    r"^(\s*)uses:\s*(?:\./\.github/actions/|\.?/?\.lgtm-ci-tooling/\.github/actions/|"
    r"lgtm-hq/lgtm-ci/\.github/actions/)harden-runner(?:@.*)?\s*$",
    re.MULTILINE,
)
TOOLING_STEP_RE = re.compile(
    r"- name: Checkout lgtm-ci tooling",
    re.MULTILINE,
)
STEPS_HEADER_RE = re.compile(r"^(    )steps:\s*\n", re.MULTILINE)
TOOLING_REF_EXPR = "".join(
    (
        "${{ inputs.tooling-ref != '' && inputs.tooling-ref ",
        "|| github.workflow_sha }}",
    ),
)

SPARSE_BLOCK_RE = re.compile(
    r"(      - name: Checkout lgtm-ci tooling\n"
    r"(?:        # yamllint disable-line rule:line-length\n)?"
    r"        uses: actions/checkout@[^\n]+\n"
    r"        with:\n"
    r"          repository: lgtm-hq/lgtm-ci\n"
    r"          path: \.lgtm-ci-tooling\n"
    r"          ref: [^\n]+\n)"
    r"((?:          sparse-checkout: [^\n]+\n|"
    r"          sparse-checkout: \|\n(?:            [^\n]+\n)+)?)"
    r"(          sparse-checkout-cone-mode: true\n"
    r"          persist-credentials: false\n)",
    re.MULTILINE,
)

_DEFAULT_TOOLING_BLOCK_TEMPLATE = """      - name: Checkout lgtm-ci tooling
        # yamllint disable-line rule:line-length
        uses: actions/checkout@{checkout_sha}
        with:
          repository: lgtm-hq/lgtm-ci
          path: .lgtm-ci-tooling
          ref: {tooling_ref}
          sparse-checkout: |
            .github/actions/harden-runner
            .github/actions/resolve-egress-allowlist
          sparse-checkout-cone-mode: true
          persist-credentials: false

"""

DEFAULT_TOOLING_BLOCK = _DEFAULT_TOOLING_BLOCK_TEMPLATE.format(
    checkout_sha=CHECKOUT_SHA,
    tooling_ref=TOOLING_REF_EXPR,
)


def split_step_blocks(steps_body: str) -> list[str]:
    positions = [m.start() for m in re.finditer(r"^      - ", steps_body, re.MULTILINE)]
    if not positions:
        return [steps_body] if steps_body.strip() else []
    if positions[0] != 0:
        positions = [0, *positions]
    blocks: list[str] = []
    for i, pos in enumerate(positions):
        end = positions[i + 1] if i + 1 < len(positions) else len(steps_body)
        blocks.append(steps_body[pos:end])
    return blocks


def join_step_blocks(blocks: list[str]) -> str:
    return "".join(blocks)


def is_egress_block(block: str) -> bool:
    return "resolve-egress-allowlist" in block or (
        "harden-runner" in block and "resolve" not in block
    )


def is_resolve_block(block: str) -> bool:
    return "resolve-egress-allowlist" in block


def is_harden_block(block: str) -> bool:
    return "harden-runner" in block and "resolve-egress" not in block


def is_tooling_checkout_block(block: str) -> bool:
    return "Checkout lgtm-ci tooling" in block and "path: .lgtm-ci-tooling" in block


def is_repo_checkout_block(block: str) -> bool:
    if "Checkout repository" not in block:
        return False
    if "repository: lgtm-hq/lgtm-ci" in block:
        return False
    if "path: .lgtm-ci-tooling" in block:
        return False
    if "steps.app-token.outputs" in block:
        return False
    return "uses: actions/checkout@" in block


def parse_sparse_paths(block: str) -> list[str]:
    paths: list[str] = []
    if "sparse-checkout: |" in block:
        for line in block.splitlines():
            stripped = line.strip()
            if (
                stripped
                and not stripped.startswith("#")
                and "sparse-checkout" not in stripped
                and line.startswith("            ")
            ):
                paths.append(stripped)
    else:
        m = re.search(r"sparse-checkout:\s*(.+)", block)
        if m:
            val = m.group(1).strip()
            if val and val != "|":
                paths.append(val)
    return paths


def format_tooling_block(ref_expr: str, sparse_paths: list[str]) -> str:
    ordered: list[str] = []
    seen: set[str] = set()
    for p in [*EGRESS_ACTIONS, *sparse_paths]:
        if p in seen:
            continue
        seen.add(p)
        ordered.append(p)
    if len(ordered) == 1:
        sparse_lines = f"          sparse-checkout: {ordered[0]}\n"
    else:
        sparse_lines = "          sparse-checkout: |\n" + "".join(
            f"            {p}\n" for p in ordered
        )
    return (
        "      - name: Checkout lgtm-ci tooling\n"
        "        # yamllint disable-line rule:line-length\n"
        f"        uses: actions/checkout@{CHECKOUT_SHA}\n"
        "        with:\n"
        "          repository: lgtm-hq/lgtm-ci\n"
        "          path: .lgtm-ci-tooling\n"
        f"          ref: {ref_expr}\n"
        f"{sparse_lines}"
        "          sparse-checkout-cone-mode: true\n"
        "          persist-credentials: false\n\n"
    )


def normalize_egress_uses(block: str, *, in_repo: bool) -> str:
    if in_repo:
        block = RESOLVE_USES_RE.sub(
            r"\1uses: ./.github/actions/resolve-egress-allowlist",
            block,
        )
        return HARDEN_USES_RE.sub(r"\1uses: ./.github/actions/harden-runner", block)
    block = RESOLVE_USES_RE.sub(
        r"\1uses: ./.lgtm-ci-tooling/.github/actions/resolve-egress-allowlist",
        block,
    )
    return HARDEN_USES_RE.sub(
        r"\1uses: ./.lgtm-ci-tooling/.github/actions/harden-runner",
        block,
    )


def normalize_job_steps(blocks: list[str], *, in_repo: bool) -> list[str]:
    if not any(is_resolve_block(b) or is_harden_block(b) for b in blocks):
        return blocks

    ref_expr = "${{ github.sha }}" if in_repo else TOOLING_REF_EXPR

    tooling_blocks = [b for b in blocks if is_tooling_checkout_block(b)]
    sparse_paths: list[str] = []
    for tb in tooling_blocks:
        sparse_paths.extend(parse_sparse_paths(tb))

    other: list[str] = []
    resolve_block: str | None = None
    harden_block: str | None = None
    repo_checkouts: list[str] = []

    for block in blocks:
        if is_tooling_checkout_block(block):
            continue
        if is_resolve_block(block):
            resolve_block = normalize_egress_uses(block, in_repo=in_repo)
            continue
        if is_harden_block(block):
            harden_block = normalize_egress_uses(block, in_repo=in_repo)
            continue
        if is_repo_checkout_block(block):
            repo_checkouts.append(block)
        else:
            other.append(block)

    if in_repo:
        reordered = [*repo_checkouts]
        if resolve_block:
            reordered.append(resolve_block)
        if harden_block:
            reordered.append(harden_block)
        reordered.extend(other)
        return reordered

    tooling = format_tooling_block(ref_expr, sparse_paths)
    reordered = [*repo_checkouts, tooling]
    if resolve_block:
        reordered.append(resolve_block)
    if harden_block:
        reordered.append(harden_block)
    reordered.extend(other)
    return reordered


def extract_steps_body(body: str) -> tuple[str, str]:
    lines = body.splitlines(keepends=True)
    consumed: list[str] = []
    i = 0
    while i < len(lines) and lines[i].startswith("      #"):
        consumed.append(lines[i])
        i += 1
    while i < len(lines):
        line = lines[i]
        if line.startswith("      - ") or (consumed and line.startswith("      #")):
            consumed.append(line)
            i += 1
            continue
        if consumed and (line.startswith("        ") or line.strip() == ""):
            consumed.append(line)
            i += 1
            continue
        break
    return "".join(consumed), "".join(lines[i:])


def migrate_workflow(text: str, path: pathlib.Path) -> str:
    in_repo = path.name == "renovate.yml"

    def process_steps(steps_body: str) -> str:
        blocks = split_step_blocks(steps_body)
        if not blocks:
            return steps_body
        normalized = normalize_job_steps(blocks, in_repo=in_repo)
        return join_step_blocks(normalized)

    parts: list[str] = []
    last = 0
    for match in STEPS_HEADER_RE.finditer(text):
        parts.append(text[last : match.start()])
        body_start = match.end()
        steps_body, _tail = extract_steps_body(text[body_start:])
        parts.append(f"{match.group(1)}steps:\n")
        parts.append(process_steps(steps_body))
        last = body_start + len(steps_body)
    parts.append(text[last:])
    return "".join(parts)


def main() -> int:
    updated = 0
    for path in sorted(WORKFLOWS.glob("*.yml")):
        if not (path.name.startswith("reusable-") or path.name == "renovate.yml"):
            continue
        if not RESOLVE_USES_RE.search(path.read_text()) and not HARDEN_USES_RE.search(
            path.read_text()
        ):
            continue
        text = path.read_text()
        new_text = migrate_workflow(text, path)
        if new_text != text:
            path.write_text(new_text)
            updated += 1
            print(path.name)
    print(f"updated {updated} workflow files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
