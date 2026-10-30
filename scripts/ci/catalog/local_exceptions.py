# SPDX-License-Identifier: MIT
"""Validate the consumer CI exception allowlist (#1236).

Like the consumer registry, this uses the catalog's dependency-free shape
checks. The JSON schema supplies the required/allowed keys and string patterns;
the remaining checks enforce the version, list shape and unique sorted scopes.
No network access is needed to validate a catalog checkout.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

import catalog_lib
from catalog_lib import Report

ALLOWLIST = Path("catalog/local-exceptions.yml")
SCHEMA = Path("schemas/local-exceptions.schema.json")


def check_keys(
    report: Report,
    value: dict[str, Any],
    schema: dict[str, Any],
    where: str,
) -> None:
    """Check required and allowed keys from a schema object definition.

    Args:
        report: Findings sink.
        value: Parsed mapping.
        schema: Object definition from the allowlist schema.
        where: Location for diagnostics.
    """
    for key in sorted(set(schema["required"]) - set(value)):
        report.error(where, f"missing required key `{key}`")
    for key in sorted(set(value) - set(schema["properties"]), key=str):
        report.error(where, f"unknown key `{key}`")


def check_row(
    report: Report,
    row: dict[str, Any],
    schema: dict[str, Any],
    where: str,
) -> bool:
    """Validate one exception's required fields and optional job scope.

    Args:
        report: Findings sink.
        row: Parsed exception.
        schema: Exception definition from the allowlist schema.
        where: Location for diagnostics.

    Returns:
        Whether the row can be used for scope checks.
    """
    before = len(report.errors)
    check_keys(report=report, value=row, schema=schema, where=where)
    for key, definition in schema["properties"].items():
        if key not in row:
            continue
        value = row[key]
        if not isinstance(value, str) or not re.fullmatch(definition["pattern"], value):
            report.error(where, f"`{key}`: {definition['description']}")
    return len(report.errors) == before


def check_local_exceptions(
    report: Report,
    repo_root: Path,
) -> None:
    """Validate the allowlist as part of the CI Support Catalog job.

    Args:
        report: Findings sink.
        repo_root: Checkout containing the allowlist and its schema.
    """
    where = str(ALLOWLIST)
    try:
        schema = json.loads((repo_root / SCHEMA).read_text(encoding="utf-8"))
        data = catalog_lib.load_catalog(path=repo_root / ALLOWLIST)
    except (OSError, ValueError, catalog_lib.yaml.YAMLError) as exc:
        report.error(where, f"unreadable allowlist or schema ({exc})")
        return
    check_keys(report=report, value=data, schema=schema, where=where)
    version = data.get("schema-version")
    if (
        not isinstance(version, int)
        or isinstance(version, bool)
        or version not in schema["properties"]["schema-version"]["enum"]
    ):
        report.error(where, "`schema-version` must be 1")
    rows = data.get("exceptions")
    if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
        report.error(where, "`exceptions` must be a list of mappings")
        return
    scopes: list[tuple[str, str, str]] = []
    definition = schema["properties"]["exceptions"]["items"]
    for index, row in enumerate(rows):
        location = f"{where}.exceptions[{index}]"
        if not check_row(report=report, row=row, schema=definition, where=location):
            continue
        scope = (row["repo"].lower(), row["path"], row.get("job", ""))
        if scope in scopes:
            report.error(location, "duplicate repo/path/job scope")
        scopes.append(scope)
    if scopes != sorted(scopes):
        report.error(where, "sort by repo (case-insensitive), then path and job")
