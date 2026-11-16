# SPDX-License-Identifier: MIT
"""HTTPS requests to the DNS-over-HTTPS resolver, by pinned address (#1585).

Used by ``check-egress-dns.py``. The check runs under harden-runner in block
mode, where a plain request to ``dns.google`` is refused more often than not:

- The agent's DNS proxy answers every job lookup of ``dns.google`` with the
  fixed address 8.8.8.8 (``dnsproxy.go`` ``processTypeA``).
- Its firewall, however, opens to the job only the address the agent itself
  got when it resolved each allowed host at start-up: the first A record,
  which for ``dns.google`` is 8.8.8.8 or 8.8.4.4 depending on the answer's
  order. The fixed address is open to the agent's own user only
  (``firewall.go`` ``addBlockRules``); anything else is rejected.

So the name cannot be left to the system resolver. A request connects to one
of the resolver's two addresses directly and still verifies the certificate
against the resolver's host name. A refused or unreachable address moves on
to the other; the one that worked is remembered.

These two are the service's published addresses and, today, its only A
records. Should Google add another and the agent pick it at start-up, every
request is refused and the check fails closed (exit 2).

Source checked 2026-11-16, step-security/agent v0.18.0:
https://github.com/step-security/agent/blob/v0.18.0/dnsproxy.go#L267-L285
https://github.com/step-security/agent/blob/v0.18.0/firewall.go#L60-L100
"""

from __future__ import annotations

import http.client
import socket
import ssl
import threading
import time

USER_AGENT = "lgtm-ci-egress-dns-check"
MAX_BODY_BYTES = 65536
GOOGLE_HOST = "dns.google"
GOOGLE_ADDRESSES = ("8.8.8.8", "8.8.4.4")

_CONTEXT = ssl.create_default_context()
_LOCK = threading.Lock()
_WORKING: list[str] = []


def reset() -> None:
    """Forget the remembered address (tests)."""
    with _LOCK:
        _WORKING.clear()


class _PinnedConnection(http.client.HTTPSConnection):
    """An HTTPS connection to a fixed address, verified against the host name.

    Args:
        host: The resolver's host name: the TLS server name and Host header.
        address: The IPv4 address to connect to.
        timeout: Seconds per socket operation.
    """

    def __init__(self, host: str, address: str, timeout: float) -> None:
        super().__init__(host, 443, timeout=timeout, context=_CONTEXT)
        self._address = address

    def connect(self) -> None:
        """Connect to the pinned address and verify the host's certificate."""
        sock = socket.create_connection((self._address, 443), self.timeout)
        try:
            self.sock = _CONTEXT.wrap_socket(sock, server_hostname=self.host)
        except BaseException:
            sock.close()
            raise


class BodyTooLarge(http.client.HTTPException):
    """Raised when an answer's body is longer than :data:`MAX_BODY_BYTES`.

    A protocol error, not an address problem: :func:`https_get` lets it
    through without trying the other address, and the caller treats it as a
    resolver error. A truncated prefix is never judged as an answer.
    """


def _request(address: str, path: str, timeout: float) -> tuple[int, bytes]:
    """Send one GET to the resolver at one address.

    Args:
        address: The address to connect to.
        path: The request path with its query string.
        timeout: Seconds per socket operation.

    Returns:
        The HTTP status and, for a 200 answer, the body. Any other status (a
        redirect included, which is never followed) comes back with an empty
        body, unread.

    Raises:
        BodyTooLarge: When a 200 answer's body exceeds :data:`MAX_BODY_BYTES`.
    """
    connection = _PinnedConnection(GOOGLE_HOST, address, timeout)
    try:
        headers = {"accept": "application/dns-json", "user-agent": USER_AGENT}
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        if response.status != 200:
            return response.status, b""
        body = response.read(MAX_BODY_BYTES + 1)
        if len(body) > MAX_BODY_BYTES:
            raise BodyTooLarge(
                f"answer body longer than {MAX_BODY_BYTES} bytes from {address}",
            )
        # read(n) returns what arrived before an early end of the stream
        # without raising; ``length`` then still counts the missing bytes. A
        # cut-off body can be a complete JSON prefix, so it is never judged.
        missing = getattr(response, "length", None)
        if missing:
            raise http.client.IncompleteRead(body, missing)
        return response.status, body
    finally:
        connection.close()


def _candidates() -> list[str]:
    """Return the addresses to try, the one that last worked first."""
    with _LOCK:
        working = list(_WORKING)
    return list(dict.fromkeys(working + list(GOOGLE_ADDRESSES)))


def https_get(path: str, timeout: float) -> tuple[int, bytes]:
    """Send one GET to ``dns.google``, trying its addresses until one connects.

    The whole call takes about ``timeout`` at most: the time left is shared
    between the addresses still to try, so an address that drops packets
    without refusing cannot use up the other's time.

    Args:
        path: The request path with its query string.
        timeout: Seconds for the whole call.

    Returns:
        The HTTP status and the body.

    Raises:
        OSError: When no address could be connected to (refused, timed out,
            certificate not valid for the host). The message lists what each
            address returned.
        http.client.HTTPException: On a protocol error after connecting, an
            oversized body (:class:`BodyTooLarge`) included; the other
            address is not tried.
    """
    end = time.monotonic() + timeout
    candidates = _candidates()
    failures: list[str] = []
    for index, address in enumerate(candidates):
        share = (end - time.monotonic()) / (len(candidates) - index)
        try:
            result = _request(address, path, max(share, 0.5))
        except OSError as error:
            failures.append(f"{address}: {error!r}")
            with _LOCK:
                if address in _WORKING:
                    _WORKING.remove(address)
            continue
        with _LOCK:
            _WORKING[:] = [address]
        return result
    raise OSError(f"no address of {GOOGLE_HOST} answered ({'; '.join(failures)})")
