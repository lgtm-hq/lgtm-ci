#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Retain raw evidence for the never-merging invalid-preset PR experiment."""

import json
import os
import re
from pathlib import Path
from typing import Any


def errors_for(needs: object, metadata: dict[str, str]) -> list[str]:
    """Require caller failure, without inferring why it failed or inventing outputs."""
    errors = []
    expected = {
        "event": "pull_request",
        "repository": "lgtm-hq/lgtm-ci",
        "head_repository": "lgtm-hq/lgtm-ci",
        "head_ref": "proof/1297-preset",
        "draft": "false",
        "case": "invalid-egress-preset",
    }
    if any(metadata.get(key) != value for key, value in expected.items()) or not (
        re.fullmatch(r"refs/pull/[1-9][0-9]*/merge", metadata.get("ref", ""))
    ):
        errors.append("Expected the exact owned ready pull_request preset case")
    if not isinstance(needs, dict) or not isinstance(needs.get("probe"), dict):
        return errors + ["Expected a probe needs object"]
    probe = needs["probe"]
    outputs = probe.get("outputs", {})
    if not isinstance(outputs, dict) or any(
        not isinstance(value, str) for value in outputs.values()
    ):
        return errors + ["Delivered outputs must be strings"]
    if probe.get("result") != "failure" or outputs.get("passed") == "true":
        errors.append("Expected actual caller failure and passed != 'true'")
    return errors


def main() -> int:
    """Retain the supplied observation before checking its verdict."""
    metadata = {
        key: os.environ.get(f"PROOF_{key.upper()}", "")
        for key in (
            "event",
            "repository",
            "head_repository",
            "head_ref",
            "head",
            "sha",
            "ref",
            "run_id",
            "attempt",
            "draft",
            "case",
        )
    }
    raw = os.environ["PROOF_NEEDS"]
    record: dict[str, Any] = {"metadata": metadata, "raw_needs": raw}
    destination = Path("python-skip-preset-observation.json")
    destination.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    try:
        needs = json.loads(raw)
    except json.JSONDecodeError as error:
        errors = [f"Malformed needs JSON: {error}"]
    else:
        record["needs"] = needs
        errors = errors_for(needs, metadata)
    record["errors"] = errors
    destination.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(destination.read_text(encoding="utf-8"), end="")
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
