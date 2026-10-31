#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Fail-closed runner selection, collection and value-only publication (#1232)."""

from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any

ORG = "lgtm-hq"
VARIABLE = f"orgs/{ORG}/actions/variables/LGTM_CI_RUNNER"
GITHUB_RUNNER = "ubuntu-26.04"
MARKER = "<!-- lgtm-ci:runner-governor -->"
CONTRACT = Path(__file__).with_name("usage-contract.json")


class GovernorError(Exception):
    """An unavailable or untrusted input; never substitute zero usage."""


def number(value: Any, name: str, *, positive: bool = False) -> Decimal:
    """Reject booleans, missing values, negative and non-finite numbers."""
    if isinstance(value, bool) or not isinstance(value, (int, float, str, Decimal)):
        raise GovernorError(f"Invalid {name}")
    try:
        result = Decimal(str(value))
    except InvalidOperation as exc:
        raise GovernorError(f"Invalid {name}") from exc
    if not result.is_finite() or result < 0 or (positive and result == 0):
        raise GovernorError(f"Invalid {name}")
    return result


def read_json(path: Path) -> Any:
    """Read an input without exposing its contents on failure."""
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise GovernorError("Unreadable JSON input") from exc


@dataclass(frozen=True)
class Knobs:
    """Validated org variables, with the issue's defaults."""

    mode: str = "auto"
    label: str = "blacksmith-2vcpu-ubuntu-2604"
    budget: Decimal = Decimal(2700)
    included: Decimal = Decimal(3000)
    overage: str = "github"
    cycle_day: int = 1

    @classmethod
    def from_env(cls, env: Any) -> Knobs:
        """Treat absent/empty Actions variables as defaults."""
        prefix = "LGTM_CI_RUNNER_"
        label = env.get(prefix + "BLACKSMITH_LABEL") or cls.label
        result = cls(
            mode=env.get(prefix + "MODE") or "auto",
            label=label,
            budget=number(env.get(prefix + "BUDGET_MINUTES") or 2700, "budget"),
            included=number(
                env.get(prefix + "GITHUB_INCLUDED_MINUTES") or 3000,
                "included minutes",
            ),
            overage=env.get(prefix + "OVERAGE") or "github",
            cycle_day=int(env.get(prefix + "CYCLE_DAY") or 1),
        )
        result.validate()
        return result

    def validate(self) -> None:
        """Bound the cycle day so it exists in every calendar month."""
        if self.mode not in {"auto", "blacksmith", "github"}:
            raise GovernorError("Invalid mode")
        if self.overage not in {"blacksmith", "github"}:
            raise GovernorError("Invalid overage choice")
        if not re.fullmatch(r"blacksmith-[a-zA-Z0-9_.-]+", self.label):
            raise GovernorError("Invalid Blacksmith runner label")
        if not 1 <= self.cycle_day <= 28:
            raise GovernorError("Cycle day must be between 1 and 28")
        number(self.budget, "budget")
        number(self.included, "included minutes")


def cycle_start(now: datetime, day: int) -> datetime:
    """Calendar cycle in UTC, including year rollover (owner confirmed day 1)."""
    if not 1 <= day <= 28 or now.utcoffset() is None:
        raise GovernorError("Invalid calendar cycle")
    now = now.astimezone(timezone.utc)
    start = now.replace(day=day, hour=0, minute=0, second=0, microsecond=0)
    if now < start:
        previous = now.replace(day=1)
        year, month = (previous.year, previous.month - 1)
        if month == 0:
            year, month = year - 1, 12
        start = start.replace(year=year, month=month)
    return start


def validate_contract(contract: Any) -> None:
    """Require reviewed evidence instead of guessing the free-tier field."""
    if not isinstance(contract, dict) or contract.get("verified") is not True:
        raise GovernorError("Usage contract unverified; see docs/runner-governor.md")
    evidence = contract.get("evidence")
    if not isinstance(evidence, str) or not evidence.strip():
        raise GovernorError("Usage contract needs nonzero dashboard evidence")
    path = contract.get("blacksmith_total_path")
    if (
        not isinstance(path, list)
        or not path
        or any(not isinstance(part, str) or not part for part in path)
    ):
        raise GovernorError("Missing verified Blacksmith total path")
    scale = contract.get("blacksmith_minutes_per_unit")
    number(scale, "Blacksmith scale", positive=True)
    multipliers = contract.get("github_sku_multipliers")
    if not isinstance(multipliers, dict) or not multipliers:
        raise GovernorError("Missing verified GitHub SKU multipliers")
    for sku, multiplier in multipliers.items():
        if not isinstance(sku, str) or not sku or sku != sku.casefold():
            raise GovernorError("Invalid GitHub SKU mapping")
        number(multiplier, "SKU multiplier", positive=True)


def blacksmith_minutes(usage: Any, contract: dict[str, Any]) -> Decimal:
    """Read only the verified aggregate, never sum truncated breakdown rows."""
    total = usage
    for part in contract["blacksmith_total_path"]:
        if not isinstance(total, dict) or part not in total:
            raise GovernorError("Missing Blacksmith aggregate")
        total = total[part]
    return number(total, "Blacksmith usage") * number(
        contract["blacksmith_minutes_per_unit"],
        "Blacksmith scale",
        positive=True,
    )


def repository_name(value: Any) -> str:
    """Accept the API's full repository name and older bare names."""
    if not isinstance(value, str):
        raise GovernorError("Missing billing repository attribution")
    full = value if "/" in value else f"{ORG}/{value}"
    if not re.fullmatch(r"lgtm-hq/[A-Za-z0-9_.-]+", full):
        raise GovernorError("Invalid billing repository attribution")
    return full


def github_minutes(
    usage: Any,
    repositories: Any,
    contract: dict[str, Any],
    *,
    month: str,
) -> Decimal:
    """Count private Actions minute quantities using reviewed SKU multipliers."""
    if not isinstance(usage, dict) or not isinstance(usage.get("usageItems"), list):
        raise GovernorError("Missing GitHub usageItems")
    if not isinstance(repositories, dict):
        raise GovernorError("Missing repository visibility")
    total = Decimal(0)
    for row in usage["usageItems"]:
        if not isinstance(row, dict) or not all(
            isinstance(row.get(key), str) for key in ("product", "unitType")
        ):
            raise GovernorError("Malformed GitHub usage row")
        if row["product"].casefold() != "actions":
            continue
        if row["unitType"].casefold() != "minutes":
            # Storage/other units never consume the included minute pool.
            continue
        try:
            date = datetime.strptime(row["date"], "%Y-%m-%d")
        except (KeyError, TypeError, ValueError) as exc:
            raise GovernorError("Invalid GitHub usage date") from exc
        if date.strftime("%Y-%m") != month:
            raise GovernorError("GitHub usage outside requested billing month")
        if str(row.get("organizationName", "")).casefold() != ORG:
            raise GovernorError("Unexpected billing organization")
        repo = repository_name(row.get("repositoryName"))
        metadata = repositories.get(repo)
        if (
            not isinstance(metadata, dict)
            or metadata.get("full_name") != repo
            or not isinstance(metadata.get("private"), bool)
            or metadata.get("visibility") not in {"private", "public"}
            or metadata["private"] != (metadata["visibility"] == "private")
        ):
            raise GovernorError("Unknown or inconsistent repository visibility")
        quantity = number(row.get("quantity"), "GitHub quantity")
        if not metadata["private"]:
            continue
        sku = row.get("sku")
        multipliers = contract["github_sku_multipliers"]
        if not isinstance(sku, str) or sku.casefold() not in multipliers:
            raise GovernorError("Unverified private Actions minute SKU")
        total += quantity * number(
            contract["github_sku_multipliers"][sku.casefold()],
            "SKU multiplier",
            positive=True,
        )
    return total


@dataclass(frozen=True)
class Usage:
    """Both provider inputs, metadata and the requested billing month."""

    blacksmith: Any
    github: Any
    repositories: Any
    month: str


def decide(usage: Usage, knobs: Knobs, contract: dict[str, Any]) -> dict[str, str]:
    """Pure decision; both sources are required even in forced modes."""
    knobs.validate()
    validate_contract(contract)
    bs_used = blacksmith_minutes(usage.blacksmith, contract)
    gh_used = github_minutes(
        usage.github,
        usage.repositories,
        contract,
        month=usage.month,
    )
    threshold = knobs.included * Decimal("0.95")
    choice = knobs.mode
    reason = f"forced {choice}"
    if choice == "auto":
        if bs_used < knobs.budget:
            choice, reason = "blacksmith", "Blacksmith usage below budget"
        elif gh_used < threshold:
            choice, reason = "github", "GitHub private minutes below 95% threshold"
        else:
            choice, reason = knobs.overage, "Both free pools exhausted; overage choice"
    return {
        "mode": knobs.mode,
        "desired": knobs.label if choice == "blacksmith" else GITHUB_RUNNER,
        "reason": reason,
        "blacksmith_minutes": str(bs_used),
        "github_minutes": str(gh_used),
        "blacksmith_budget": str(knobs.budget),
        "github_threshold": str(threshold),
    }


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never forward a credential to a redirect target."""

    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        """Refuse every redirect, regardless of the original request method."""
        return None


class GitHub:
    """Small bounded REST client; tokens stay in headers, errors omit bodies."""

    def __init__(self, token: str):
        if not token:
            raise GovernorError("Missing GitHub credential")
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect())

    def request(self, path: str, method: str = "GET", body: Any = None) -> Any:
        """Do not retry writes whose outcome may be ambiguous."""
        request = urllib.request.Request(
            "https://api.github.com/" + path,
            data=json.dumps(body).encode() if body is not None else None,
            method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "Content-Type": "application/json",
            },
        )
        try:
            with self.opener.open(request, timeout=60) as response:
                payload = response.read()
                return json.loads(payload) if payload else None
        except (
            OSError,
            ValueError,
            urllib.error.URLError,
            http.client.HTTPException,
        ) as exc:
            error = "GitHub API request failed; value may need inspection"
            raise GovernorError(error) from exc

    def runner_variable(self) -> dict[str, Any]:
        """Read the switch without permitting visibility or selection changes."""
        current = self.request(VARIABLE)
        if (
            not isinstance(current, dict)
            or not isinstance(current.get("value"), str)
            or current.get("visibility") != "selected"
        ):
            raise GovernorError("Runner variable must exist with selected visibility")
        return current


def collect_blacksmith(start: datetime, end: datetime) -> Any:
    """Use stdin auth and an isolated, deleted HOME; suppress all CLI diagnostics."""
    token = os.environ.get("BLACKSMITH_ORG_TOKEN")
    if not token or os.environ.get("BLACKSMITH_ORG") != ORG:
        raise GovernorError("Missing Blacksmith org credential/configuration")
    with tempfile.TemporaryDirectory(prefix="runner-governor-") as directory:
        env = {
            key: os.environ[key]
            for key in ("PATH", "TMPDIR", "LANG", "SSL_CERT_FILE", "SSL_CERT_DIR")
            if key in os.environ
        }
        env["HOME"] = directory
        env["BLACKSMITH_ORG"] = ORG
        env["BLACKSMITH_DISABLE_AUTO_UPDATE"] = "1"
        commands = [
            [
                "blacksmith",
                "auth",
                "login",
                "--api-token",
                "-",
                "--non-interactive",
                "--organization",
                ORG,
            ],
            [
                "blacksmith",
                "usage",
                "--start-time",
                start.isoformat(),
                "--end-time",
                end.isoformat(),
                "--format",
                "json",
            ],
        ]
        try:
            subprocess.run(
                commands[0],
                input=token,
                text=True,
                env=env,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=60,
            )
            result = subprocess.run(
                commands[1],
                text=True,
                env=env,
                check=True,
                capture_output=True,
                timeout=120,
            )
            return json.loads(result.stdout)
        except (OSError, subprocess.SubprocessError, ValueError) as exc:
            raise GovernorError("Blacksmith usage unavailable") from exc


def collect_github(api: GitHub, now: datetime) -> tuple[Any, dict[str, Any]]:
    """Read the complete monthly report, resolving each metered repo via the API."""
    usage = api.request(
        f"organizations/{ORG}/settings/billing/usage?year={now.year}&month={now.month}",
    )
    if not isinstance(usage, dict) or not isinstance(usage.get("usageItems"), list):
        raise GovernorError("Missing GitHub usageItems")
    repositories = {}
    for row in usage["usageItems"]:
        if not isinstance(row, dict):
            raise GovernorError("Malformed billing row")
        if (
            str(row.get("product", "")).casefold() == "actions"
            and str(row.get("unitType", "")).casefold() == "minutes"
        ):
            repo = repository_name(row.get("repositoryName"))
            if repo not in repositories:
                repositories[repo] = api.request(f"repos/{repo}")
    return usage, repositories


def is_status_issue(issue: Any) -> bool:
    """Accept only an open, labeled status issue with a leading marker line."""
    if not isinstance(issue, dict) or not isinstance(issue.get("body") or "", str):
        raise GovernorError("Malformed status issue response")
    body = (issue.get("body") or "").lstrip()
    labels = issue.get("labels") or []
    return (
        "pull_request" not in issue
        and issue.get("state") == "open"
        and issue.get("title") == "Runner governor status"
        and body.splitlines()[:1] == [MARKER]
        and isinstance(labels, list)
        and any(
            isinstance(label, dict) and label.get("name") == "infrastructure"
            # API labels include extra fields; compare only the label name.
            for label in labels
        )
    )


def status_issue(api: GitHub, report: str) -> None:
    """Publish a known change to an open status issue; never reuse a closed one.

    The live caller is blocked until durable reporting is implemented. This
    helper alone cannot reconcile ambiguous POST outcomes; see the runbook.
    """
    repo = "repos/lgtm-hq/lgtm-ci"
    for page in range(1, 101):
        issues = api.request(f"{repo}/issues?state=open&per_page=100&page={page}")
        if not isinstance(issues, list):
            raise GovernorError("Unable to locate governor status issue")
        for issue in issues:
            if is_status_issue(issue):
                number_value = issue.get("number")
                if (
                    not isinstance(number_value, int)
                    or isinstance(number_value, bool)
                    or number_value <= 0
                ):
                    raise GovernorError("Invalid status issue number")
                comments = f"{repo}/issues/{number_value}/comments"
                api.request(comments, "POST", {"body": report})
                return
        if len(issues) < 100:
            api.request(
                f"{repo}/issues",
                "POST",
                {
                    "title": "Runner governor status",
                    "body": MARKER + "\n\n" + report,
                    "labels": ["infrastructure"],
                },
            )
            return
    raise GovernorError("Status issue lookup exceeded page limit")


def apply(
    api: GitHub,
    reporter: GitHub | None,
    decision: dict[str, str],
    *,
    dry_run: bool,
) -> str:
    """Preview safely; block live changes until durable reporting is available."""
    current = GitHub.runner_variable(api)
    decision["current"] = current["value"]
    decision["value_changed"] = "false"
    decision["report_completed"] = "false"
    if current["value"] == decision["desired"]:
        return "unchanged"
    if dry_run:
        return "dry-run; no writes"
    if reporter is None:
        raise GovernorError("Missing status issue credential")
    # Re-read to detect a concurrent human override, including while blocked.
    if GitHub.runner_variable(api) != current:
        raise GovernorError("Runner variable changed concurrently; retry next run")
    # Neither a runner-local file nor the current value proves that a previous
    # PATCH completed. Do not enable the old PATCH-then-POST loss window.
    raise GovernorError(
        "Live changes blocked: durable report reconciliation is unavailable; "
        "see docs/runner-governor.md",
    )


def summary(values: dict[str, str]) -> str:
    """Only emit validated decisions or fixed errors, never source JSON/tokens."""
    lines = ["### Runner governor", ""]
    lines.extend(f"- {key.replace('_', ' ')}: {value}" for key, value in values.items())
    return "\n".join(lines) + "\n"


def validate_setup(fixture: bool) -> None:
    """Require workflow setup explicitly; standalone fixtures need no setup."""
    if not fixture and os.environ.get("SETUP_READY") != "true":
        raise GovernorError("Governor setup failed or run cancelled; no writes")
    if not fixture and os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise GovernorError("Governor credentials require refs/heads/main; no writes")


def fixture_decision(
    arguments: argparse.Namespace,
    knobs: Knobs,
    now: datetime,
) -> dict[str, str]:
    """Load synthetic inputs without allowing them to authorize publication."""
    if arguments.live:
        raise GovernorError("Fixture inputs cannot authorize live writes")
    directory = arguments.fixture_dir
    usage = Usage(
        read_json(directory / "blacksmith.json"),
        read_json(directory / "github.json"),
        read_json(directory / "repositories.json"),
        arguments.fixture_month or now.strftime("%Y-%m"),
    )
    return decide(usage, knobs, read_json(directory / "contract.json"))


def network_decision(knobs: Knobs, now: datetime, live: bool) -> dict[str, str]:
    """Validate the contract and activation gate before any provider request."""
    contract = read_json(CONTRACT)
    validate_contract(contract)
    if live and os.environ.get("LGTM_CI_RUNNER_GOVERNOR_ENABLED") != "true":
        raise GovernorError("Live governor is disabled")
    api = GitHub(os.environ.get("GH_TOKEN", ""))
    blacksmith = collect_blacksmith(cycle_start(now, knobs.cycle_day), now)
    github, repositories = collect_github(api, now)
    usage = Usage(blacksmith, github, repositories, now.strftime("%Y-%m"))
    report = decide(usage, knobs, contract)
    reporter = GitHub(os.environ.get("STATUS_TOKEN", "")) if live else None
    try:
        report["result"] = apply(api, reporter, report, dry_run=not live)
    except GovernorError as exc:
        # Keep known mutation/report state in the caller's step summary.
        report["result"] = "failed; no further writes"
        report["error"] = str(exc)
    return report


def main(argv: list[str] | None = None) -> int:
    """Default to dry-run. Fixture inputs can never select the live write path."""
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--live", action="store_true")
    mode.add_argument("--dry-run", choices=("true", "false"), default="true")
    parser.add_argument("--fixture-dir", type=Path)
    parser.add_argument("--fixture-month")
    args = parser.parse_args(argv)
    args.live = args.live or args.dry_run == "false"
    report = {
        "mode": "unvalidated",
        "dry_run": str(not args.live).lower(),
        "blacksmith_minutes": "unavailable",
        "github_minutes": "unavailable",
        "blacksmith_budget": "unavailable",
        "github_threshold": "unavailable",
        "current": "unavailable",
        "desired": "unavailable",
    }
    try:
        validate_setup(bool(args.fixture_dir))
        knobs = Knobs.from_env(os.environ)
        now = datetime.now(timezone.utc)
        report.update(
            mode=knobs.mode,
            blacksmith_budget=str(knobs.budget),
            github_threshold=str(knobs.included * Decimal("0.95")),
        )
        if args.fixture_dir:
            report.update(fixture_decision(args, knobs, now))
            report["result"] = "fixture dry-run; no network or writes"
        else:
            if args.fixture_month:
                raise GovernorError("Fixture month requires fixture inputs")
            report.update(network_decision(knobs, now, args.live))
        return_code = int("error" in report)
    except (GovernorError, ValueError, ArithmeticError) as exc:
        report["result"] = "failed; no further writes"
        if isinstance(exc, GovernorError):
            report["error"] = str(exc)
        else:
            report["error"] = "Invalid numeric input or knob"
        return_code = 1
    rendered = summary(report)
    print(rendered, end="")
    if path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(path).open("a", encoding="utf-8") as handle:
            handle.write(rendered)
    return return_code


if __name__ == "__main__":
    sys.exit(main())
