#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Retain delivered workflow outputs; never infer missing cancellation outputs."""

# pylint: disable=invalid-name  # Hyphenated standalone CLI contract.

import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

COUNTS = {"single": 1, "matrix": 2, "empty": 1, "commas": 1}
FIELDS = ("tests-passed", "tests-failed", "tests-total", "coverage-percent", "passed")


def errors_for(needs: dict[str, Any], metadata: dict[str, str]) -> list[str]:
    """Assert results without coercing outputs or synthesizing absent keys."""
    errors = []
    case = metadata["case"]
    callers = COUNTS if case == "positive" else {"probe": 1}
    for caller, count in callers.items():
        observation = needs.get(caller, {})
        result = observation.get("result")
        outputs = observation.get("outputs", {})
        if not isinstance(outputs, dict) or any(
            not isinstance(value, str) for value in outputs.values()
        ):
            errors.append(f"{caller}: outputs must be strings")
            continue
        passed = outputs.get("passed")
        if case != "positive":
            expected = "failure" if case == "pytest-failure" else "cancelled"
            if result != expected or passed == "true":
                errors.append(f"{caller}: expected {expected} and passed != 'true'")
            if case == "pytest-failure" and any(
                outputs.get(field) != value
                for field, value in {
                    "tests-passed": "0",
                    "tests-failed": "1",
                    "tests-total": "1",
                    "passed": "false",
                }.items()
            ):
                errors.append(f"{caller}: expected the single executed failing control")
            continue
        draft = metadata["event"] == "pull_request" and metadata["draft"] == "true"
        if draft:
            if result != "skipped" or passed == "true":
                errors.append(f"{caller}: expected preserved draft skip")
            continue
        if result != "success" or passed != "true":
            errors.append(f"{caller}: expected real success and passed='true'")
        if any(field not in outputs for field in FIELDS):
            errors.append(f"{caller}: missing success outputs")
        # PRs support both the false-input baseline and true-input skip, with
        # identical IDs/names/versions. Hosted step logs must establish the route.
        totals = {str(count)}
        if metadata["event"] == "pull_request":
            totals.add("0")
        if (
            outputs.get("tests-total") not in totals
            or outputs.get("tests-passed") != outputs.get("tests-total")
            or outputs.get("tests-failed") != "0"
        ):
            errors.append(f"{caller}: unexpected sentinel counts")
        if outputs.get("tests-total") == "0" and outputs.get("coverage-percent") != "0":
            errors.append(f"{caller}: lightweight coverage must be '0'")
    return errors


def guard() -> None:
    """Fail closed outside owned dispatch refs or when a proof PR is open."""
    case = os.environ["PROOF_CASE"]
    branch = {"pytest-failure": "proof/1297-negative", "cancel": "proof/1297-cancel"}
    repository = os.environ["PROOF_REPOSITORY"]
    if (
        os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
        or repository != "lgtm-hq/lgtm-ci"
        or case not in branch
        or os.environ["PROOF_REF"] != f"refs/heads/{branch[case]}"
    ):
        raise ValueError("Dispatch requires the exact owned case/ref/repository")
    query = urllib.parse.urlencode({"state": "open", "head": f"lgtm-hq:{branch[case]}"})
    request = urllib.request.Request(
        f"https://api.github.com/repos/lgtm-hq/lgtm-ci/pulls?{query}",
        headers={
            "Authorization": f"Bearer {os.environ['PROOF_TOKEN']}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    # An HTTPS-only opener excludes file handlers and credential-bearing redirects.
    opener = urllib.request.OpenerDirector()
    opener.add_handler(urllib.request.HTTPSHandler())
    with opener.open(request, timeout=30) as response:
        if response.status != 200:
            raise ValueError(f"Proof PR lookup failed: HTTP {response.status}")
        pulls = json.load(response)
    if not isinstance(pulls, list) or pulls:
        raise ValueError("Negative dispatch requires an owned ref with no open PR")


def main() -> int:
    """Write raw evidence before validating so failed assertions remain reviewable."""
    if sys.argv[1:] == ["--guard"]:
        guard()
        return 0
    metadata = {
        key: os.environ.get(f"PROOF_{key.upper()}", "")
        for key in ("event", "head", "sha", "ref", "run_id", "attempt", "draft", "case")
    }
    raw = os.environ["PROOF_NEEDS"]
    record: dict[str, Any] = {"metadata": metadata, "raw_needs": raw}
    destination = Path("python-skip-proof-observation.json")
    destination.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    needs = json.loads(raw)
    if not isinstance(needs, dict) or metadata["case"] not in (
        "positive",
        "pytest-failure",
        "cancel",
    ):
        raise ValueError("Expected needs object and supported proof case")
    errors = errors_for(needs, metadata)
    record.update(needs=needs, errors=errors)
    rendered = json.dumps(record, indent=2) + "\n"
    destination.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
