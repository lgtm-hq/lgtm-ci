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


def _check_definition(
    report: Report, definition: Any, where: str, kind: str, keywords: set[str]
) -> bool:
    """Check a definition's supported keywords, type and constraint values.

    Args:
        report: Findings sink.
        definition: Parsed schema definition.
        where: Location for diagnostics.
        kind: Expected JSON Schema type.
        keywords: Required constraint keywords supported at this location.

    Returns:
        Whether the definition can safely be consumed.
    """
    before = len(report.errors)
    if not isinstance(definition, dict):
        report.error(where, "schema definition must be a mapping")
        return False
    supported = keywords | ANNOTATIONS | {"type"}
    for keyword in sorted(set(definition) - supported, key=str):
        report.error(where, f"unsupported schema keyword `{keyword}`")
    for keyword in sorted((keywords | {"type"}) - set(definition)):
        report.error(where, f"missing schema keyword `{keyword}`")
    if definition.get("type") != kind:
        report.error(where, f"schema type must be `{kind}`")
    if kind == "object" and definition.get("additionalProperties") is not False:
        report.error(where, "schema `additionalProperties` must be false")
    if kind == "integer":
        values = definition.get("enum")
        if (
            not isinstance(values, list)
            or not values
            or not all(isinstance(v, int) and not isinstance(v, bool) for v in values)
            or len(set(values)) != len(values)
        ):
            message = "schema `enum` must be a non-empty list of unique integers"
            report.error(where, message)
    if kind == "string":
        pattern = definition.get("pattern")
        if not isinstance(pattern, str):
            report.error(where, "schema `pattern` must be a string")
        else:
            try:
                re.compile(pattern)
            except (re.error, ValueError, OverflowError, RecursionError) as exc:
                report.error(where, f"invalid schema `pattern` ({exc})")
    return len(report.errors) == before


def _check_object_definition(
    report: Report,
    definition: Any,
    where: str,
    fields: set[str],
    required: set[str],
) -> bool:
    """Validate an object's properties and mandatory/optional field contract.

    Args:
        report: Findings sink.
        definition: Parsed object definition.
        where: Location for diagnostics.
        fields: Exact supported property names.
        required: Exact mandatory property names; remaining fields stay optional.

    Returns:
        Whether the object definition preserves the allowlist contract.
    """
    before = len(report.errors)
    if not _check_definition(report, definition, where, "object", OBJECT_KEYWORDS):
        return False
    properties = definition["properties"]
    if not isinstance(properties, dict) or set(properties) != fields:
        report.error(where, f"schema `properties` must define exactly {sorted(fields)}")
    keys = definition["required"]
    if (
        not isinstance(keys, list)
        or not all(isinstance(key, str) for key in keys)
        or len(set(keys)) != len(keys)
        or set(keys) != required
    ):
        report.error(where, f"schema `required` must list exactly {sorted(required)}")
    return len(report.errors) == before


def check_schema(report: Report, schema: Any) -> bool:
    """Reject schemas whose structure or constraint values cannot be enforced.

    Args:
        report: Findings sink.
        schema: Parsed allowlist schema.

    Returns:
        Whether all schema definitions preserve the supported allowlist contract.
    """
    before = len(report.errors)
    where = str(SCHEMA)
    fields = {"schema-version", "exceptions"}
    if not _check_object_definition(report, schema, where, fields, fields):
        return False
    properties = schema["properties"]
    _check_definition(
        report,
        properties["schema-version"],
        f"{where}.schema-version",
        "integer",
        {"enum"},
    )
    exceptions = properties["exceptions"]
    where = f"{where}.exceptions"
    if not _check_definition(report, exceptions, where, "array", {"items"}):
        return False
    row = exceptions["items"]
    where = f"{where}.items"
    required = {"repo", "path", "reason", "link"}
    if not _check_object_definition(report, row, where, required | {"job"}, required):
        return False
    for key, definition in row["properties"].items():
        _check_definition(report, definition, f"{where}.{key}", "string", {"pattern"})
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
        pattern = definition["pattern"]
        if not isinstance(value, str) or re.search(pattern, value) is None:
            description = definition.get("description", "invalid field")
            report.error(where, f"`{key}`: {description} (got {value!r})")
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
    except (OSError, ValueError, RecursionError, catalog_lib.yaml.YAMLError) as exc:
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
        choices = " or ".join(map(str, allowed))
        report.error(where, f"`schema-version` must be {choices}")
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
