# SPDX-License-Identifier: MIT
"""Tests for the pinned-address transport of the egress DNS check (#1585).

``scripts/ci/maintenance/egress_dns_transport.py``. Fully offline: the one
function that opens a socket is replaced in every test.
"""

from __future__ import annotations

import http.client
import json
from collections.abc import Callable, Iterator
from types import ModuleType
from typing import Any

import pytest
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/maintenance/egress_dns_transport.py"
REFUSED = ConnectionRefusedError(111, "Connection refused")
Call = tuple[str, str, str]


@pytest.fixture(name="transport")
def fixture_transport(
    load_script: Callable[[str], ModuleType],
) -> Iterator[ModuleType]:
    """Load the transport with nothing remembered."""
    module = load_script(SCRIPT_PATH)
    module.reset()
    yield module
    module.reset()


def _serve(
    transport: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    replies: dict[str, Any],
) -> list[Call]:
    """Answer requests per address and record ``(host, address, path)``."""
    calls: list[Call] = []

    def fake(host: str, address: str, path: str, _timeout: float) -> tuple[int, bytes]:
        calls.append((host, address, path))
        reply = replies.get(address, REFUSED)
        if isinstance(reply, Exception):
            raise reply
        return 200, json.dumps(reply).encode("utf-8")

    monkeypatch.setattr(transport, "_request", fake)
    return calls


def test_google_moves_to_the_second_address_when_the_first_is_refused(
    transport: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Under the agent only one of 8.8.8.8 and 8.8.4.4 is open; it is found."""
    calls = _serve(transport, monkeypatch, {"8.8.4.4": {"Status": 0}})

    status, body = transport.https_get("dns.google", "/resolve?name=a.&type=A", 5.0)
    transport.https_get("dns.google", "/resolve?name=b.&type=A", 5.0)

    assert_that(status).is_equal_to(200)
    assert_that(json.loads(body)).is_equal_to({"Status": 0})
    assert_that([address for _, address, _ in calls]).is_equal_to(
        ["8.8.8.8", "8.8.4.4", "8.8.4.4"],
    )


def test_a_remembered_address_that_fails_is_forgotten(
    transport: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The working address is tried first, and dropped when it stops working."""
    replies: dict[str, Any] = {"8.8.4.4": {"Status": 0}}
    calls = _serve(transport, monkeypatch, replies)
    transport.https_get("dns.google", "/x", 5.0)
    replies.clear()
    replies["8.8.8.8"] = {"Status": 0}
    calls.clear()

    transport.https_get("dns.google", "/x", 5.0)
    transport.https_get("dns.google", "/x", 5.0)

    assert_that([address for _, address, _ in calls]).is_equal_to(
        ["8.8.4.4", "8.8.8.8", "8.8.8.8"],
    )


def test_every_address_refused_raises_the_last_error(
    transport: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """No open address is a transport error for the caller to retry."""
    _serve(transport, monkeypatch, {})

    with pytest.raises(ConnectionRefusedError):
        transport.https_get("dns.google", "/x", 5.0)


def test_cloudflare_tries_the_addresses_google_reports_first(
    transport: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The agent allows an A record of cloudflare-dns.com, never 1.1.1.1."""
    answer = {
        "Status": 0,
        "Answer": [
            {"type": 5, "data": "alias.example."},
            {"type": 1, "data": "104.16.249.249"},
            {"type": 1, "data": "104.16.248.249"},
            {"type": 1, "data": "not-an-address"},
        ],
    }
    calls = _serve(
        transport,
        monkeypatch,
        {"8.8.8.8": answer, "104.16.248.249": {"Status": 3}},
    )

    _, body = transport.https_get("cloudflare-dns.com", "/dns-query?name=a.", 5.0)

    assert_that(json.loads(body)).is_equal_to({"Status": 3})
    assert_that(calls).is_equal_to(
        [
            ("dns.google", "8.8.8.8", "/resolve?name=cloudflare-dns.com.&type=A"),
            ("cloudflare-dns.com", "104.16.249.249", "/dns-query?name=a."),
            ("cloudflare-dns.com", "104.16.248.249", "/dns-query?name=a."),
        ],
    )


def test_cloudflare_falls_back_to_its_service_addresses(
    transport: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """When Google cannot be asked, the published addresses are tried."""
    calls = _serve(transport, monkeypatch, {"1.0.0.1": {"Status": 0}})

    transport.https_get("cloudflare-dns.com", "/dns-query?name=a.", 5.0)
    transport.https_get("cloudflare-dns.com", "/dns-query?name=b.", 5.0)

    cloudflare = [address for host, address, _ in calls if host != "dns.google"]
    assert_that(cloudflare).is_equal_to(["1.1.1.1", "1.0.0.1", "1.0.0.1"])
    google = [address for host, address, _ in calls if host == "dns.google"]
    assert_that(google).is_equal_to(["8.8.8.8", "8.8.4.4"])


def test_a_protocol_error_is_not_retried_on_another_address(
    transport: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The address connected; the caller decides whether to ask again."""
    calls = _serve(
        transport,
        monkeypatch,
        {"8.8.8.8": http.client.IncompleteRead(b"{")},
    )

    with pytest.raises(http.client.IncompleteRead):
        transport.https_get("dns.google", "/x", 5.0)
    assert_that(calls).is_length(1)


@pytest.mark.parametrize("host", ["attacker.example.org", "8.8.8.8", "", "DNS.GOOGLE"])
def test_only_the_two_resolver_hosts_are_ever_contacted(
    transport: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    host: str,
) -> None:
    """Any other host is refused before a request is made."""
    calls = _serve(transport, monkeypatch, {})

    with pytest.raises(ValueError, match="not a resolver host"):
        transport.https_get(host, "/x", 5.0)
    assert_that(calls).is_empty()


def test_the_connection_pins_the_address_and_verifies_the_host_name(
    transport: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The socket goes to the address; TLS checks the resolver's name."""
    seen: dict[str, Any] = {}

    class FakeContext:  # pylint: disable=too-few-public-methods
        """Records the server name TLS is asked to verify."""

        def wrap_socket(self, sock: Any, server_hostname: str) -> Any:
            """Return the socket unchanged."""
            seen["server_hostname"] = server_hostname
            return sock

    def connect(target: tuple[str, int], timeout: float) -> Any:
        seen["target"] = target
        seen["timeout"] = timeout
        return object()

    monkeypatch.setattr(transport.socket, "create_connection", connect)
    monkeypatch.setattr(transport, "_CONTEXT", FakeContext())
    connection = transport._PinnedConnection(  # pylint: disable=protected-access
        "dns.google",
        "8.8.4.4",
        7.0,
    )

    connection.connect()

    assert_that(seen).is_equal_to(
        {"target": ("8.8.4.4", 443), "timeout": 7.0, "server_hostname": "dns.google"},
    )


def test_the_tls_context_verifies_certificates_and_host_names(
    transport: ModuleType,
) -> None:
    """Pinning an address must not weaken certificate checks."""
    context = transport._CONTEXT  # pylint: disable=protected-access

    assert_that(context.check_hostname).is_true()
    assert_that(context.verify_mode).is_equal_to(transport.ssl.CERT_REQUIRED)
