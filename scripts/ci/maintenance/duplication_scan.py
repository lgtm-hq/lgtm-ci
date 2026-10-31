#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Scan org CI copies and reconcile one backlog issue per normalized cluster.

Reads use GH_READ_TOKEN (or the local gh login). Writes use GH_TOKEN and are
disabled unless --dry-run=false is explicitly supplied. No repository content
is checked out or executed; private source is never persisted or logged.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from collections import Counter
from pathlib import Path
from typing import Any
from urllib.parse import quote

import yaml

from duplication_model import (
    MEMBERS_BEGIN,
    MEMBERS_END,
    Unit,
    clusters,
    excepted,
    file_units,
    load_exceptions,
    near_matches,
    render,
    selected,
    units,
)

ROOT = Path(__file__).resolve().parents[3]
TARGET = "lgtm-hq/lgtm-ci"
MAX_BLOB = 256 * 1024


class GitHubError(RuntimeError):
    """Transport failure with a status, but no potentially private response text."""

    def __init__(self, read: bool, status: int | None):
        super().__init__(
            f"GitHub {'read' if read else 'write'} failed (HTTP {status or 'unknown'})"
        )
        self.status = status


class GitHub:
    """Small gh JSON transport with separately scoped read and write tokens."""

    def __init__(self):
        self.skipped: Counter[str] = Counter()

    def api(
        self,
        endpoint: str,
        *,
        payload: Any = None,
        read: bool = True,
        source: bool = True,
    ) -> Any:
        """Read pages or send one mutation; never print response error content."""
        env = os.environ.copy()
        if read and source:
            env.pop("GITHUB_TOKEN", None)
            env.pop("GH_TOKEN", None)
            if os.environ.get("GH_READ_TOKEN"):
                env["GH_TOKEN"] = os.environ["GH_READ_TOKEN"]
        args = ["gh", "api", endpoint]
        if payload is not None:
            payload = dict(payload)
            method = payload.pop("_method", "POST")
            args += ["--method", method, "--input", "-"]
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
            status = re.search(r"HTTP (\d{3})", proc.stderr or "")
            raise GitHubError(read, int(status[1]) if status else None)
        # gh --paginate emits consecutive JSON values; decode without relying
        # on --slurp, which older workstation gh versions do not support.
        decoder = json.JSONDecoder()
        remaining = proc.stdout.strip()
        pages = []
        while remaining:
            page, end = decoder.raw_decode(remaining)
            pages.append(page)
            remaining = remaining[end:].strip()
        if not pages:
            raise RuntimeError("GitHub returned an empty response")
        data = pages[0]
        if any(isinstance(page, dict) and page.get("errors") for page in pages):
            raise RuntimeError(
                "GitHub GraphQL returned errors; refusing a partial scan"
            )
        if payload is None:
            if all(isinstance(page, list) for page in pages):
                return [item for page in pages for item in page]
            return data
        return data

    def files(self, repository: dict[str, Any]) -> dict[str, str]:
        """Pin the default-branch tree, then batch immutable blob reads."""
        name = repository["full_name"]
        branch = quote(repository["default_branch"], safe="")
        try:
            tree = self.api(f"repos/{name}/git/trees/{branch}?recursive=1")
        except GitHubError as error:
            if error.status != 409 or repository.get("size") != 0:
                raise
            self.skipped["empty repositories"] += 1
            return {}
        if not isinstance(tree, dict):
            raise RuntimeError("GitHub tree unavailable; refusing a partial inventory")
        if tree.get("truncated"):
            raise RuntimeError("truncated tree; refusing a partial inventory")
        blobs = [
            item
            for item in tree["tree"]
            if item["type"] == "blob" and selected(item["path"])
        ]
        oversized = [item for item in blobs if item.get("size", 0) > MAX_BLOB]
        self.skipped["oversized source"] += len(oversized)
        blobs = [item for item in blobs if item.get("size", 0) <= MAX_BLOB]
        owner, repo = name.split("/")
        found = {}
        for start in range(0, len(blobs), 50):
            batch = blobs[start : start + 50]
            fields = " ".join(
                f'f{i}: object(oid: {json.dumps(item["sha"])}) '
                "{ ... on Blob { text isBinary } }"
                for i, item in enumerate(batch)
            )
            query = (
                f"query {{ repository(owner: {json.dumps(owner)}, "
                f"name: {json.dumps(repo)}) {{ {fields} }} }}"
            )
            response = self.api("graphql", payload={"query": query})["data"][
                "repository"
            ]
            if not isinstance(response, dict):
                raise RuntimeError(
                    "GitHub repository unavailable; refusing a partial inventory"
                )
            for i, item in enumerate(batch):
                blob = response[f"f{i}"]
                if not blob:
                    raise RuntimeError(
                        "GitHub blob unavailable; refusing a partial inventory"
                    )
                if blob["isBinary"] or blob["text"] is None:
                    self.skipped["binary source"] += 1
                    continue
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
        # All script bodies are available to resolve nested dependencies. Only
        # entry points and scripts reached by them belong to the reference set.
        files = {path: source, **scripts}
        result.extend(file_units(TARGET, False, path, source, files, entry_id))
        for script, text in scripts.items():
            if script in source:
                result.extend(file_units(TARGET, False, script, text, files, entry_id))
    return result


def member_section(body: str) -> str:
    """Read only scanner-owned membership, supporting the original body format."""
    start = body.find(MEMBERS_BEGIN)
    end = body.find(MEMBERS_END, start)
    if start >= 0 and end >= 0:
        return body[start : end + len(MEMBERS_END)]
    match = re.search(r"(?m)^Members:\n\n(?:- [^\n]*\n)+", body)
    return match.group().rstrip() if match else ""


def membership(body: str) -> tuple[str, ...]:
    """Canonical visible member rows exclude snippets and human triage notes."""
    return tuple(sorted(re.findall(r"(?m)^- `[^\n]+", member_section(body))))


def refresh_members(existing: str, generated: str) -> str:
    """Replace just the member block, preserving all other issue text."""
    old, new = member_section(existing), member_section(generated)
    return (
        existing.replace(old, new, 1)
        if old
        else existing.rstrip() + "\n\n" + new + "\n"
    )


def has_marker(body: str, marker: str) -> bool:
    """Recognize standalone identity markers outside Markdown code fences."""
    fence = ""
    for line in body.splitlines():
        boundary = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if boundary:
            run = boundary[1]
            if not fence:
                fence = run
            elif run[0] == fence[0] and len(run) >= len(fence):
                fence = ""
        elif not fence and line == marker:
            return True
    return False


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
    issues = api.api(f"repos/{TARGET}/issues?state=all&per_page=100", source=False)
    counts: Counter[str] = Counter()
    for fingerprint, title, body in findings:
        marker = f"<!-- lgtm-ci:dup-scan:{fingerprint} -->"
        matches = [
            issue
            for issue in issues
            if "pull_request" not in issue
            and has_marker(issue.get("body") or "", marker)
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
            (item for item in matches if item["state"] == "open"),
            matches[0] if matches else None,
        )
        action = "unchanged"
        if issue is None:
            action = "created" if counts["created"] < cap else "deferred"
        elif issue["state"] == "closed":
            action = (
                "reopened" if issue.get("state_reason") == "completed" else "suppressed"
            )
        elif membership(issue.get("body") or "") != membership(body):
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
                payload={
                    "title": title,
                    "body": body,
                    "labels": ["ci", "needs-triage"],
                },
            )
        else:
            endpoint = f"repos/{TARGET}/issues/{issue['number']}"
            payload = {
                "_method": "PATCH",
                "title": title,
                "body": refresh_members(issue.get("body") or "", body),
            }
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


def encoded(value: bytes) -> bytes:
    """Encode one JWT component without padding."""
    return base64.urlsafe_b64encode(value).rstrip(b"=")


def verify_installation(app_id: str, private_key: str) -> None:
    """Read installation metadata with an App JWT; never log credential material."""
    now = int(time.time())
    header = encoded(b'{"alg":"RS256","typ":"JWT"}')
    claims = encoded(
        json.dumps({"iat": now - 60, "exp": now + 300, "iss": app_id}).encode()
    )
    message = header + b"." + claims
    with tempfile.NamedTemporaryFile() as key:
        key.write(private_key.encode())
        key.flush()
        signature = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key.name],
            input=message,
            capture_output=True,
            check=False,
        )
    if signature.returncode:
        raise RuntimeError("could not sign the source App JWT")
    env = os.environ.copy()
    env.pop("GITHUB_TOKEN", None)
    env["GH_TOKEN"] = (message + b"." + encoded(signature.stdout)).decode()
    response = subprocess.run(
        [
            "gh",
            "api",
            "orgs/lgtm-hq/installation",
            "--header",
            "Authorization: Bearer " + env["GH_TOKEN"],
        ],
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if response.returncode:
        raise RuntimeError("could not verify the source App installation")
    installation = json.loads(response.stdout)
    if installation.get("repository_selection") != "all":
        raise RuntimeError(
            "source App must be installed on all organization repositories"
        )
    if installation.get("permissions", {}).get("contents") != "read":
        raise RuntimeError("source App must have Contents: read")


def check_readiness() -> int:
    """Publish readiness without failing when setup prerequisites are absent."""
    app_id = os.environ.get("DUPLICATION_SCAN_APP_ID", "")
    private_key = os.environ.get("DUPLICATION_SCAN_APP_PRIVATE_KEY", "")
    ready = bool(
        app_id and private_key and (ROOT / "catalog/local-exceptions.yml").is_file()
    )
    if ready:
        verify_installation(app_id, private_key)
    else:
        print(
            "Duplication scan skipped: source App secrets or "
            "local-exceptions.yml are absent."
        )
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write(f"ready={str(ready).lower()}\n")
    return 0


def main() -> int:
    """Scan without writes by default and emit only public-safe Markdown."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check-readiness", action="store_true", help="CI prerequisite check only"
    )
    parser.add_argument("--dry-run", choices=("true", "false"), default="true")
    parser.add_argument("--threshold", type=float, default=0.8)
    parser.add_argument("--max-new-issues", type=int, default=5)
    parser.add_argument(
        "--exceptions", type=Path, default=ROOT / "catalog/local-exceptions.yml"
    )
    parser.add_argument(
        "--allow-missing-exceptions",
        action="store_true",
        help="provisional dry-run only, while #1236 is unmerged",
    )
    parser.add_argument(
        "--report", type=Path, help="public-safe Markdown output (also printed)"
    )
    args = parser.parse_args()
    if args.check_readiness:
        return check_readiness()
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
    private_count = 0
    for repo in sorted(repos, key=lambda item: item["full_name"].lower()):
        if repo["archived"] or repo["full_name"].lower() == TARGET:
            continue
        found = units(
            repo["full_name"],
            bool(repo["private"]),
            api.files(repo),
            skipped=api.skipped,
        )
        consumers.extend(unit for unit in found if not excepted(unit, exceptions))
        scanned.append(repo["full_name"] if not repo["private"] else None)
        private_count += bool(repo["private"])
    catalog = references(ROOT)
    grouped = clusters(consumers, catalog, args.threshold)
    suggestions = near_matches(consumers, catalog, args.threshold)
    findings = [
        (group[0][0].fingerprint, *render(group, args.threshold)) for group in grouped
    ]
    decisions: dict[str, str] = {}
    counts = reconcile(
        api, findings, dry_run=dry_run, cap=args.max_new_issues, decisions=decisions
    )
    lines = [
        "# Cross-repository CI duplication scan",
        "",
        f"Mode: {'dry-run' if dry_run else 'live'}. Near-match Jaccard threshold: "
        f"{args.threshold:.3f}. Automatic issues require exact normalized structure.",
        f"Scanned {len(scanned)} repositories; {len(consumers)} units; "
        f"{len(findings)} qualifying clusters.",
        "",
        "Public repositories: "
        + ", ".join(f"`{repo}`" for repo in scanned if repo)
        + ".",
        f"Private repositories: {private_count} "
        "(names appear only in qualifying members).",
        "",
        "Issue actions"
        + (" (would perform)" if dry_run else "")
        + ": "
        + json.dumps(dict(sorted(counts.items())))
        + ".",
        "",
    ]
    skipped = {reason: count for reason, count in sorted(api.skipped.items()) if count}
    if skipped:
        lines += ["Skipped: " + json.dumps(skipped) + ".", ""]
        if any(reason != "empty repositories" for reason in skipped):
            lines += [
                "Partial scan: unreadable units were omitted; review before adoption.",
                "",
            ]
    if provisional:
        lines += [
            "Provisional: #1236 allowlist is absent; exceptions have NOT been applied. "
            "Live reporting is blocked.",
            "",
        ]
    for fingerprint, title, body in findings:
        lines += [
            f"## {title}",
            "",
            f"Issue action: {decisions[fingerprint]}.",
            "",
            body,
        ]
    if suggestions:
        lines += ["## Public near matches (manual review only; no issues)", ""]
        for left, right, score in suggestions:
            lines += [
                f"- `{left.repository}`: `{left.path}` and `{right.repository}`: "
                f"`{right.path}`; Jaccard {score:.3f}. Differences need inspection."
            ]
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
    except (
        ValueError,
        RuntimeError,
        OSError,
        yaml.YAMLError,
        TypeError,
        KeyError,
    ) as error:
        # YAML parser errors contain source snippets, which could be private.
        print(
            (
                "ERROR: invalid YAML in scanned source"
                if isinstance(error, yaml.YAMLError)
                else (
                    "ERROR: invalid GitHub response or source structure"
                    if isinstance(error, (TypeError, KeyError))
                    else f"ERROR: {error}"
                )
            ),
            file=sys.stderr,
        )
        raise SystemExit(1) from None
