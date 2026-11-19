#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Point the apt helper's Ubuntu archive sources at hosts egress allows (#1661).

GitHub's Ubuntu images read the archive through
``mirror+file:/etc/apt/apt-mirrors.txt``. Since 2026-11-19 that list names
EC2 regional mirrors such as ``us-east-2.ec2.archive.ubuntu.com`` (fixture
run 44503491578, ubuntu-24.04), which no egress preset allows: harden-runner
drops the connection and every apt call times out. Egress stays as it is;
instead the helper's private ``Dir::Etc::SourceParts`` copy names only
archive hosts the job may reach.

Which URIs change (``MirrorPolicy.target``):

- in the distribution's ``ubuntu.sources`` only, a mirror URI
  (``mirror:``, ``mirror+file:``, ``mirror+http(s):``), whose hosts apt
  picks at run time;
- in any copied file, an ``http(s)`` URI on ``archive.ubuntu.com``,
  ``security.ubuntu.com`` or a ``*.archive.ubuntu.com`` host (EC2 and other
  regional mirrors) whose host and port the allowed set does not hold.

A ``*-security`` suite goes to ``security.ubuntu.com`` when it is allowed,
else to the archive host. Other suites go to the first allowed of
``https://archive.ubuntu.com``, ``http://azure.archive.ubuntu.com`` and
``http://archive.ubuntu.com``: HTTPS first where egress allows it. Only the
URI changes; ``Signed-By`` and the rest of the entry stay, so apt verifies
the same signatures as before. Any other host (``ports.ubuntu.com``, Debian,
a corporate mirror, a third-party repository) is left alone, and nothing is
rewritten on a runner that is not amd64 or i386, whose archive is
``ports.ubuntu.com``.

The allowed set (``load_policy``):

- harden-runner's agent configuration (``/home/agent/agent.json``, the file
  ``verify-harden-runner-agent.sh`` already reads) with
  ``"egress_policy": "block"`` and a non-empty ``allowed_endpoints``: its
  exact ``host:port`` entries. When it names no Ubuntu archive host the
  sources are left as they are: the caller chose that list.
- Otherwise (no file, unreadable, not JSON, not block mode, empty list, as
  in a container job or under a policy store): ``FALLBACK_ALLOWED``, the
  hosts every apt-using egress preset (``playwright``, ``shell-test``,
  ``rust-release``) carries. Never a host outside that list.

The module is loaded by ``apt_helper.py`` under ``python3 -I`` on any
runner ``python3`` (3.10 on ``ubuntu-22.04``): standard library only.
"""

from __future__ import annotations

import json
import platform
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlsplit

try:
    import apt_sources
except ImportError:  # python3 -I leaves this lib/ directory off sys.path
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import apt_sources

AGENT_CONFIG = Path("/home/agent/agent.json")
# Hosts and ports every apt-using egress preset in scripts/ci/lib/egress/
# presets.sh carries (playwright, shell-test, rust-release), checked by
# tests/python/test_apt_mirrors.py. Used when the job's own list is unknown.
FALLBACK_ALLOWED = frozenset(
    {
        ("archive.ubuntu.com", 80),
        ("archive.ubuntu.com", 443),
        ("azure.archive.ubuntu.com", 80),
        ("security.ubuntu.com", 80),
        ("security.ubuntu.com", 443),
    },
)
# Targets in order of preference: (scheme, host). HTTPS first.
ARCHIVE_TARGETS = (
    ("https", "archive.ubuntu.com"),
    ("http", "azure.archive.ubuntu.com"),
    ("http", "archive.ubuntu.com"),
)
SECURITY_TARGETS = (("https", "security.ubuntu.com"), ("http", "security.ubuntu.com"))
PORTS = {"http": 80, "https": 443}
ARCHIVE_PATH = "/ubuntu"
# Machines whose packages are on archive.ubuntu.com, not ports.ubuntu.com.
ARCHIVE_MACHINES = frozenset({"x86_64", "amd64", "i386", "i686"})
UBUNTU_SOURCES = "ubuntu.sources"


def is_archive_host(host: str) -> bool:
    """Return whether ``host`` serves the Ubuntu archive for amd64 and i386."""
    return host in ("archive.ubuntu.com", "security.ubuntu.com") or host.endswith(
        ".archive.ubuntu.com",
    )


def is_mirror_uri(uri: str) -> bool:
    """Return whether apt resolves ``uri`` through a mirror list."""
    scheme = uri.partition(":")[0].lower()
    return scheme == "mirror" or scheme.startswith("mirror+")


def _endpoint(uri: str) -> tuple[str, int] | None:
    """Return the host and port an ``http(s)`` URI connects to, if any."""
    try:
        parts = urlsplit(uri)
        port = parts.port
    except ValueError:
        return None
    scheme = parts.scheme.lower()
    if scheme not in PORTS or not parts.hostname:
        return None
    return parts.hostname.rstrip(".").lower(), port or PORTS[scheme]


@dataclass(frozen=True)
class MirrorPolicy:
    """The archive hosts apt may use, and the rewrites made with them.

    Attributes:
        allowed: Exact ``(host, port)`` pairs egress allows.
        origin: Where ``allowed`` came from, for the log line.
        changes: Each rewritten URI and its targets, in first-seen order.
    """

    allowed: frozenset[tuple[str, int]]
    origin: str
    changes: dict[str, list[str]] = field(default_factory=dict, compare=False)

    def _first(self, targets: tuple[tuple[str, str], ...], path: str) -> str | None:
        """Return the first allowed target URI, or None."""
        for scheme, host in targets:
            if (host, PORTS[scheme]) in self.allowed:
                return f"{scheme}://{host}{path}"
        return None

    def target(self, uri: str, suite: str, distribution: bool) -> str:
        """Return the URI apt should use for ``uri`` and one of its suites.

        Args:
            uri: The entry's URI.
            suite: One of its suites, or "".
            distribution: The entry is in the distribution's ``ubuntu.sources``.

        Returns:
            An allowed archive URI, or ``uri`` itself when it may stay or is
            not an Ubuntu archive URI.
        """
        endpoint = _endpoint(uri)
        if endpoint is not None:
            if not is_archive_host(endpoint[0]) or endpoint in self.allowed:
                return uri
            path = urlsplit(uri).path.rstrip("/") or ARCHIVE_PATH
        elif distribution and is_mirror_uri(uri):
            path = ARCHIVE_PATH
        else:
            return uri
        new = None
        if suite.endswith("-security"):
            new = self._first(SECURITY_TARGETS, path)
        new = new or self._first(ARCHIVE_TARGETS, path)
        if new is None:
            return uri
        seen = self.changes.setdefault(uri, [])
        if new not in seen:
            seen.append(new)
        return new

    def rewrite_for(self, name: str) -> apt_sources.Rewrite:
        """Return the rewrite for the sources file called ``name``."""
        distribution = name == UBUNTU_SOURCES

        def rewrite(uri: str, suite: str) -> str:
            """Return ``target`` for this file."""
            return self.target(uri, suite, distribution)

        return rewrite

    def summary(self) -> str:
        """Return the log line naming the overridden URIs and the hosts used."""
        used = sorted({new for targets in self.changes.values() for new in targets})
        return (
            f"overrode Ubuntu archive sources {', '.join(self.changes)}"
            f" (hosts egress may not allow); apt uses {', '.join(used)}"
            f" (allowed archive hosts from {self.origin})"
        )


def parse_endpoints(value: str) -> frozenset[tuple[str, int]]:
    """Parse harden-runner's ``allowed_endpoints``: exact ``host:port`` entries.

    Wildcards and entries without a port are ignored: this module only
    trusts exact hosts.

    Args:
        value: Space-separated (or comma-separated) ``host:port`` entries.

    Returns:
        The ``(host, port)`` pairs.
    """
    pairs: set[tuple[str, int]] = set()
    for entry in value.replace(",", " ").split():
        host, sep, port = entry.rpartition(":")
        if sep and port.isdigit() and host and "*" not in host:
            pairs.add((host.rstrip(".").lower(), int(port)))
    return frozenset(pairs)


def _read_allowed(config: Path) -> tuple[frozenset[tuple[str, int]] | None, str]:
    """Read the job's allowed endpoints; None with the reason when unknown."""
    try:
        data = json.loads(config.read_text(encoding="utf-8"))
    except OSError as error:
        return None, f"cannot read {config}: {error.strerror or error}"
    except ValueError:
        return None, f"{config} is not valid JSON"
    if not isinstance(data, dict):
        return None, f"{config} is not a JSON object"
    if data.get("egress_policy") != "block":
        return None, f"{config} does not carry egress_policy block"
    raw = data.get("allowed_endpoints")
    allowed = parse_endpoints(raw) if isinstance(raw, str) else frozenset()
    if not allowed:
        return None, f"{config} lists no exact host:port endpoint"
    return allowed, str(config)


def load_policy(
    config: Path = AGENT_CONFIG,
    machine: str | None = None,
) -> tuple[MirrorPolicy | None, str]:
    """Build the policy from the job's egress configuration.

    Args:
        config: harden-runner's agent configuration.
        machine: ``platform.machine()`` (injected by tests).

    Returns:
        The policy and a log note: the reason for the fallback list, or why
        nothing is rewritten (policy None). The note is empty when the job's
        own list is used.
    """
    machine = platform.machine() if machine is None else machine
    if machine.lower() not in ARCHIVE_MACHINES:
        return None, f"{machine} runner: Ubuntu ports sources left as they are"
    allowed, origin = _read_allowed(config)
    if allowed is None:
        fallback = "the fixed list every apt-using egress preset carries"
        return MirrorPolicy(FALLBACK_ALLOWED, fallback), origin
    archive = {pair for pair in allowed if is_archive_host(pair[0])}
    if not archive:
        note = f"the egress allow list in {origin} names no Ubuntu archive host"
        return None, f"{note}; sources left as they are"
    return MirrorPolicy(frozenset(archive), origin), ""
