#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Reconcile Actions attempts without inferring logical identity from job names.

Stable-name retries retain every job in the newest attempt, including shared-name
matrix legs. Renamed cancellations need stronger evidence. The legacy CodeQL
contract below recognizes immutable, audited workflow/generator bytes and the
runner's pre-step receipts in BOTH attempts. Unsupported graphs stay closed.
"""

import base64
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

# Historical source contracts, not mutable release tags. These exact bytes have
# two jobs: setup, then inputs.job-name over generate-codeql-matrix.sh's output.
# Changing the source requires a separately reviewed contract; matching a path or
# a successful sibling alone never authorizes erasing a cancelled check.
CODEQL_WORKFLOW = "6c35627c2f21854dffe97debf9fe70d5a803c43c91e0075f26c965ac895a3938"
CODEQL_GENERATOR = "300d904aabdb1131318e3e46a6be4f8d29784cede4712b1a49c7c9f96d8ac9cd"
CODEQL_PATH = "lgtm-hq/lgtm-ci/.github/workflows/reusable-codeql.yml"
TIMESTAMP = re.compile(r"^\ufeff?\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+Z ")


def api(endpoint: str, work: Path, *, paginate: bool = False, log: bool = False) -> str:
    """Fetch bounded evidence, retaining stderr for the gate's rate-limit logic."""
    args = ["gh", "api", endpoint]
    if paginate:
        args.append("--paginate")
    if log:
        # New gh versions reject ANSI in logs unless explicitly enabled. Older
        # versions predate this flag, so probe the local CLI, not the network.
        help_result = subprocess.run(
            ["gh", "api", "--help"],
            capture_output=True,
            text=True,
            timeout=int(os.environ["GH_CMD_TIMEOUT"]),
            check=True,
        )
        if "--allow-escape-sequences" in help_result.stdout:
            args.append("--allow-escape-sequences")
    with (work / "gh.err").open("a") as error_log:
        result = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=error_log,
            text=True,
            timeout=int(os.environ["GH_CMD_TIMEOUT"]),
            check=True,
        )
    return result.stdout


def jobs_for_run(run: dict[str, Any], work: Path) -> list[dict[str, Any]]:
    """Validate complete pagination and immutable run/attempt/head membership."""
    raw = api(
        f"repos/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{run['id']}"
        "/jobs?filter=all&per_page=100",
        work=work,
        paginate=True,
    )
    pages = []
    decoder = json.JSONDecoder()
    while raw.strip():
        page, end = decoder.raw_decode(raw.lstrip())
        pages.append(page)
        raw = raw.lstrip()[end:]
    if not pages or any(
        not isinstance(p.get("total_count"), int) or isinstance(p["total_count"], bool)
        for p in pages
    ):
        raise ValueError("missing job pagination metadata")
    total = pages[0]["total_count"]
    jobs = [j for page in pages for j in page["jobs"]]
    if (
        not jobs
        or len(jobs) != total
        or any(p["total_count"] != total for p in pages)
        or len({j["id"] for j in jobs}) != total
    ):
        raise ValueError("incomplete or inconsistent job pagination")
    for job in jobs:
        if (
            job["run_id"] != run["id"]
            or job["head_sha"] != run["head_sha"]
            or not isinstance(job["run_attempt"], int)
            or isinstance(job["run_attempt"], bool)
            or not 1 <= job["run_attempt"] <= run["run_attempt"]
        ):
            raise ValueError("job does not belong to the expected run attempt")
    return jobs


def header(job: dict[str, Any], work: Path) -> tuple[str, dict[str, str]] | None:
    """Read only the runner-generated reusable receipt, before any step runs."""
    path = work / f"receipt-{job['id']}.txt"
    if not path.exists():
        repo = os.environ["GITHUB_REPOSITORY"]
        path.write_text(
            api(
                f"repos/{repo}/actions/jobs/{job['id']}/logs",
                work=work,
                log=True,
            )
        )
    lines = []
    for raw in path.read_text().splitlines():
        if not TIMESTAMP.match(raw):
            # Empty continuation lines occur in real allowed-endpoints values.
            # Nonempty continuations must never truncate a matrix/identity field.
            if raw.strip():
                lines.append("\0")
            continue
        line = TIMESTAMP.sub("", raw)
        if line.startswith("##[group]Run "):
            return None
        lines.append(line)
        if line.startswith("Complete job name: "):
            break
    indices = [i for i, line in enumerate(lines) if line.startswith("Uses: ")]
    if len(indices) != 1:
        return None  # unknown or nested/ambiguous reusable chain
    tail = lines[indices[0] + 1 :]
    if tail[:1] != ["##[group] Inputs"] or tail[-2:] != [
        "##[endgroup]",
        f"Complete job name: {job['name']}",
    ]:
        return None
    inputs = receipt_inputs(tail[1:-2])
    return (lines[indices[0]].removeprefix("Uses: "), inputs) if inputs else None


def receipt_inputs(lines: list[str]) -> dict[str, str] | None:
    """Parse an unambiguous scalar input block, rejecting duplicate keys."""
    inputs: dict[str, str] = {}
    for line in lines:
        match = re.fullmatch(r"  ([a-z][a-z0-9-]*): (.*)", line)
        if not match or match[1] in inputs:
            return None
        inputs[match[1]] = match[2]
    return inputs


def supported_source(uses: str, inputs: dict[str, str], work: Path) -> bool:
    """Verify exact immutable bytes; never execute fetched workflow/generator code."""
    match = re.fullmatch(re.escape(CODEQL_PATH) + r"@([0-9a-f]{40})", uses)
    if not match or inputs.get("tooling-ref", "") not in ("", match[1]):
        return False
    for source, digest in (
        (".github/workflows/reusable-codeql.yml", CODEQL_WORKFLOW),
        ("scripts/ci/actions/generate-codeql-matrix.sh", CODEQL_GENERATOR),
    ):
        cached = work / f"source-{match[1]}-{digest}.json"
        if not cached.exists():
            cached.write_text(
                api(
                    f"repos/lgtm-hq/lgtm-ci/contents/{source}?ref={match[1]}",
                    work=work,
                )
            )
        record = json.loads(cached.read_text())
        if record["encoding"] != "base64":
            return False
        content = base64.b64decode(record["content"].replace("\n", ""), validate=True)
        if hashlib.sha256(content).hexdigest() != digest:
            return False
    return True


def single_coordinate(inputs: dict[str, str]) -> bool:
    """Recognize only one explicit CodeQL matrix coordinate and a scalar name."""
    name = inputs.get("job-name", "")
    valid_name = (
        bool(name)
        and not any(c in name for c in "\r\n${}")
        and name not in ("inputs.job-name", "Setup CodeQL matrix")
    )
    return bool(
        valid_name
        and re.fullmatch(r"[a-z][a-z0-9-]*", inputs.get("languages", "").strip())
        and inputs.get("build-mode") in ("none", "manual", "autobuild")
        and inputs.get("language-build-modes", "") == ""
    )


def replacement_proven(
    old: dict[str, Any],
    jobs: list[dict[str, Any]],
    run: dict[str, Any],
    work: Path,
) -> bool:
    """Require both attempts' unique two-job graph and source/input receipts."""
    prefix = old["name"].removesuffix("inputs.job-name")
    group = [j for j in jobs if j["name"].startswith(prefix)]
    prior_jobs = [j for j in group if j["run_attempt"] == old["run_attempt"]]
    current = [j for j in group if j["run_attempt"] == run["run_attempt"]]
    setups = [j for j in prior_jobs if j["name"] == prefix + "Setup CodeQL matrix"]
    if len(prior_jobs) != 2 or len(current) != 2 or len(setups) != 1:
        return False
    prior = header(job=setups[0], work=work)
    if prior is None:
        return False
    uses, inputs = prior
    references = run.get("referenced_workflows", [])
    identities = {(r.get("path"), r.get("sha")) for r in references}
    if (uses, uses.rsplit("@", 1)[-1]) not in identities:
        return False
    if {j["name"] for j in current} != {
        prefix + "Setup CodeQL matrix",
        prefix + inputs.get("job-name", ""),
    }:
        return False
    if not all(
        j["status"] == "completed"
        and j["conclusion"] == "success"
        and j.get("runner_id")
        and j.get("steps")
        for j in current
    ):
        return False
    return (
        single_coordinate(inputs)
        and all(header(job=j, work=work) == prior for j in current)
        and supported_source(uses=uses, inputs=inputs, work=work)
    )


def recovered_placeholders(
    run: dict[str, Any],
    jobs: list[dict[str, Any]],
    work: Path,
) -> set[int]:
    """Prove single-leg replacements; never guess unexpanded matrix coordinates."""
    recovered: set[int] = set()
    for old in jobs:
        unstarted = old.get("runner_id") is None and old.get("steps") == []
        candidate = (
            old["run_attempt"] < run["run_attempt"]
            and old["conclusion"] == "cancelled"
            and old["status"] == "completed"
            and unstarted
            and old["name"].endswith(" / inputs.job-name")
        )
        if candidate and replacement_proven(old=old, jobs=jobs, run=run, work=work):
            recovered.add(old["id"])
    return recovered


def bind_jobs(
    run: dict[str, Any],
    jobs: list[dict[str, Any]],
    checks: list[dict[str, Any]],
) -> None:
    """Bind every observed job to its exact check, retaining current matrix IDs."""
    repo = os.environ["GITHUB_REPOSITORY"]
    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    server_url = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    url_prefix = f"{api_url}/repos/{repo}/check-runs/"
    job_url_prefix = f"{server_url}/{repo}/actions/runs/{run['id']}/job/"
    by_check = {c["id"]: c for c in checks}
    bound: set[int] = set()
    for job in jobs:
        suffix = job["check_run_url"].removeprefix(url_prefix)
        if not job["check_run_url"].startswith(url_prefix) or not suffix.isdigit():
            raise ValueError("invalid job/check association")
        check_id = int(suffix)
        expected = {k: job[k] for k in ("name", "status", "conclusion")}
        expected.update(
            app="github-actions",
            suite=run["check_suite_id"],
            head_sha=run["head_sha"],
            url=f"{job_url_prefix}{job['id']}",
        )
        matches = all(by_check[check_id][k] == v for k, v in expected.items())
        if check_id in bound or not matches:
            raise ValueError("inconsistent job/check association")
        bound.add(check_id)
        # Actions job IDs and check IDs are distinct API identities.
        job["check_id"] = check_id
        by_check[check_id]["attempt"] = job["run_attempt"]
    if any(
        c["app"] == "github-actions"
        and c["suite"] == run["check_suite_id"]
        and c["url"].startswith(job_url_prefix)
        and c["id"] not in bound
        for c in checks
    ):
        raise ValueError("check absent from complete attempt membership")


def reconcile(work: Path) -> None:
    """Annotate exact job attempts and remove only proven placeholder IDs."""
    checks = json.loads((work / "checks.json").read_text())
    runs = json.loads((work / "retry-runs.json").read_text())
    removed: set[int] = set()
    for run in runs:
        if run["head_sha"] != os.environ["HEAD_SHA"]:
            raise ValueError("workflow head does not match gated commit")
        jobs = jobs_for_run(run=run, work=work)
        bind_jobs(run=run, jobs=jobs, checks=checks)
        if run["status"] == "completed" and run["conclusion"] == "success":
            recovered = recovered_placeholders(run=run, jobs=jobs, work=work)
            removed.update(j["check_id"] for j in jobs if j["id"] in recovered)
    retained = [c for c in checks if c["id"] not in removed]
    (work / "checks.json").write_text(json.dumps(retained))


if __name__ == "__main__":
    try:
        reconcile(Path(sys.argv[1]))
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError):
        # No API payload/name/log text is printed as a workflow command.
        print("Cannot verify retry job evidence", file=sys.stderr)
        sys.exit(1)
