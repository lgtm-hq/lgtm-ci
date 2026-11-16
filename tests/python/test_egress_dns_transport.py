# SPDX-License-Identifier: MIT
"""Tests for the pinned-address transport of the egress DNS check (#1585).

``scripts/ci/maintenance/egress_dns_transport.py``. Fully offline: the socket
and the connection class are replaced in every test.
"""

from __future__ import annotations

import http.client
import ssl
from collections.abc import Callable, Iterator
from types import ModuleType
from typing import Any

import pytest
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/maintenance/egress_dns_transport.py"
REFUSED = ConnectionRefusedError(111, "Connection refused")
OK = (200, b'{"Status":0}')


@pytest.fixture(name="transport")
def fixture_transport(
    load_script: Callable[[str], ModuleType],
    monkeypatch: pytest.MonkeyPatch,
) -> Iterator[ModuleType]:
    """Load the transport with nothing remembered and no way to the network."""
    module = load_script(SCRIPT_PATH)
    module.reset()

    def refuse(*_args: Any, **_kwargs: Any) -> None:
        raise AssertionError("a test tried to reach the network")

    monkeypatch.setattr(module.socket, "create_connection", refuse)
    yield module
    module.reset()


def _serve(
    transport: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    replies: dict[str, Any],
) -> list[tuple[str, str, float]]:
    """Answer requests per address and record ``(address, path, timeout)``."""
    calls: list[tuple[str, str, float]] = []

    def fake(address: str, path: str, timeout: float) -> tuple[int, bytes]:
        calls.append((address, path, timeout))
        reply = replies.get(address, REFUSED)
        if isinstance(reply, Exception):
            raise reply
        return reply  # type: ignore[no-any-return]

    monkeypatch.setattr(transport, "_request", fake)
    return calls


def test_moves_to_the_second_address_when_the_first_is_refused(
    transport: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Under the agent only one of 8.8.8.8 and 8.8.4.4 is open; it is found."""
    calls = _serve(transport, monkeypatch, {"8.8.4.4": OK})

    result = transport.https_get("/resolve?name=a.&type=A", 10.0)
    transport.https_get("/resolve?name=b.&type=A", 10.0)

    assert_that(result).is_equal_to(OK)
    assert_that([address for address, _, _ in calls]).is_equal_to(
        ["8.8.8.8", "8.8.4.4", "8.8.4.4"],
    )


def test_a_remembered_address_that_fails_is_forgotten(
    transport: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The working address is tried first, and dropped when it stops working."""
    replies: dict[str, Any] = {"8.8.4.4": OK}
    calls = _serve(transport, monkeypatch, replies)
    transport.https_get("/x", 10.0)
    replies.clear()
    replies["8.8.8.8"] = OK
    calls.clear()

    transport.https_get("/x", 10.0)
    transport.https_get("/x", 10.0)

    assert_that([address for address, _, _ in calls]).is_equal_to(
        ["8.8.4.4", "8.8.8.8", "8.8.8.8"],
    )


def test_every_address_refused_names_what_each_returned(
    transport: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """No open address is a transport error that shows both attempts."""
    _serve(transport, monkeypatch, {})

    with pytest.raises(OSError, match="no address of dns.google answered") as raised:
        transport.https_get("/x", 10.0)
    assert_that(str(raised.value)).contains("8.8.8.8: ", "8.8.4.4: ", "refused")


def test_a_certificate_error_moves_on_and_is_not_remembered(
    transport: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """An address that does not present Google's certificate is never used."""
    bad = ssl.SSLCertVerificationError("hostname mismatch")
    calls = _serve(transport, monkeypatch, {"8.8.8.8": bad, "8.8.4.4": OK})

    transport.https_get("/x", 10.0)
    transport.https_get("/x", 10.0)

    assert_that([address for address, _, _ in calls]).is_equal_to(
        ["8.8.8.8", "8.8.4.4", "8.8.4.4"],
    )


def test_the_timeout_is_shared_between_the_addresses(
    transport: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Both addresses together take about the caller's timeout, not twice it."""
    calls = _serve(transport, monkeypatch, {"8.8.4.4": OK})

    transport.https_get("/x", 10.0)

    first, second = (timeout for _, _, timeout in calls)
    assert_that(first).is_close_to(5.0, 0.5)
    assert_that(second).is_close_to(10.0, 0.5)
    assert_that(first + second).is_less_than_or_equal_to(15.5)


def test_a_protocol_error_is_not_retried_on_the_other_address(
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
        transport.https_get("/x", 10.0)
    assert_that(calls).is_length(1)


class _FakeResponse:  # pylint: disable=too-few-public-methods
    """A response whose body records whether it was read."""

    def __init__(self, status: int) -> None:
        self.status = status
        self.read_sizes: list[int] = []

    def read(self, size: int) -> bytes:
        """Return a short body and record the cap asked for."""
        self.read_sizes.append(size)
        return b"{}"


class _FakeConnection:
    """Stands in for the pinned connection; records what it is asked."""

    made: list[_FakeConnection] = []
    status = 200

    def __init__(self, host: str, address: str, timeout: float) -> None:
        self.target = (host, address, timeout)
        self.requests: list[tuple[str, str, dict[str, str]]] = []
        self.response = _FakeResponse(self.status)
        self.closed = False
        _FakeConnection.made.append(self)

    def request(self, method: str, path: str, headers: dict[str, str]) -> None:
        """Record the request."""
        self.requests.append((method, path, headers))

    def getresponse(self) -> _FakeResponse:
        """Return the canned response."""
        return self.response

    def close(self) -> None:
        """Record the close."""
        self.closed = True


@pytest.fixture(name="connection")
def fixture_connection(
    transport: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> type[_FakeConnection]:
    """Replace the pinned connection with the recording fake."""
    _FakeConnection.made = []
    _FakeConnection.status = 200
    monkeypatch.setattr(transport, "_PinnedConnection", _FakeConnection)
    return _FakeConnection


def test_request_sends_the_agents_headers_and_caps_the_body(
    transport: ModuleType,
    connection: type[_FakeConnection],
) -> None:
    """One GET to dns.google at the address, a capped read, then a close."""
    result = transport._request(  # pylint: disable=protected-access
        "8.8.4.4",
        "/resolve?name=a.&type=A",
        4.0,
    )

    made = connection.made[0]
    assert_that(result).is_equal_to((200, b"{}"))
    assert_that(made.target).is_equal_to(("dns.google", "8.8.4.4", 4.0))
    method, path, headers = made.requests[0]
    assert_that((method, path)).is_equal_to(("GET", "/resolve?name=a.&type=A"))
    assert_that(headers["accept"]).is_equal_to("application/dns-json")
    assert_that(made.response.read_sizes).is_equal_to([transport.MAX_BODY_BYTES])
    assert_that(made.closed).is_true()


@pytest.mark.parametrize("status", [302, 429, 503])
def test_request_does_not_read_the_body_of_another_status(
    transport: ModuleType,
    connection: type[_FakeConnection],
    status: int,
) -> None:
    """A redirect or an error is returned at once, unread and never followed."""
    connection.status = status

    result = transport._request("8.8.8.8", "/x", 4.0)  # pylint: disable=protected-access

    assert_that(result).is_equal_to((status, b""))
    assert_that(connection.made).is_length(1)
    assert_that(connection.made[0].response.read_sizes).is_empty()
    assert_that(connection.made[0].closed).is_true()


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
    pinned = transport._PinnedConnection(  # pylint: disable=protected-access
        "dns.google",
        "8.8.4.4",
        7.0,
    )

    pinned.connect()

    assert_that(seen).is_equal_to(
        {"target": ("8.8.4.4", 443), "timeout": 7.0, "server_hostname": "dns.google"},
    )


def test_the_tls_context_verifies_certificates_and_host_names(
    transport: ModuleType,
) -> None:
    """Pinning an address must not weaken certificate checks."""
    context = transport._CONTEXT  # pylint: disable=protected-access

    assert_that(context.check_hostname).is_true()
    assert_that(context.verify_mode).is_equal_to(ssl.CERT_REQUIRED)


def test_only_googles_two_service_addresses_are_ever_tried(
    transport: ModuleType,
) -> None:
    """No learned or configurable address: the list is fixed."""
    assert_that(transport.GOOGLE_HOST).is_equal_to("dns.google")
    assert_that(transport.GOOGLE_ADDRESSES).is_equal_to(("8.8.8.8", "8.8.4.4"))
