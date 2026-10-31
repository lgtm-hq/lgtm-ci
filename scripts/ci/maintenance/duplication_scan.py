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

# Sibling imports also work when the script is loaded by offline test helpers.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from duplication_model import (  # noqa: E402  # pylint: disable=wrong-import-position
    MEMBERS_BEGIN,
    MEMBERS_END,
    Unit,
    clusters,
    excepted,
    file_units,
    load_exceptions,
    near_matches,
    render,
    safe_text,
    selected,
    units,
)
from duplication_sources import (  # noqa: E402  # pylint: disable=wrong-import-position
    dependency_names,
)

ROOT = Path(__file__).resolve().parents[3]
TARGET = "lgtm-hq/lgtm-ci"
MAX_BLOB = 256 * 1024
PUBLIC_EXAMPLE = re.compile(
    r"^Public example from `(?P<repository>[^`\r\n]+)`:\r?\n\r?\n"
    r"(?P<fence>`{3,})\r?\n[\s\S]*?^(?P=fence)\r?$",
    re.MULTILINE,
)


class GitHubError(RuntimeError):
    """Transport failure with a status, but no potentially private response text."""

    def __init__(self, read: bool, status: int | None) -> None:
        super().__init__(
            f"GitHub {'read' if read else 'write'} failed (HTTP {status or 'unknown'})"
        )
        self.status = status


class GitHub:
    """Small gh JSON transport with separately scoped read and write tokens."""

    def __init__(self) -> None:
        self.skipped: Counter[str] = Counter()
        # Freeze the credential used for both coverage proof and source reads.
        self.source_token = os.environ.get("GH_READ_TOKEN")

    @property
    def partial(self) -> bool:
        """Known empty repos are harmless; omitted source prevents reconciliation."""
        return sum(self.skipped.values()) > self.skipped["empty repositories"]

    def api(
        self,
        endpoint: str,
        *,
        payload: Any = None,
        read: bool = True,
        source: bool = True,
        all_pages: bool = False,
    ) -> Any:
        """Read pages or send one mutation; never print response error content."""
        env = os.environ.copy()
        if read and source:
            env.pop("GITHUB_TOKEN", None)
            env.pop("GH_TOKEN", None)
            if self.source_token:
                env["GH_TOKEN"] = self.source_token
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
        pages: list[Any] = []
        while remaining:
            page, end = decoder.raw_decode(remaining)
            pages.append(page)
            remaining = remaining[end:].strip()
        if not pages:
            raise RuntimeError("GitHub returned an empty response")
        if any(isinstance(page, dict) and page.get("errors") for page in pages):
            raise RuntimeError(
                "GitHub GraphQL returned errors; refusing a partial scan",
            )
        if all_pages:
            return pages
        if payload is None and all(isinstance(page, list) for page in pages):
            return [item for page in pages for item in page]
        if len(pages) != 1:
            raise RuntimeError("GitHub returned inconsistent pagination metadata")
        return pages[0]

    def verify_source_coverage(self, repositories: list[dict[str, Any]]) -> None:
        """Require all-repository grants reported for this scan's source token.

        A successful org listing alone proves only visibility. The installation
        endpoint authenticates the actual source credential, independently of
        optional readiness or the App JWT. Missing selection metadata is not
        evidence of complete coverage. Check every page and compare inventories
        so missing pages, narrowed grants and concurrent inventory changes fail.
        """
        self.skipped["unverified repository coverage"] += 1
        pages = self.api("installation/repositories?per_page=100", all_pages=True)
        inventory: list[dict[str, Any]] = []
        total: int | None = None
        for page in pages:
            if (
                not isinstance(page, dict)
                or page.get("repository_selection") != "all"
                or type(page.get("total_count")) is not int
                or page["total_count"] <= 0
                or not isinstance(page.get("repositories"), list)
                or (total is not None and total != page["total_count"])
            ):
                raise RuntimeError(
                    "source credential lacks verified all-repository coverage",
                )
            total = page["total_count"]
            inventory.extend(page["repositories"])
        identities = repository_identities(inventory)
        if len(inventory) != total or identities != repository_identities(repositories):
            raise RuntimeError(
                "source installation and organization inventories disagree",
            )
        del self.skipped["unverified repository coverage"]

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
        blobs = (item for item in tree["tree"] if item["type"] == "blob")
        inventory = {item["path"]: item for item in blobs}
        pending = {path for path in inventory if selected(path)}
        seen: set[str] = set()
        found: dict[str, str] = {}
        while pending:
            seen.update(pending)
            fetched = self.read_blobs(
                name,
                [inventory[path] for path in sorted(pending)],
            )
            found.update(fetched)
            names = dependency_names(fetched)
            pending = {
                path
                for path in inventory
                if path not in seen
                and any(path == name or path.endswith("/" + name) for name in names)
            }
        return found

    def read_blobs(self, name: str, blobs: list[dict[str, Any]]) -> dict[str, str]:
        """Read a bounded batch of dependencies without executing source."""
        self.skipped["oversized source"] += sum(
            (item.get("size", 0) > MAX_BLOB for item in blobs),
        )
        blobs = [item for item in blobs if item.get("size", 0) <= MAX_BLOB]
        owner, repo = name.split("/")
        found: dict[str, str] = {}
        for start in range(0, len(blobs), 50):
            batch = blobs[start : start + 50]
            fields = " ".join(
                f"f{i}: object(oid: {json.dumps(item['sha'])}) "
                + "{ ... on Blob { text isBinary } }"
                for i, item in enumerate(batch)
            )
            query = (
                f"query {{ repository(owner: {json.dumps(owner)}, "
                f"name: {json.dumps(repo)}) {{ {fields} }} }}"
            )
            data = self.api("graphql", payload={"query": query})
            response = data["data"]["repository"]
            if not isinstance(response, dict):
                raise RuntimeError(
                    "GitHub repository unavailable; refusing a partial inventory",
                )
            for i, item in enumerate(batch):
                blob = response[f"f{i}"]
                if not blob:
                    raise RuntimeError(
                        "GitHub blob unavailable; refusing a partial inventory",
                    )
                if blob["isBinary"] or blob["text"] is None:
                    self.skipped["binary source"] += 1
                    continue
                found[item["path"]] = blob["text"]
        return found


def repository_identities(
    repositories: list[dict[str, Any]],
) -> set[tuple[int, str, int]]:
    """Validate org ownership and reject duplicate or unusable inventory rows."""
    identities: set[tuple[int, str, int]] = set()
    names: set[str] = set()
    identifiers: set[int] = set()
    owners: set[int] = set()
    for repo in repositories:
        owner = repo.get("owner") if isinstance(repo, dict) else None
        if (
            not isinstance(repo, dict)
            or type(repo.get("id")) is not int
            or repo["id"] <= 0
            or not isinstance(repo.get("full_name"), str)
            or not re.fullmatch(r"lgtm-hq/[\w.-]+", repo["full_name"], re.IGNORECASE)
            or not isinstance(owner, dict)
            or type(owner.get("id")) is not int
            or owner["id"] <= 0
            or not isinstance(owner.get("login"), str)
            or owner["login"].casefold() != "lgtm-hq"
            or owner.get("type") != "Organization"
            or type(repo.get("private")) is not bool
            or type(repo.get("archived")) is not bool
            or type(repo.get("fork", False)) is not bool
            or not isinstance(repo.get("default_branch"), str)
            or not repo["default_branch"]
        ):
            raise RuntimeError("invalid source organization repository metadata")
        name = repo["full_name"].casefold()
        if repo["id"] in identifiers or name in names:
            raise RuntimeError("duplicate source organization repository metadata")
        identifiers.add(repo["id"])
        names.add(name)
        owners.add(owner["id"])
        identities.add((repo["id"], name, owner["id"]))
    if len(owners) != 1:
        raise RuntimeError("unverified source organization ownership")
    return identities


def references(root: Path) -> list[Unit]:
    """Use catalog entry points and their directly referenced script bodies."""
    catalog = yaml.safe_load((root / "catalog/catalog.yml").read_text())
    if not isinstance(catalog, dict) or not isinstance(catalog.get("entries"), list):
        raise ValueError("catalog requires an entries list")
    files = {
        str(path.relative_to(root)): path.read_text()
        for base in ("scripts", ".github/actions")
        for path in (root / base).rglob("*")
        if path.is_file() and selected(str(path.relative_to(root)))
    }
    entrypoints: list[tuple[str, str]] = []
    for entry in catalog["entries"]:
        entry_id = entry["id"]
        path = (
            f".github/workflows/{entry_id}.yml"
            if entry["kind"] == "reusable-workflow"
            else f".github/actions/{entry_id}/action.yml"
        )
        files[path] = (root / path).read_text(encoding="utf-8")
        entrypoints.append((entry_id, path))
    pending = files.copy()
    while pending:
        fetched = {}
        for name in dependency_names(pending):
            for dependency in root.glob(f"**/{name}"):
                relative = str(dependency.relative_to(root))
                if (
                    dependency.is_file()
                    and relative not in files
                    and dependency.stat().st_size <= MAX_BLOB
                ):
                    fetched[relative] = dependency.read_text(encoding="utf-8")
        files.update(fetched)
        pending = fetched
    result: list[Unit] = []
    for entry_id, path in entrypoints:
        # All script bodies are available to resolve nested dependencies. Only
        # entry points and scripts reached by them belong to the reference set.
        result.extend(file_units(TARGET, False, path, files[path], files, entry_id))
        for script, text in files.items():
            if script in files[path]:
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
    section = member_section(body.replace("\r\n", "\n"))
    return tuple(sorted(re.findall(r"(?m)^- `[^\n]+", section)))


def refreshed_title(existing: str, generated: str) -> str:
    """Refresh only generated counts, preserving maintainer title edits."""
    pattern = "".join(
        (
            r"^refactor\(adoption\): (?:move .+ into|adopt .+ from) ",
            r"lgtm-ci (\(\d+ repos?\))$",
        )
    )
    if not existing:
        return generated
    old, new = re.fullmatch(pattern, existing), re.fullmatch(pattern, generated)
    return existing[: old.start(1)] + new[1] if old and new else existing


def refresh_members(existing: str, generated: str) -> str:
    """Replace just the member block, preserving all other issue text."""
    old, new = member_section(existing), member_section(generated)
    if old:
        return existing.replace(old, new, 1)
    return existing.rstrip() + "\n\n" + new + "\n"


def refresh_public_source(existing: str, generated: str) -> str:
    """Retain historical source only when its origin is still publicly rendered."""
    # Recognize the original generated format, including web-edited CRLF and
    # fences longer than source backtick runs. Leave surrounding human text alone.
    old, new = PUBLIC_EXAMPLE.search(existing), PUBLIC_EXAMPLE.search(generated)
    if old is None or (new and old["repository"] == new["repository"]):
        return existing
    # Input names came from the same public example and need the same recheck.
    inputs = re.compile(r"^Action input names: [^\r\n]*\r?\n", re.MULTILINE)
    current_inputs = inputs.search(generated[: new.start()] if new else "")
    prefix = inputs.sub(
        lambda _: current_inputs.group() if current_inputs else "",
        existing[: old.start()],
    )
    return prefix + (new.group() if new else "") + existing[old.end() :]


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


def redact_historical_body(
    existing: str,
    public_repositories: set[str],
    generated: str,
) -> str:
    """Keep source and job details only for verifiably public repositories."""

    def redact_job(match: re.Match[str]) -> str:
        if match[2].casefold() in public_repositories:
            return match.group()
        return match[1]

    refreshed = existing
    example = PUBLIC_EXAMPLE.search(existing)
    origin = example["repository"].casefold() if example else ""
    if origin not in public_repositories:
        refreshed = refresh_public_source(existing, generated)
        if example is None:
            inputs = r"(?m)^Action input names: [^\r\n]*\r?\n"
            refreshed = re.sub(inputs, "", refreshed)
    # Retain historical membership even when source coverage is partial.
    # Remove only job names whose repository is no longer provably public.
    section = member_section(refreshed)
    redacted = re.sub(
        r"(?m)^(- `([^`\r\n]+)`: `[^`\r\n]+`) \(job `[^`\r\n]+`\)",
        redact_job,
        section,
    )
    return refreshed.replace(section, redacted, 1) if section else refreshed


def historical_issues(
    api: GitHub,
    findings: list[tuple[str, str, str]],
    *,
    public_repositories: set[str] | None,
    dry_run: bool,
) -> tuple[list[dict[str, Any]], Counter[str]]:
    """Read every issue page and apply visibility-based cleanup before matching."""
    counts: Counter[str] = Counter()
    if public_repositories is None and api.partial:
        return [], counts
    # Listing avoids search-index delays and includes open/closed issues.
    issues = api.api(f"repos/{TARGET}/issues?state=all&per_page=100", source=False)
    issues = [issue for issue in issues if "pull_request" not in issue]
    if public_repositories is None:
        return issues, counts
    public = {safe_text(repo).casefold() for repo in public_repositories}
    generated = {}
    for fingerprint, _, body in findings:
        generated[f"<!-- lgtm-ci:dup-scan:{fingerprint} -->"] = body
    for issue in issues:
        existing = issue.get("body") or ""
        markers = re.findall(r"<!-- lgtm-ci:dup-scan:[a-f0-9]{24} -->", existing)
        marker = next((item for item in markers if has_marker(existing, item)), "")
        if not marker:
            continue
        refreshed = redact_historical_body(existing, public, generated.get(marker, ""))
        if refreshed == existing:
            continue
        counts["redacted"] += 1
        if not dry_run:
            api.api(
                f"repos/{TARGET}/issues/{issue['number']}",
                read=False,
                payload={"_method": "PATCH", "body": refreshed},
            )
        # Reconciliation should reason from the sanitized body in both modes.
        issue["body"] = refreshed
    return issues, counts


# Keep coverage and create/update/reopen policy together to review mutations.
# pylint: disable-next=too-many-locals,too-many-branches,too-many-arguments
def reconcile(
    api: GitHub,
    findings: list[tuple[str, str, str]],
    *,
    dry_run: bool,
    cap: int,
    decisions: dict[str, str] | None = None,
    public_repositories: set[str] | None = None,
) -> Counter[str]:
    """Search open AND closed issues; apply the create/update/closure policy."""
    issues, counts = historical_issues(
        api, findings, public_repositories=public_repositories, dry_run=dry_run
    )
    if api.partial:
        if decisions is not None:
            decisions.update((fingerprint, "blocked") for fingerprint, _, _ in findings)
        counts["blocked"] = len(findings)
        return counts
    for fingerprint, title, body in findings:
        marker = f"<!-- lgtm-ci:dup-scan:{fingerprint} -->"
        bodies = ((issue, issue.get("body") or "") for issue in issues)
        matches = [issue for issue, text in bodies if has_marker(text, marker)]
        # A rejected candidate always wins over an accidental duplicate issue.
        rejected = any(
            issue.get("state_reason") == "not_planned" and issue["state"] == "closed"
            for issue in matches
        )
        issue = next(
            (item for item in matches if item["state"] == "open"),
            matches[0] if matches else None,
        )
        action = "unchanged"
        if rejected:
            action = "suppressed"
        elif issue is None:
            action = "created" if counts["created"] < cap else "deferred"
        elif issue["state"] == "closed":
            completed = issue.get("state_reason") == "completed"
            action = "reopened" if completed else "suppressed"
        else:
            existing_body = issue.get("body") or ""
            existing_title = issue.get("title", "")
            if (
                membership(existing_body) != membership(body)
                or refreshed_title(existing_title, title) != existing_title
                or refresh_public_source(existing_body, body) != existing_body
            ):
                action = "updated"
        counts[action] += 1
        if decisions is not None:
            decisions[fingerprint] = action
        # Privacy cleanup applies to every match, including rejected/otherwise
        # suppressed closures and accidental duplicates. Only the active issue
        # may receive membership/title/state changes through the policy below.
        for matched in matches:
            if matched is issue and action in {"updated", "reopened"}:
                continue
            existing = matched.get("body") or ""
            refreshed = refresh_public_source(existing, body)
            if refreshed != existing:
                counts["redacted"] += 1
                if not dry_run:
                    api.api(
                        f"repos/{TARGET}/issues/{matched['number']}",
                        read=False,
                        payload={"_method": "PATCH", "body": refreshed},
                    )
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
            assert issue is not None
            endpoint = f"repos/{TARGET}/issues/{issue['number']}"
            public_body = refresh_public_source(issue.get("body") or "", body)
            payload = {
                "_method": "PATCH",
                "title": refreshed_title(issue.get("title", ""), title),
                "body": refresh_members(public_body, body),
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
        json.dumps({"iat": now - 60, "exp": now + 300, "iss": app_id}).encode(),
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
    try:
        installation = json.loads(response.stdout)
    except json.JSONDecodeError:
        raise RuntimeError("invalid source App installation response") from None
    if not isinstance(installation, dict):
        raise RuntimeError("invalid source App installation response")
    if installation.get("repository_selection") != "all":
        raise RuntimeError(
            "source App must be installed on all organization repositories",
        )
    permissions = installation.get("permissions")
    if not isinstance(permissions, dict) or any(
        not isinstance(name, str) or not name or level != "read"
        for name, level in permissions.items()
    ):
        raise RuntimeError("source App permissions must be a read-only mapping")
    if permissions.get("contents") != "read":
        raise RuntimeError("source App must have Contents: read")


def check_readiness() -> int:
    """Publish readiness without failing when setup prerequisites are absent."""
    app_id = os.environ.get("DUPLICATION_SCAN_APP_ID", "")
    private_key = os.environ.get("DUPLICATION_SCAN_APP_PRIVATE_KEY", "")
    ready = bool(
        app_id and private_key and (ROOT / "catalog/local-exceptions.yml").is_file(),
    )
    if ready:
        load_exceptions(ROOT / "catalog/local-exceptions.yml")
        verify_installation(app_id, private_key)
    else:
        print(
            "Duplication scan skipped: source App secrets or allowlist absent.",
        )
    result = f"ready={str(ready).lower()}\n"
    if os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
            output.write(result)
    else:
        print(result, end="")
    return 0


# The CLI composes inventory, matching and reporting without persisting source.
# pylint: disable-next=too-many-locals,too-many-branches,too-many-statements
def main() -> int:
    """Scan without writes by default and emit only public-safe Markdown."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check-readiness",
        action="store_true",
        help="CI prerequisite check only",
    )
    parser.add_argument("--dry-run", choices=("true", "false"), default="true")
    parser.add_argument("--threshold", type=float, default=0.8)
    parser.add_argument("--max-new-issues", type=int, default=5)
    parser.add_argument(
        "--exceptions",
        type=Path,
        default=ROOT / "catalog/local-exceptions.yml",
    )
    parser.add_argument(
        "--allow-missing-exceptions",
        action="store_true",
        help="provisional dry-run only, while #1236 is unmerged",
    )
    parser.add_argument(
        "--report",
        type=Path,
        help="public-safe Markdown output (also printed)",
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
    if not isinstance(repos, list) or any(not isinstance(repo, dict) for repo in repos):
        raise RuntimeError("invalid organization repository inventory")
    # Missing visibility is never evidence that historical source remains public.
    public = {
        repo["full_name"]
        for repo in repos
        if repo.get("private") is False and isinstance(repo.get("full_name"), str)
    }
    try:
        api.verify_source_coverage(repos)
    except (RuntimeError, ValueError, KeyError, TypeError):
        historical_issues(api, [], public_repositories=public, dry_run=dry_run)
        raise
    consumers: list[Unit] = []
    scanned: list[str | None] = []
    private_count = 0
    for repo in sorted(repos, key=lambda item: item["full_name"].lower()):
        if repo["archived"] or repo.get("fork") or repo["full_name"].lower() == TARGET:
            continue
        try:
            files = api.files(repo)
        except (RuntimeError, ValueError, KeyError, TypeError):
            # Source inventory errors block reconciliation, but visibility is
            # already known. Sanitize historical issues, then fail the scan.
            historical_issues(api, [], public_repositories=public, dry_run=dry_run)
            raise
        found = units(
            repo["full_name"],
            bool(repo["private"]),
            files,
            skipped=api.skipped,
        )
        consumers.extend(unit for unit in found if not excepted(unit, exceptions))
        scanned.append(repo["full_name"] if not repo["private"] else None)
        private_count += bool(repo["private"])
    catalog = references(ROOT)
    grouped = clusters(consumers, catalog, args.threshold)
    suggestions = near_matches(consumers, catalog, args.threshold)
    findings = [
        (
            group[0][0].fingerprint,
            *render(group, args.threshold),
        )
        for group in grouped
    ]
    decisions: dict[str, str] = {}
    counts = reconcile(
        api,
        findings,
        dry_run=dry_run,
        cap=args.max_new_issues,
        decisions=decisions,
        public_repositories=public,
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
        + ", ".join(f"`{safe_text(repo)}`" for repo in scanned if repo)
        + ".",
        f"Private repositories: {private_count} (listed only in qualifying members).",
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
        if api.partial:
            lines += [
                "Partial scan: omitted source; cluster reconciliation is blocked. "
                "Only independent privacy redactions are permitted.",
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
                f"- `{safe_text(left.repository)}`: `{safe_text(left.path)}` and "
                f"`{safe_text(right.repository)}`: `{safe_text(right.path)}`; "
                f"Jaccard {score:.3f}. Differences need inspection."
            ]
    report = "\n".join(lines)
    print(report)
    if args.report:
        args.report.write_text(report + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open(
            "a",
            encoding="utf-8",
        ) as handle:
            handle.write(report + "\n")
    return 1 if api.partial and not dry_run else 0


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
