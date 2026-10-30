# SPDX-License-Identifier: MIT
"""Validate the consumer CI exception allowlist (#1236).

Like the consumer registry, this uses the catalog's dependency-free shape
checks. Enforced JSON Schema keywords are ``type`` (object, array, integer and
string), ``properties``/``required``/``additionalProperties: false`` (allowed
and required keys), ``items`` (exception mappings), ``pattern`` (string fields)
and ``enum`` (schema-version only). ``$schema``, ``title`` and ``description``
are annotations; every other keyword fails validation. The remaining checks
enforce unique, nonredundant, sorted scopes. No network access is needed.
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
OBJECT_KEYWORDS = {"required", "properties", "additionalProperties"}
ANNOTATIONS = {"$schema", "title", "description"}


def check_schema(report: Report, schema: dict[str, Any]) -> bool:
    """Reject schema constraints the allowlist checker cannot enforce.

    Args:
        report: Findings sink.
        schema: Parsed allowlist schema.

    Returns:
        Whether all schema definitions use the supported subset.
    """
    before = len(report.errors)
    where = str(SCHEMA)
    try:
        properties = schema["properties"]
        exceptions = properties["exceptions"]
        row = exceptions["items"]
        definitions = [
            (schema, where, "object", OBJECT_KEYWORDS),
            (properties["schema-version"], f"{where}.schema-version", "integer", {"enum"}),
            (exceptions, f"{where}.exceptions", "array", {"items"}),
            (row, f"{where}.exceptions.items", "object", OBJECT_KEYWORDS),
        ]
        definitions.extend(
            (definition, f"{where}.exceptions.items.{key}", "string", {"pattern"})
            for key, definition in row["properties"].items()
        )
    except (KeyError, TypeError, AttributeError):
        report.error(where, "unsupported schema structure")
        return False
    if set(properties) != {"schema-version", "exceptions"}:
        report.error(where, "unsupported top-level schema properties")
    for definition, location, kind, keywords in definitions:
        if not isinstance(definition, dict):
            report.error(location, "schema definition must be a mapping")
            continue
        for keyword in sorted(set(definition) - (keywords | ANNOTATIONS | {"type"})):
            report.error(location, f"unsupported schema keyword `{keyword}`")
        for keyword in sorted((keywords | {"type"}) - set(definition)):
            report.error(location, f"missing schema keyword `{keyword}`")
        if definition.get("type") != kind:
            report.error(location, f"schema type must be `{kind}`")
        if kind == "object" and definition.get("additionalProperties") is not False:
            report.error(location, "schema `additionalProperties` must be false")
    return len(report.errors) == before


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
            report.error(
                where,
                f"`{key}`: {definition.get('description', 'invalid field')} (got {value!r})",
            )
    return len(report.errors) == before


def check_scopes(report: Report, scopes: list[tuple[str, str, str]]) -> None:
    """Reject duplicate, redundant or unsorted normalized exception scopes.

    Args:
        report: Findings sink.
        scopes: Validated repository/path/job tuples in allowlist order.
    """
    where = str(ALLOWLIST)
    seen: set[tuple[str, str, str]] = set()
    for scope in scopes:
        if scope in seen:
            report.error(where, f"duplicate repo/path/job scope ({scope!r})")
        seen.add(scope)
    for repo, path, job in scopes:
        if job and (repo, path, "") in seen:
            report.error(
                where,
                "redundant job scope: repo/path already has a whole-file entry "
                f"({repo}:{path}, job {job!r})",
            )
    if scopes != sorted(scopes):
        report.error(where, "sort by repo (case-insensitive), then path and job")


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
    if not check_schema(report=report, schema=schema):
        return
    check_keys(report=report, value=data, schema=schema, where=where)
    version = data.get("schema-version")
    if (
        not isinstance(version, int)
        or isinstance(version, bool)
        or version not in schema["properties"]["schema-version"]["enum"]
    ):
        allowed = schema["properties"]["schema-version"]["enum"]
        report.error(where, f"`schema-version` must be {' or '.join(map(str, allowed))}")
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
        scopes.append((row["repo"].lower(), row["path"], row.get("job", "")))
    check_scopes(report=report, scopes=scopes)
