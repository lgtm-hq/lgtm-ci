# SPDX-License-Identifier: MIT
"""A small JSON Schema (2020-12) checker for the repository's own schemas (#1678).

The test environment has no JSON Schema library, and adding one only to check
``schemas/comment.v1.json`` is not worth a new dependency. This checker
covers the keywords that schema uses and nothing more; ``unsupported``
lists any other keyword, so a schema that grows past it fails its test
instead of being checked partly.
"""

from __future__ import annotations

import re
from typing import Any

#: Keywords this checker understands; annotations are accepted and ignored.
KEYWORDS = frozenset(
    {
        "$schema",
        "$id",
        "$defs",
        "$ref",
        "title",
        "description",
        "type",
        "const",
        "enum",
        "properties",
        "required",
        "additionalProperties",
        "items",
        "minItems",
        "maxItems",
        "minLength",
        "maxLength",
        "pattern",
        "minimum",
        "maximum",
        "minProperties",
        "oneOf",
        "anyOf",
        "not",
    },
)
_TYPES: dict[str, type | tuple[type, ...]] = {
    "object": dict,
    "array": list,
    "string": str,
    "boolean": bool,
    "number": (int, float),
}


def unsupported(schema: Any) -> set[str]:
    """Return every keyword in ``schema`` this checker does not understand."""
    found: set[str] = set()
    if isinstance(schema, dict):
        for key, value in schema.items():
            if key not in KEYWORDS:
                found.add(key)
            if key in {"properties", "$defs"}:
                for sub in value.values():
                    found |= unsupported(sub)
            elif key in {"items", "not", "additionalProperties"}:
                found |= unsupported(value)
            elif key in {"oneOf", "anyOf"}:
                for sub in value:
                    found |= unsupported(sub)
    return found


def _type_ok(value: Any, name: str) -> bool:
    """Tell whether ``value`` has JSON type ``name``."""
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name in {"number", "string", "array", "object"} and isinstance(value, bool):
        return False
    return isinstance(value, _TYPES[name])


def errors(
    value: Any,
    schema: dict[str, Any],
    root: dict[str, Any],
    path: str = "$",
) -> list[str]:
    """Return every way ``value`` breaks ``schema`` (``root`` resolves ``$ref``)."""
    if "$ref" in schema:
        name = schema["$ref"].removeprefix("#/$defs/")
        return errors(value, root["$defs"][name], root, path)
    if "type" in schema and not _type_ok(value, schema["type"]):
        return [f"{path}: not of type {schema['type']}"]
    found: list[str] = []
    if "const" in schema and value != schema["const"]:
        found.append(f"{path}: not {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        found.append(f"{path}: not one of {schema['enum']}")
    found += _scalar_errors(value, schema, path)
    if isinstance(value, list):
        most = schema.get("maxItems", len(value))
        if not schema.get("minItems", 0) <= len(value) <= most:
            found.append(f"{path}: wrong number of items")
        for index, item in enumerate(value):
            found += errors(item, schema.get("items", {}), root, f"{path}[{index}]")
    if isinstance(value, dict):
        found += _object_errors(value, schema, root, path)
    return found + _combinator_errors(value, schema, root, path)


def _scalar_errors(value: Any, schema: dict[str, Any], path: str) -> list[str]:
    """Return the string and number keywords' errors for ``value``."""
    found: list[str] = []
    if isinstance(value, str):
        if len(value) > schema.get("maxLength", len(value)):
            found.append(f"{path}: longer than {schema['maxLength']}")
        if len(value) < schema.get("minLength", 0):
            found.append(f"{path}: shorter than {schema['minLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            found.append(f"{path}: does not match {schema['pattern']}")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        low, high = schema.get("minimum"), schema.get("maximum")
        if (low is not None and value < low) or (high is not None and value > high):
            found.append(f"{path}: out of range")
    return found


def _combinator_errors(
    value: Any,
    schema: dict[str, Any],
    root: dict[str, Any],
    path: str,
) -> list[str]:
    """Return the ``oneOf``, ``anyOf`` and ``not`` errors for ``value``."""
    found: list[str] = []
    for key in ("oneOf", "anyOf"):
        if key in schema:
            passing = sum(not errors(value, sub, root, path) for sub in schema[key])
            wrong = passing != 1 if key == "oneOf" else passing == 0
            if wrong:
                found.append(f"{path}: {key} matched {passing} alternatives")
    if "not" in schema and not errors(value, schema["not"], root, path):
        found.append(f"{path}: matches a schema it must not")
    return found


def _object_errors(
    value: dict[str, Any], schema: dict[str, Any], root: dict[str, Any], path: str
) -> list[str]:
    """Return the object keywords' errors for ``value``."""
    required = schema.get("required", [])
    found = [f"{path}: missing {key}" for key in required if key not in value]
    if len(value) < schema.get("minProperties", 0):
        found.append(f"{path}: too few properties")
    properties = schema.get("properties", {})
    for key, item in value.items():
        if key in properties:
            found += errors(item, properties[key], root, f"{path}.{key}")
        elif schema.get("additionalProperties") is False:
            found.append(f"{path}: unexpected property {key}")
    return found
