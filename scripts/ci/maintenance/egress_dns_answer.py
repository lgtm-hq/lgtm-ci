# SPDX-License-Identifier: MIT
"""Decode a DNS-over-HTTPS JSON answer as the harden-runner agent does (#1582).

Used by ``check-egress-dns.py``. The agent (step-security/agent v0.18.0,
built with Go 1.27.3) reads the whole body and calls ``json.Unmarshal`` into::

    type DNSResponse struct {
        Status   int        `json:"Status"`
        Tc, Rd, Ra, Ad, Cd bool  // `json:"TC"`, "RD", "RA", "AD", "CD"
        Question []Question `json:"Question"`
        Answer   []Answer   `json:"Answer"`
    }
    type Question struct { Name string `json:"name"`; Type int `json:"type"` }
    type Answer struct {
        Name string `json:"name"`; Type int `json:"type"`
        TTL  int    `json:"TTL"`;  Data string `json:"data"`
    }

https://github.com/step-security/agent/blob/v0.18.0/dnsproxy.go#L31-L50

Where this decoder follows ``encoding/json`` (https://pkg.go.dev/encoding/json,
``Unmarshal``):

- Keys match fields case-insensitively: "Unmarshal matches incoming object
  keys to the keys used by Marshal (either the struct field name or its tag),
  preferring an exact match but also accepting a case-insensitive match."
  For ASCII keys that means ASCII letters compare without regard to case.
- Keys that are no field are ignored; ``null`` leaves a field unset.
- Each value must have its field's type, or the whole answer is rejected;
  ``int`` is 64 bits on the agent's runners (linux/amd64, linux/arm64), so an
  integer outside int64, or one written with a fraction or exponent, is
  rejected.
- The body is UTF-8 (invalid bytes become U+FFFD), a single JSON value with
  nothing after it; ``NaN`` and ``Infinity`` are not JSON.

Deliberate differences from Go, each in the fail-closed direction (the answer
becomes a resolver error, retried and at worst an exit 2, never a host that
wrongly resolves or fails):

- Only ASCII letters fold. An object key with any non-ASCII character makes
  the answer malformed. Go folds a non-ASCII rune to the smallest rune of its
  ``unicode.SimpleFold`` orbit (``foldRune`` in ``src/encoding/json/fold.go``),
  so it would ignore most such keys but match the long s (U+017F) to ``s``
  and the Kelvin sign (U+212A) to ``k``. dns.google sends ASCII keys only.
- Two keys of one object that match the same field, exactly or only in
  case, make the answer malformed. Go's package documentation does not say
  what happens then, and its result depends on the order and the type: a
  later ``null`` leaves an earlier scalar as it was but resets a slice. So
  the answer is not guessed at.
- Arrays and objects nested more than ``MAX_DEPTH`` deep, anywhere in the
  body (unknown fields included), make the answer malformed; Go's limit is
  10,000, and a real answer nests 3 deep.
- An integer with more than ``MAX_INT_DIGITS`` digits, anywhere in the body,
  makes the answer malformed (Python's default conversion limit); Go skips
  the value of an unknown field without converting it.
- A missing or ``null`` ``Status``, a ``null`` element of ``Question`` or
  ``Answer``, and an A record without data are rejected; Go would read zero
  values. dns.google always sends ``Status`` and the data of an A record.
- A top-level ``null`` is rejected; Go would read an empty answer.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

A_RECORD = 1
INT64_MIN = -(2**63)
INT64_MAX = 2**63 - 1
MAX_DEPTH = 64
MAX_INT_DIGITS = 4300
NO_STATUS = "answer without a DNS Status"
BAD_ENVELOPE = "answer with malformed flags or Question"
BAD_ANSWER = "answer with a malformed Answer list"
DUPLICATE_KEYS = "answer with a key given twice (letter case aside)"
NON_ASCII_KEY = "answer with a non-ASCII object key"
TOO_DEEP = "answer nested too deeply"
LONG_INTEGER = "answer with an integer too long to read"

FLAG_FIELDS = tuple((name, bool) for name in ("TC", "RD", "RA", "AD", "CD"))
QUESTION_FIELDS: tuple[tuple[str, type], ...] = (("name", str), ("type", int))
ANSWER_FIELDS: tuple[tuple[str, type], ...] = (
    ("name", str),
    ("data", str),
    ("type", int),
    ("TTL", int),
)


class MalformedAnswer(Exception):
    """Raised when the agent would reject an answer, or its reading is unsure."""


class JsonObject(tuple[tuple[str, Any], ...]):
    """A decoded JSON object: its ``(key, value)`` pairs in order, duplicates kept."""

    __slots__ = ()


@dataclass(frozen=True)
class DnsAnswer:
    """The fields of a decoded answer the verdict needs.

    Attributes:
        status: The DNS response code.
        records: ``(type, data)`` of every Answer record, in order.
    """

    status: int
    records: tuple[tuple[int | None, str | None], ...]


def field(record: JsonObject, name: str) -> Any:
    """Return the value of a struct field in a JSON object, as Go matches it.

    Args:
        record: The decoded object; its keys are ASCII (see :func:`_object`).
        name: The field's JSON name, such as ``Status``.

    Returns:
        The value, or None when no key matches.

    Raises:
        MalformedAnswer: When two keys match the field.
    """
    target = name.upper()
    matches = [value for key, value in record if key.upper() == target]
    if len(matches) > 1:
        raise MalformedAnswer(DUPLICATE_KEYS)
    return matches[0] if matches else None


def _fits(value: Any, kind: type) -> bool:
    """Tell whether a present JSON value decodes into a Go field of ``kind``."""
    if kind is int:
        return (
            isinstance(value, int)
            and not isinstance(value, bool)
            and INT64_MIN <= value <= INT64_MAX
        )
    return isinstance(value, kind)


def _typed(record: Any, fields: tuple[tuple[str, type], ...]) -> bool:
    """Tell whether a JSON object's fields, where set, have their Go types."""
    if not isinstance(record, JsonObject):
        return False
    for name, kind in fields:
        value = field(record, name)
        if value is not None and not _fits(value, kind):
            return False
    return True


def _typed_list(records: Any, fields: tuple[tuple[str, type], ...]) -> bool:
    """Tell whether a JSON value is absent or a list of typed objects."""
    if records is None:
        return True
    return isinstance(records, list) and all(_typed(r, fields) for r in records)


def _reject_constant(name: str) -> Any:
    """Refuse ``NaN`` and ``Infinity``, which Go's decoder does not accept."""
    raise ValueError(f"not JSON: {name}")


def _object(pairs: list[tuple[str, Any]]) -> JsonObject:
    """Build a decoded object, refusing a key that is not ASCII."""
    if not all(key.isascii() for key, _ in pairs):
        raise MalformedAnswer(NON_ASCII_KEY)
    return JsonObject(pairs)


def _integer(digits: str) -> int:
    """Convert a JSON integer, refusing one too long to convert safely."""
    if len(digits.lstrip("-")) > MAX_INT_DIGITS:
        raise MalformedAnswer(LONG_INTEGER)
    return int(digits)


def _nesting(text: str) -> int:
    """Return how deep arrays and objects nest in a JSON text.

    Brackets inside strings are not counted. The text need not be valid:
    this only bounds the decoder's recursion before it runs.
    """
    depth = deepest = 0
    in_string = escaped = False
    for char in text:
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char in "[{":
            depth += 1
            deepest = max(deepest, depth)
        elif char in "]}":
            depth -= 1
    return deepest


def decode(body: bytes) -> Any:
    """Decode a body as JSON, keeping every object key.

    Args:
        body: The response body.

    Returns:
        The value, with objects as :class:`JsonObject`.

    Raises:
        ValueError: When the body is not one JSON value.
        MalformedAnswer: When it nests too deep, holds an integer too long
            to read, or an object key that is not ASCII.
    """
    text = body.decode("utf-8", errors="replace")
    if _nesting(text) > MAX_DEPTH:
        raise MalformedAnswer(TOO_DEEP)
    return json.loads(
        text,
        object_pairs_hook=_object,
        parse_int=_integer,
        parse_constant=_reject_constant,
    )


def parse_answer(body: bytes) -> DnsAnswer:
    """Decode an answer and check it as the agent's decoder does.

    Args:
        body: The response body.

    Returns:
        The DNS status and the Answer records.

    Raises:
        MalformedAnswer: When the agent would reject the answer, or the
            checker cannot be sure it would accept it.
    """
    try:
        payload = decode(body)
    except ValueError as error:
        raise MalformedAnswer("undecodable answer") from error
    if not isinstance(payload, JsonObject):
        raise MalformedAnswer(NO_STATUS)
    status = field(payload, "Status")
    if status is None or not _fits(status, int):
        raise MalformedAnswer(NO_STATUS)
    questions = field(payload, "Question")
    if not _typed(payload, FLAG_FIELDS) or not _typed_list(questions, QUESTION_FIELDS):
        raise MalformedAnswer(BAD_ENVELOPE)
    answers = field(payload, "Answer")
    if not _typed_list(answers, ANSWER_FIELDS):
        raise MalformedAnswer(BAD_ANSWER)
    records = tuple((field(a, "type"), field(a, "data")) for a in answers or ())
    if any(kind == A_RECORD and not data for kind, data in records):
        raise MalformedAnswer(BAD_ANSWER)
    return DnsAnswer(status=status, records=records)
