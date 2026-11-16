# SPDX-License-Identifier: MIT
"""HTTPS requests to the DNS-over-HTTPS resolvers, by pinned address (#1585).

Used by ``check-egress-dns.py``. The check runs under harden-runner in block
mode, where a plain request to ``dns.google`` is refused more often than not:

- The agent's DNS proxy answers every lookup of ``dns.google`` with the fixed
  address 8.8.8.8, and of ``cloudflare-dns.com`` with 1.1.1.1
  (``dnsproxy.go`` ``processTypeA``).
- Its firewall, however, allows the job only the address the agent itself got
  when it resolved each allowed host at start-up: the first A record, which
  for ``dns.google`` is 8.8.8.8 or 8.8.4.4 depending on the answer's order,
  and for ``cloudflare-dns.com`` is never 1.1.1.1. The fixed addresses are
  open to the agent's own user only (``firewall.go`` ``addBlockRules``).

So the name cannot be left to the system resolver. Each resolver has a list
of candidate addresses; a request connects to one of them directly and still
verifies the certificate against the resolver's host name. A refused or
unreachable address moves on to the next; the one that worked is remembered.

Source checked 2026-11-16, step-security/agent v0.18.0:
https://github.com/step-security/agent/blob/v0.18.0/dnsproxy.go#L267-L285
https://github.com/step-security/agent/blob/v0.18.0/firewall.go#L60-L100
"""

from __future__ import annotations

import http.client
import ipaddress
import json
import socket
import ssl
import threading

USER_AGENT = "lgtm-ci-egress-dns-check"
MAX_BODY_BYTES = 65536
GOOGLE_HOST = "dns.google"
CLOUDFLARE_HOST = "cloudflare-dns.com"

# The resolvers' published service addresses. For dns.google these are also
# its only A records, so one of them is the address the agent allowed.
ADDRESSES: dict[str, tuple[str, ...]] = {
    GOOGLE_HOST: ("8.8.8.8", "8.8.4.4"),
    CLOUDFLARE_HOST: ("1.1.1.1", "1.0.0.1"),
}

_CONTEXT = ssl.create_default_context()
_LOCK = threading.Lock()
_WORKING: dict[str, str] = {}
_LEARNED: dict[str, tuple[str, ...]] = {}


def reset() -> None:
    """Forget every remembered and learned address (tests)."""
    with _LOCK:
        _WORKING.clear()
        _LEARNED.clear()


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


def _request(host: str, address: str, path: str, timeout: float) -> tuple[int, bytes]:
    """Send one GET to a resolver at one address.

    Args:
        host: The resolver's host name.
        address: The address to connect to.
        path: The request path with its query string.
        timeout: Seconds per socket operation.

    Returns:
        The HTTP status and at most :data:`MAX_BODY_BYTES` of the body. A
        redirect is returned as its 3xx status, never followed.
    """
    connection = _PinnedConnection(host, address, timeout)
    try:
        headers = {"accept": "application/dns-json", "user-agent": USER_AGENT}
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        return response.status, response.read(MAX_BODY_BYTES)
    finally:
        connection.close()


def _learn_cloudflare(timeout: float) -> tuple[str, ...]:
    """Ask Google for the A records of ``cloudflare-dns.com``.

    The agent allows the job the first A record it got for that host, which
    is one of these and not a published service address.

    Args:
        timeout: Seconds per socket operation.

    Returns:
        The IPv4 addresses, or an empty tuple when they could not be read.
    """
    try:
        path = f"/resolve?name={CLOUDFLARE_HOST}.&type=A"
        status, body = https_get(GOOGLE_HOST, path, timeout)
        answers = json.loads(body).get("Answer") or [] if status == 200 else []
    except (OSError, http.client.HTTPException, ValueError, AttributeError):
        return ()
    found: list[str] = []
    for answer in answers if isinstance(answers, list) else []:
        if not isinstance(answer, dict) or answer.get("type") != 1:
            continue
        try:
            found.append(str(ipaddress.IPv4Address(answer.get("data"))))
        except ValueError:
            continue
    return tuple(dict.fromkeys(found))


def _candidates(host: str, timeout: float) -> list[str]:
    """Return the addresses to try for a resolver, the working one first."""
    with _LOCK:
        learned = _LEARNED.get(host)
    if learned is None:
        learned = _learn_cloudflare(timeout) if host == CLOUDFLARE_HOST else ()
        with _LOCK:
            _LEARNED[host] = learned
    with _LOCK:
        working = _WORKING.get(host)
    ordered = ([working] if working else []) + list(learned) + list(ADDRESSES[host])
    return list(dict.fromkeys(ordered))


def https_get(host: str, path: str, timeout: float) -> tuple[int, bytes]:
    """Send one GET to a resolver, trying its addresses until one connects.

    Args:
        host: ``dns.google`` or ``cloudflare-dns.com``; nothing else.
        path: The request path with its query string.
        timeout: Seconds per socket operation.

    Returns:
        The HTTP status and the body.

    Raises:
        ValueError: For any other host.
        OSError: When no address could be connected to (refused, timed out,
            certificate not valid for the host).
        http.client.HTTPException: On a protocol error after connecting.
    """
    if host not in ADDRESSES:
        raise ValueError(f"not a resolver host: {host!r}")
    failure: OSError = OSError(f"no address for {host}")
    for address in _candidates(host, timeout):
        try:
            result = _request(host, address, path, timeout)
        except OSError as error:
            failure = error
            with _LOCK:
                if _WORKING.get(host) == address:
                    del _WORKING[host]
            continue
        with _LOCK:
            _WORKING[host] = address
        return result
    raise failure
