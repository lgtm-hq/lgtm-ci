#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Scan org CI copies and reconcile one backlog issue per normalized cluster.

Reads use GH_READ_TOKEN (or the local gh login). Writes use GH_TOKEN and are
disabled unless --dry-run=false is explicitly supplied. No repository content
is checked out or executed; private source is never persisted or logged.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any
from urllib.parse import quote

import yaml

from duplication_model import Unit, clusters, excepted, load_exceptions, render, selected, units

ROOT = Path(__file__).resolve().parents[3]
TARGET = "lgtm-hq/lgtm-ci"
MAX_BLOB = 256 * 1024


class GitHub:
    """Small gh JSON transport with separately scoped read and write tokens."""

    def api(self, endpoint: str, *, payload: Any = None, read: bool = True) -> Any:
        """Read pages or send one mutation; never print response error content."""
        env = os.environ.copy()
        if read:
            env.pop("GITHUB_TOKEN", None)
            env.pop("GH_TOKEN", None)
            if os.environ.get("GH_READ_TOKEN"):
                env["GH_TOKEN"] = os.environ["GH_READ_TOKEN"]
        args = ["gh", "api", endpoint]
        if payload is not None:
            args += ["--method", "POST" if read else payload.pop("_method", "POST"), "--input", "-"]
        else:
            args += ["--paginate"]
        proc = subprocess.run(
            args,
            input=json.dumps(payload) if payload is not None else None,
            text=True,
            capture_output=True,
            check=False,
            env=env,
        )
        if proc.returncode:
            raise RuntimeError(
                f"GitHub {'read' if read else 'write'} failed: {endpoint.split('?')[0]}"
            )
        # gh --paginate emits consecutive JSON values; decode without relying
        # on --slurp, which older workstation gh versions do not support.
        decoder = json.JSONDecoder()
        remaining = proc.stdout.strip()
        pages = []
        while remaining:
            page, end = decoder.raw_decode(remaining)
            pages.append(page)
            remaining = remaining[end:].strip()
        data = pages[0]
        if isinstance(data, dict) and data.get("errors"):
            raise RuntimeError("GitHub GraphQL returned errors; refusing a partial scan")
        if payload is None:
            if all(isinstance(page, list) for page in pages):
                return [item for page in pages for item in page]
            return data
        return data

    def files(self, repository: dict[str, Any]) -> dict[str, str]:
        """Pin the default-branch tree, then batch immutable blob reads."""
        name = repository["full_name"]
        branch = quote(repository["default_branch"], safe="")
        tree = self.api(f"repos/{name}/git/trees/{branch}?recursive=1")
        if tree.get("truncated"):
            raise RuntimeError(f"truncated tree: {name}; refusing a partial scan")
        blobs = [item for item in tree["tree"] if item["type"] == "blob" and selected(item["path"])]
        if any(item.get("size", 0) > MAX_BLOB for item in blobs):
            raise RuntimeError(f"oversized CI source in {name}; narrow the scope explicitly")
        owner, repo = name.split("/")
        found = {}
        for start in range(0, len(blobs), 50):
            batch = blobs[start : start + 50]
            fields = " ".join(
                f'f{i}: object(oid: {json.dumps(item["sha"])}) ' "{ ... on Blob { text isBinary } }"
                for i, item in enumerate(batch)
            )
            query = (
                f"query {{ repository(owner: {json.dumps(owner)}, "
                f"name: {json.dumps(repo)}) {{ {fields} }} }}"
            )
            response = self.api("graphql", payload={"query": query})["data"]["repository"]
            for i, item in enumerate(batch):
                blob = response[f"f{i}"]
                if not blob or blob["isBinary"] or blob["text"] is None:
                    raise RuntimeError(f"unreadable CI source in {name}")
                found[item["path"]] = blob["text"]
        return found


def references(root: Path) -> list[Unit]:
    """Use catalog entry points and their directly referenced script bodies."""
    catalog = yaml.safe_load((root / "catalog/catalog.yml").read_text())
    scripts = {
        str(path.relative_to(root)): path.read_text()
        for path in (root / "scripts").rglob("*")
        if path.is_file() and selected(str(path.relative_to(root)))
    }
    result = []
    for entry in catalog["entries"]:
        entry_id = entry["id"]
        path = (
            f".github/workflows/{entry_id}.yml"
            if entry["kind"] == "reusable-workflow"
            else f".github/actions/{entry_id}/action.yml"
        )
        source = (root / path).read_text()
        files = {path: source}
        files.update({key: value for key, value in scripts.items() if Path(key).name in source})
        result.extend(units(TARGET, False, files, entry_id))
    return result


def reconcile(
    api: GitHub,
    findings: list[tuple[str, str, str]],
    *,
    dry_run: bool,
    cap: int,
    decisions: dict[str, str] | None = None,
) -> Counter[str]:
    """Search open AND closed issues; apply the create/update/closure policy."""
    # Listing avoids search-index delays, and pagination avoids a 100-issue cap.
    issues = api.api(f"repos/{TARGET}/issues?state=all&per_page=100")
    counts: Counter[str] = Counter()
    for fingerprint, title, body in findings:
        marker = f"<!-- lgtm-ci:dup-scan:{fingerprint} -->"
        matches = [
            issue
            for issue in issues
            if "pull_request" not in issue and marker in (issue.get("body") or "")
        ]
        # A rejected candidate always wins over an accidental duplicate issue.
        rejected = any(
            issue.get("state_reason") == "not_planned" and issue["state"] == "closed"
            for issue in matches
        )
        if rejected:
            counts["suppressed"] += 1
            if decisions is not None:
                decisions[fingerprint] = "suppressed"
            continue
        issue = next(
            (item for item in matches if item["state"] == "open"), matches[0] if matches else None
        )
        action = "unchanged"
        if issue is None:
            action = "created" if counts["created"] < cap else "deferred"
        elif issue["state"] == "closed":
            action = "reopened" if issue.get("state_reason") == "completed" else "suppressed"
        elif issue.get("body") != body:
            action = "updated"
        counts[action] += 1
        if decisions is not None:
            decisions[fingerprint] = action
        if dry_run or action in {"unchanged", "suppressed", "deferred"}:
            continue
        if action == "created":
            api.api(
                f"repos/{TARGET}/issues",
                read=False,
                payload={"title": title, "body": body, "labels": ["ci", "needs-triage"]},
            )
        else:
            endpoint = f"repos/{TARGET}/issues/{issue['number']}"
            payload = {"_method": "PATCH", "body": body}
            if action == "reopened":
                payload["state"] = "open"
            api.api(endpoint, read=False, payload=payload)
            if action == "reopened":
                api.api(
                    endpoint + "/comments",
                    read=False,
                    payload={
                        "body": (
                            "The duplication scanner found this copy again on the "
                            "default branch; reopening for adoption triage."
                        )
                    },
                )
    return counts


def main() -> int:
    """Scan without writes by default and emit only public-safe Markdown."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", choices=("true", "false"), default="true")
    parser.add_argument("--threshold", type=float, default=0.8)
    parser.add_argument("--max-new-issues", type=int, default=5)
    parser.add_argument("--exceptions", type=Path, default=ROOT / "catalog/local-exceptions.yml")
    parser.add_argument(
        "--allow-missing-exceptions",
        action="store_true",
        help="provisional dry-run only, while #1236 is unmerged",
    )
    parser.add_argument("--report", type=Path, help="public-safe Markdown output (also printed)")
    args = parser.parse_args()
    dry_run = args.dry_run == "true"
    if not 0 < args.threshold <= 1 or not 0 <= args.max_new_issues <= 5:
        parser.error("threshold must be in (0, 1]; max-new-issues must be in [0, 5]")
    if args.allow_missing_exceptions and not dry_run:
        parser.error("--allow-missing-exceptions is only allowed in dry-run mode")
    if not dry_run and not os.environ.get("GH_TOKEN"):
        parser.error("live reporting requires the repository-scoped GH_TOKEN")
    provisional = not args.exceptions.exists() and args.allow_missing_exceptions
    exceptions = [] if provisional else load_exceptions(args.exceptions)
    api = GitHub()
    repos = api.api("orgs/lgtm-hq/repos?type=all&per_page=100")
    consumers = []
    scanned = []
    for repo in sorted(repos, key=lambda item: item["full_name"].lower()):
        if repo["archived"] or repo["full_name"].lower() == TARGET:
            continue
        found = units(repo["full_name"], bool(repo["private"]), api.files(repo))
        consumers.extend(unit for unit in found if not excepted(unit, exceptions))
        scanned.append(repo["full_name"])
    grouped = clusters(consumers, references(ROOT), args.threshold)
    findings = [(group[0][0].fingerprint, *render(group, args.threshold)) for group in grouped]
    decisions: dict[str, str] = {}
    counts = reconcile(api, findings, dry_run=dry_run, cap=args.max_new_issues, decisions=decisions)
    lines = [
        "# Cross-repository CI duplication scan",
        "",
        f"Mode: {'dry-run' if dry_run else 'live'}. Jaccard threshold: "
        f"{args.threshold:.3f} (initial conservative value).",
        f"Scanned {len(scanned)} repositories; {len(consumers)} units; "
        f"{len(findings)} qualifying clusters.",
        "",
        "Repositories: " + ", ".join(f"`{repo}`" for repo in scanned) + ".",
        "",
        "Issue actions"
        + (" (would perform)" if dry_run else "")
        + ": "
        + json.dumps(dict(sorted(counts.items())))
        + ".",
        "",
    ]
    if provisional:
        lines += [
            "Provisional: #1236 allowlist is absent; exceptions have NOT been applied. "
            "Live reporting is blocked.",
            "",
        ]
    for fingerprint, title, body in findings:
        lines += [f"## {title}", "", f"Issue action: {decisions[fingerprint]}.", "", body]
    report = "\n".join(lines)
    print(report)
    if args.report:
        args.report.write_text(report + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as handle:
            handle.write(report + "\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, RuntimeError, OSError, yaml.YAMLError) as error:
        # YAML parser errors contain source snippets, which could be private.
        print(
            (
                "ERROR: invalid YAML in scanned source"
                if isinstance(error, yaml.YAMLError)
                else f"ERROR: {error}"
            ),
            file=sys.stderr,
        )
        raise SystemExit(1) from None
