# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Parse the answers of GitHub's attestations API for the bundle hosts.

Used by ``check-attestation-store-host.py`` (#1644). Every attestation must
carry either a ``bundle_url`` (an https URL on a plain DNS name, port 443) or
an inline Sigstore ``bundle``; anything else is an input the check cannot
trust. A URL is never echoed: its query string is a signed access token.
Standard library only.
"""

from __future__ import annotations

import re
from typing import Any
from urllib.parse import urlsplit

# A plain lowercase DNS name: dot-separated labels of letters, digits and
# inner hyphens, a letter-only top-level label, 253 characters at most. Every
# host from the API is checked against it before it is used or printed.
HOSTNAME = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$",
)
# The media type every Sigstore bundle carries; an inline bundle without it is
# not a bundle gh could verify.
BUNDLE_MEDIA_TYPE = "application/vnd.dev.sigstore.bundle"


class StoreCheckError(Exception):
    """Raised when an input cannot be trusted; the check fails closed."""


def is_inline_bundle(bundle: Any) -> bool:
    """Return True when ``bundle`` looks like a Sigstore bundle gh can verify.

    Args:
        bundle: The ``bundle`` field of one attestation.

    Returns:
        True for an object whose ``mediaType`` is a Sigstore bundle type.
    """
    return (
        isinstance(bundle, dict)
        and isinstance(bundle.get("mediaType"), str)
        and bundle["mediaType"].startswith(BUNDLE_MEDIA_TYPE)
    )


def url_host(url: Any) -> str:
    """Return the validated host of one bundle_url.

    Never echoes the URL: its query string is a signed access token.

    Args:
        url: The ``bundle_url`` field of one attestation (non-empty).

    Returns:
        The host, a plain DNS name.

    Raises:
        StoreCheckError: When the URL is not a string, not https, or its host
            is not a plain DNS name on port 443.
    """
    if not isinstance(url, str):
        raise StoreCheckError(f"bundle_url is not a string ({type(url).__name__})")
    try:
        parts = urlsplit(url)
        port = parts.port
    except ValueError as error:
        raise StoreCheckError("bundle_url is not a parseable URL") from error
    if parts.scheme != "https" or not parts.hostname:
        raise StoreCheckError(
            f"bundle_url is not an https URL with a host ({parts.scheme!r})",
        )
    if port not in (None, 443) or not HOSTNAME.match(parts.hostname):
        raise StoreCheckError("bundle_url host is not a plain DNS name on port 443")
    return parts.hostname


def bundle_hosts(document: Any) -> tuple[set[str], int, int]:
    """Extract the bundle_url hosts from one attestations API answer.

    Args:
        document: A parsed ``GET .../attestations/{digest}`` document.

    Returns:
        The bundle_url hosts, the number of attestations that carry only an
        inline bundle, and the number of attestations read.

    Raises:
        StoreCheckError: When the document's shape is not recognised, an
            attestation has neither a bundle_url nor an inline Sigstore
            bundle, or a bundle_url is not https on a plain DNS name.
    """
    if not isinstance(document, dict):
        raise StoreCheckError("an attestations answer is not a JSON object")
    attestations = document.get("attestations")
    if not isinstance(attestations, list):
        raise StoreCheckError("an attestations answer has no `attestations` list")
    hosts: set[str] = set()
    inline = 0
    for entry in attestations:
        if not isinstance(entry, dict):
            raise StoreCheckError(
                f"an attestation is not an object ({type(entry).__name__})",
            )
        url = entry.get("bundle_url")
        if url not in (None, ""):
            hosts.add(url_host(url))
        elif is_inline_bundle(entry.get("bundle")):
            inline += 1
        else:
            # gh fails the same way: "attestation has no bundle or bundle URL".
            raise StoreCheckError("an attestation has neither bundle_url nor bundle")
    return hosts, inline, len(attestations)
