# SPDX-License-Identifier: MIT
"""Tests for decoding resolver answers as the agent's Go decoder does (#1582).

``scripts/ci/maintenance/egress_dns_answer.py``, reached through
``check-egress-dns.py``'s ``classify``. Fully offline.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from types import ModuleType

import pytest
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/maintenance/check-egress-dns.py"
A_RECORD = '{"name": "h.", "type": 1, "TTL": 60, "data": "192.0.2.1"}'
RECORD_IN_OTHER_CASES = '{"NAME": "h.", "Type": 1, "ttl": 60, "Data": "192.0.2.1"}'
RESOLVES = ("resolves", "A 192.0.2.1")
MALFORMED = ("error", "answer with a malformed Answer list")
ENVELOPE = ("error", "answer with malformed flags or Question")
NO_STATUS = ("error", "answer without a DNS Status")
DUPLICATE = ("error", "answer with a key given twice (letter case aside)")
NON_ASCII = ("error", "answer with a non-ASCII object key")
TOO_DEEP = ("error", "answer nested too deeply")
LONG_INTEGER = ("error", "answer with an integer too long to read")
UNDECODABLE = ("error", "undecodable answer")
INT64_MAX = 2**63 - 1
INT64_MIN = -(2**63)

# A canonical dns.google answer, as it arrives (with keys the agent ignores).
CANONICAL = (
    '{"Status":0,"TC":false,"RD":true,"RA":true,"AD":false,"CD":false,'
    '"Question":[{"name":"github.com.","type":1}],'
    '"Answer":[{"name":"github.com.","type":1,"TTL":60,"data":"192.0.2.1"}],'
    '"Comment":"Response from 192.0.2.53."}'
)


@pytest.fixture(name="dns")
def fixture_dns(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the DNS check without running it."""
    return load_script(SCRIPT_PATH)


def _classify(dns: ModuleType, body: str | bytes) -> tuple[str, str]:
    """Classify a raw body and return its outcome and detail."""
    raw = body.encode("utf-8") if isinstance(body, str) else body
    attempt = dns.classify(raw)
    return str(attempt.outcome), attempt.detail


@pytest.mark.parametrize(
    ("body", "expected"),
    [
        pytest.param(CANONICAL, RESOLVES, id="canonical"),
        pytest.param(f'{{"Status":0,"answer":[{A_RECORD}]}}', RESOLVES, id="answer"),
        pytest.param(f'{{"status":0,"ANSWER":[{A_RECORD}]}}', RESOLVES, id="status"),
        pytest.param(
            f'{{"Status":0,"Answer":[{RECORD_IN_OTHER_CASES}]}}',
            RESOLVES,
            id="record-fields",
        ),
        pytest.param('{"STATUS":3}', ("negative", "NXDOMAIN"), id="nxdomain"),
        pytest.param(
            f'{{"Status":0,"Answer":[{A_RECORD}],"question":false}}',
            ENVELOPE,
            id="question-false",
        ),
        pytest.param(
            f'{{"Status":0,"Answer":[{A_RECORD}],"tc":"no"}}',
            ENVELOPE,
            id="flag-string",
        ),
        pytest.param(
            f'{{"Status":0,"Answer":[{A_RECORD}],"answer":[{A_RECORD}]}}',
            DUPLICATE,
            id="answer-twice-by-case",
        ),
        pytest.param(
            f'{{"Status":0,"Answer":[{A_RECORD}],"Question":[],"question":[]}}',
            DUPLICATE,
            id="question-twice-by-case",
        ),
        pytest.param(
            f'{{"Status":0,"status":3,"Answer":[{A_RECORD}]}}',
            DUPLICATE,
            id="status-twice-by-case",
        ),
        pytest.param(
            f'{{"Status":0,"Status":0,"Answer":[{A_RECORD}]}}',
            DUPLICATE,
            id="status-twice-exactly",
        ),
        pytest.param(
            '{"Status":0,"Answer":[{"type":1,"Type":1,"data":"192.0.2.1"}]}',
            DUPLICATE,
            id="record-type-twice",
        ),
        pytest.param(
            f'{{"Status":0,"Answer":[{A_RECORD}],"edns_client_subnet":"x"}}',
            RESOLVES,
            id="unknown-key-ignored",
        ),
        pytest.param(
            f'{{"Status":0,"Answer":[{A_RECORD},null]}}',
            MALFORMED,
            id="null-record",
        ),
        pytest.param('{"Status":null,"Answer":[]}', NO_STATUS, id="null-status"),
        pytest.param("null", NO_STATUS, id="top-level-null"),
        pytest.param('{"Status":0,"Answer":[]} {}', UNDECODABLE, id="trailing-data"),
        pytest.param('{"Status":0,"TTL":NaN}', UNDECODABLE, id="nan"),
        pytest.param('{"Status":0,"x":-Infinity}', UNDECODABLE, id="infinity"),
        pytest.param(
            '{"Status":0,"Answer":[{"type":1.0,"data":"192.0.2.1"}]}',
            MALFORMED,
            id="fraction",
        ),
        pytest.param(
            '{"Status":0,"Answer":[{"type":1e0,"data":"192.0.2.1"}]}',
            MALFORMED,
            id="exponent",
        ),
    ],
)
def test_classify_decodes_keys_and_values_as_go_does(
    dns: ModuleType,
    body: str,
    expected: tuple[str, str],
) -> None:
    """Keys match case-insensitively; duplicates and non-JSON fail closed."""
    assert_that(_classify(dns, body)).is_equal_to(expected)


def _with_ttl(ttl: int) -> str:
    """Return an answer whose A record has the given TTL."""
    return f'{{"Status":0,"Answer":[{{"type":1,"TTL":{ttl},"data":"192.0.2.1"}}]}}'


@pytest.mark.parametrize(
    ("body", "expected"),
    [
        pytest.param(_with_ttl(INT64_MAX), RESOLVES, id="ttl-max"),
        pytest.param(_with_ttl(INT64_MAX + 1), MALFORMED, id="ttl-max-plus-1"),
        pytest.param(_with_ttl(INT64_MIN), RESOLVES, id="ttl-min"),
        pytest.param(_with_ttl(INT64_MIN - 1), MALFORMED, id="ttl-min-minus-1"),
        pytest.param(
            f'{{"Status":{INT64_MAX},"Answer":[{A_RECORD}]}}',
            RESOLVES,
            id="status-max",
        ),
        pytest.param(f'{{"Status":{INT64_MAX + 1}}}', NO_STATUS, id="status-over"),
        pytest.param(f'{{"Status":{INT64_MIN - 1}}}', NO_STATUS, id="status-under"),
        pytest.param(
            f'{{"Status":0,"Question":[{{"type":{INT64_MAX + 1}}}]}}',
            ENVELOPE,
            id="question-type-over",
        ),
        pytest.param(
            f'{{"Status":0,"Answer":[{{"type":{2**64 + 1},"data":"x"}},{A_RECORD}]}}',
            MALFORMED,
            id="record-type-wraps-to-1",
        ),
    ],
)
def test_classify_bounds_integers_to_64_bits(
    dns: ModuleType,
    body: str,
    expected: tuple[str, str],
) -> None:
    """An integer outside int64 is rejected, as Go's ``int`` on the runners."""
    assert_that(_classify(dns, body)).is_equal_to(expected)


@pytest.mark.parametrize(
    ("body", "expected"),
    [
        pytest.param(
            b'{"Status":0,"Comment":"\xff","Answer":[' + A_RECORD.encode() + b"]}",
            RESOLVES,
            id="invalid-utf8-in-a-string",
        ),
        pytest.param(
            json.dumps({"Status": 0}).encode("utf-16"),
            UNDECODABLE,
            id="utf16",
        ),
        pytest.param(b"\xef\xbb\xbf" + CANONICAL.encode(), UNDECODABLE, id="bom"),
    ],
)
def test_classify_reads_the_body_as_utf8(
    dns: ModuleType,
    body: bytes,
    expected: tuple[str, str],
) -> None:
    """Invalid UTF-8 in a string is replaced; another encoding is not JSON."""
    assert_that(_classify(dns, body)).is_equal_to(expected)


@pytest.mark.parametrize(
    "key",
    [
        pytest.param("\u017ftatus", id="long-s-Go-would-match-Status"),
        pytest.param("\u212aey", id="kelvin-sign"),
        pytest.param("Comment\u00e9", id="unknown-key-Go-would-ignore"),
        pytest.param("\u0130", id="dotted-capital-i"),
    ],
)
def test_classify_rejects_a_non_ascii_key(dns: ModuleType, key: str) -> None:
    """Only ASCII letters fold; any non-ASCII object key fails closed."""
    body = json.dumps({"Status": 0, "Answer": [json.loads(A_RECORD)], key: 1})
    nested = f'{{"Status":0,"Answer":[{{"type":1,"data":"x",{json.dumps(key)}:1}}]}}'

    assert_that(_classify(dns, body)).is_equal_to(NON_ASCII)
    assert_that(_classify(dns, nested)).is_equal_to(NON_ASCII)


@pytest.mark.parametrize(
    ("body", "expected"),
    [
        pytest.param(
            f'{{"Status":0,"Answer":[{A_RECORD}],"x":' + "[" * 63 + "]" * 63 + "}",
            RESOLVES,
            id="64-deep",
        ),
        pytest.param(
            f'{{"Status":0,"Answer":[{A_RECORD}],"x":' + "[" * 64 + "]" * 64 + "}",
            TOO_DEEP,
            id="65-deep-in-an-unknown-field",
        ),
        pytest.param("[" * 100_000, TOO_DEEP, id="hostile-nesting"),
        pytest.param(
            f'{{"Status":0,"Answer":[{A_RECORD}],"x":"' + "[" * 100 + '"}',
            RESOLVES,
            id="brackets-in-a-string",
        ),
        pytest.param(
            f'{{"Status":0,"Answer":[{A_RECORD}],"x":{"9" * 4301}}}',
            LONG_INTEGER,
            id="integer-over-4300-digits",
        ),
        pytest.param(
            f'{{"Status":0,"Answer":[{A_RECORD}],"x":-{"9" * 4300}}}',
            RESOLVES,
            id="integer-of-4300-digits-in-an-unknown-field",
        ),
    ],
)
def test_classify_bounds_nesting_and_integer_length(
    dns: ModuleType,
    body: str,
    expected: tuple[str, str],
) -> None:
    """Hostile input is a malformed answer, never a crash."""
    assert_that(_classify(dns, body)).is_equal_to(expected)
