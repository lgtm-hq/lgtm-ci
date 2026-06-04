#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Restore scripts/ci/ in tooling sparse-checkout when a job runs CI scripts."""

from __future__ import annotations

import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
WORKFLOWS = REPO_ROOT / ".github/workflows"
SCRIPTS_LINE = "            scripts/ci/\n"
EGRESS_STEP = re.compile(r"^\s+- name: Checkout lgtm-ci egress tooling\s*$")


def job_needs_scripts(job_body: str) -> bool:
    return ".lgtm-ci-tooling/scripts" in job_body


def fix_sparse_block(block: str) -> str:
    if "scripts/ci/" in block or "scripts/ci/actions/" in block:
        return block
    if "resolve-egress-allowlist" in block:
        return block.replace(
            "            .github/actions/resolve-egress-allowlist\n",
            "            .github/actions/resolve-egress-allowlist\n" + SCRIPTS_LINE,
            1,
        )
    if ".github/actions/" in block:
        return block.replace(
            "            .github/actions/\n",
            "            .github/actions/\n" + SCRIPTS_LINE,
            1,
        )
    return block


def fix_job(job_body: str) -> str:
    if not job_needs_scripts(job_body):
        return job_body

    lines = job_body.splitlines(keepends=True)
    out: list[str] = []
    i = 0
    egress_sparse = False
    while i < len(lines):
        line = lines[i]
        if EGRESS_STEP.match(line.rstrip("\n")):
            egress_sparse = True
            out.append(line)
            i += 1
            continue
        if line.strip().startswith("- name:") and "Checkout lgtm-ci" in line:
            egress_sparse = False
        if line.strip() == "sparse-checkout: |" and not egress_sparse:
            out.append(line)
            i += 1
            block_lines: list[str] = []
            while i < len(lines) and lines[i].startswith("            "):
                block_lines.append(lines[i])
                i += 1
            block = "".join(block_lines)
            out.append(fix_sparse_block(block))
            continue
        out.append(line)
        i += 1
    return "".join(out)


def fix_workflow(text: str) -> str:
    parts: list[str] = []
    last = 0
    for match in re.finditer(r"^  (\w[\w-]*):\n", text, re.MULTILINE):
        if match.start() > last:
            parts.append(text[last : match.start()])
        job_name = match.group(1)
        if job_name in {"on", "permissions", "concurrency"}:
            last = match.start()
            continue
        next_job = re.search(r"^  \w[\w-]*:\n", text[match.end() :], re.MULTILINE)
        job_end = match.end() + next_job.start() if next_job else len(text)
        job_body = text[match.start() : job_end]
        parts.append(fix_job(job_body))
        last = job_end
    parts.append(text[last:])
    return "".join(parts)


def main() -> int:
    updated = 0
    for path in sorted(WORKFLOWS.glob("reusable-*.yml")):
        text = path.read_text()
        if ".lgtm-ci-tooling/scripts" not in text:
            continue
        new_text = fix_workflow(text)
        if new_text != text:
            path.write_text(new_text)
            updated += 1
            print(path.name)
    print(f"updated {updated} workflow files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
