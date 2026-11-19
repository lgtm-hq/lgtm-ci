#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Point the apt helper's Ubuntu archive sources at hosts egress allows (#1661).

GitHub's Ubuntu images read the archive through
``mirror+file:/etc/apt/apt-mirrors.txt``. Since 2026-11-19 that list names
EC2 regional mirrors such as ``us-east-2.ec2.archive.ubuntu.com`` (fixture
run 44503491578, ubuntu-24.04), which no egress preset allows: harden-runner
drops the connection and every apt call times out. Egress stays as it is;
the helper's private sources name only archive hosts the job may reach.

Which URIs change (``MirrorPolicy.target``):

- in ``ubuntu.sources`` and ``/etc/apt/sources.list`` only, a mirror URI
  (``mirror:``, ``mirror+file:``, ``mirror+http(s):``);
- in any copied file, an ``http(s)`` URI on ``archive.ubuntu.com``,
  ``security.ubuntu.com`` or a ``*.archive.ubuntu.com`` host (EC2 and other
  regional mirrors) whose host and port egress does not allow, or that is a
  ``TARGET_HOSTS`` entry egress does allow (#1664: those get failover too).

Each such URI on the ``/ubuntu`` path names a stable mirror list of allowed
hosts (#1664, ``apt_failover``): ``archive-ubuntu.txt`` holds the allowed
``https://archive``, ``http://azure.archive`` and ``http://archive`` hosts;
``security-ubuntu.txt`` the security ports, then the first allowed archive
host, which serves byte-identical signed ``-security`` pockets. When the
lists cannot be used, allowed hosts stay and others name their first
allowed host directly (#1661); the log line says why. Only the URI changes.
Other hosts (``ports.ubuntu.com``, Debian, a corporate or third-party
mirror) are left alone, and nothing is rewritten off amd64 and i386.

When anything is rewritten (``load_policy``): only when egress is
provably enforced, that is when harden-runner's agent configuration
(``/home/agent/agent.json``, the file ``verify-harden-runner-agent.sh``
already reads) carries ``"egress_policy": "block"`` and exact ``host:port``
entries in ``allowed_endpoints``. The targets are ``TARGET_HOSTS`` (the
hosts every apt-using egress preset carries) that this list also allows.
Otherwise the sources stay exactly as they are and one log line says why:
no file, not a regular file (a symlink, a FIFO), over ``MAX_CONFIG_BYTES``,
unreadable, not JSON, another policy, no exact endpoint or target host.

Reading the file never fails or blocks the helper: it is opened with
``O_NOFOLLOW | O_NONBLOCK``, must be a regular file, is read up to
``MAX_CONFIG_BYTES``, and any parse error (``RecursionError`` included)
means no rewrite.

Loaded by ``apt_helper.py`` under ``python3 -I`` on any runner ``python3``
(3.10 on ``ubuntu-22.04``): standard library only.
"""

from __future__ import annotations

import errno
import json
import os
import platform
import stat
from dataclasses import dataclass, field, replace
from pathlib import Path
from urllib.parse import urlsplit

try:
    import apt_failover
except ImportError:  # python3 -I leaves this lib/ directory off sys.path
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import apt_failover
import apt_sources  # importable once apt_failover is: same directory

AGENT_CONFIG = Path("/home/agent/agent.json")
# Upper bound of the agent configuration read; harden-runner's is a few KiB.
MAX_CONFIG_BYTES = 1 << 20
# The only hosts a URI is ever rewritten to, and only those of them the
# job's own allow list holds. Every apt-using egress preset in
# scripts/ci/lib/egress/presets.sh (playwright, shell-test, rust-release)
# carries all of them, checked by tests/python/test_apt_mirrors.py.
TARGET_HOSTS = frozenset(
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
        lists_dir: Directory of the private mirror lists; None to name the
            first allowed host directly (#1661).
        direct_reason: Why ``lists_dir`` is None, for the log line.
        changes: Each rewritten URI and its targets, in first-seen order.
        lists: Each mirror list's file name and its URIs, in order.
    """

    allowed: frozenset[tuple[str, int]]
    origin: str
    lists_dir: Path | None = None
    direct_reason: str = ""
    changes: dict[str, list[str]] = field(default_factory=dict, compare=False)
    lists: dict[str, list[str]] = field(default_factory=dict, compare=False)

    def with_lists(self, root: Path) -> MirrorPolicy:
        """Return a fresh policy naming the stable lists, written first.

        Args:
            root: The helper's temporary root (``/tmp`` on a runner).

        Returns:
            A policy with ``lists_dir`` set, or one naming hosts directly,
            with the reason, when the lists cannot be used.
        """
        stable = apt_failover.lists_dir(root)
        names = {"archive-ubuntu.txt": "", "security-ubuntu.txt": "-security"}
        found = {n: self.candidates(s, ARCHIVE_PATH)[1] for n, s in names.items()}
        lists = {name: uris for name, uris in found.items() if uris}
        blocker = apt_failover.sandbox_blocker(stable)
        why = f"{blocker} is not searchable by _apt" if blocker else ""
        if not why and lists:
            try:
                apt_failover.publish_lists(stable, lists)
            except (apt_failover.ListsRefused, OSError) as error:
                why = f"mirror lists not used ({error})"
        at = None if why or not lists else stable
        named = lists if at else {}
        return replace(self, lists_dir=at, direct_reason=why, changes={}, lists=named)

    def _allowed(self, targets: tuple[tuple[str, str], ...], path: str) -> list[str]:
        """Return the allowed target URIs, in order."""
        return [
            f"{scheme}://{host}{path}"
            for scheme, host in targets
            if (host, PORTS[scheme]) in self.allowed
        ]

    def candidates(self, suite: str, path: str) -> tuple[str, list[str]]:
        """Return the group of ``suite`` and its allowed target URIs, in order.

        Args:
            suite: One of an entry's suites, or "".
            path: The archive path, such as ``/ubuntu``.

        Returns:
            ``("security", ...)`` for a ``*-security`` suite: the security
            ports, then only the first allowed archive host, so a third
            dead host still leaves time in one attempt. Else ``("archive",
            ...)``.
        """
        archive = self._allowed(ARCHIVE_TARGETS, path)
        if suite.endswith("-security"):
            return "security", self._allowed(SECURITY_TARGETS, path) + archive[:1]
        return "archive", archive

    def _list_uri(self, group: str, path: str) -> str | None:
        """Return the stable list of ``group`` for the ``/ubuntu`` path, if any.

        Only the standard archive path has lists: one fixed name per group
        keeps apt's source identity stable, and no two paths can share one.
        """
        name = f"{group}-ubuntu.txt"
        if self.lists_dir is None or path != ARCHIVE_PATH or name not in self.lists:
            return None
        return f"mirror+file:{self.lists_dir / name}"

    def target(self, uri: str, suite: str, distribution: bool) -> str:
        """Return the URI apt should use for ``uri`` and one of its suites.

        Args:
            uri: The entry's URI.
            suite: One of its suites, or "".
            distribution: The entry is in the distribution's ``ubuntu.sources``.

        Returns:
            A private ``mirror+file:`` list of the allowed archive hosts (or,
            without ``lists_dir``, the first of them), or ``uri`` itself
            when it may stay or is not an Ubuntu archive URI.
        """
        endpoint = _endpoint(uri)
        if endpoint is not None:
            if not is_archive_host(endpoint[0]):
                return uri
            # An allowed host stays, unless a list adds failover to it (#1664).
            listed = self.lists_dir is not None and endpoint in TARGET_HOSTS
            if endpoint in self.allowed and not listed:
                return uri
            path = urlsplit(uri).path.rstrip("/") or ARCHIVE_PATH
        elif distribution and is_mirror_uri(uri):
            path = ARCHIVE_PATH
        else:
            return uri
        group, targets = self.candidates(suite, path)
        if not targets:
            return uri
        new = self._list_uri(group, path)
        if new is None and endpoint in self.allowed:
            return uri
        new = new or targets[0]
        seen = self.changes.setdefault(uri, [])
        if new not in seen:
            seen.append(new)
        return new

    def rewrite_for(self, name: str) -> apt_sources.Rewrite:
        """Return the rewrite for the sources file called ``name``."""
        distribution = name in (UBUNTU_SOURCES, apt_failover.MAIN_LIST)

        def rewrite(uri: str, suite: str) -> str:
            """Return ``target`` for this file."""
            return self.target(uri, suite, distribution)

        return rewrite

    def summary(self) -> str:
        """Return the log line naming the overridden URIs and what apt uses."""
        used = sorted({new for targets in self.changes.values() for new in targets})
        named = []
        for new in used:
            name = new.rpartition("/")[2] if new.startswith("mirror+file:") else ""
            hosts = self.lists.get(name)
            named.append(f"{new} ({', '.join(hosts)})" if hosts else new)
        direct = self.direct_reason and f"; one host per suite: {self.direct_reason}"
        return (
            f"overrode Ubuntu archive sources {', '.join(self.changes)}"
            f" (hosts egress may not allow); apt uses {', '.join(named)}"
            f" (allowed archive hosts from {self.origin}){direct}"
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
        # isascii: str.isdigit() also accepts digits int() refuses ("²").
        if sep and port.isascii() and port.isdigit() and host and "*" not in host:
            pairs.add((host.rstrip(".").lower(), int(port)))
    return frozenset(pairs)


class ConfigError(Exception):
    """Raised when the agent configuration cannot be used; the message says why."""


def read_config(config: Path) -> bytes:
    """Read the agent configuration without following links or blocking.

    Args:
        config: harden-runner's agent configuration.

    Returns:
        Its bytes.

    Raises:
        ConfigError: When it is missing, unreadable, not a regular file
            (a symlink, a FIFO, a device) or over ``MAX_CONFIG_BYTES``.
    """
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(config, flags)
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise ConfigError(f"{config} is a symbolic link") from error
        raise ConfigError(f"cannot read {config}: {error.strerror or error}") from error
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ConfigError(f"{config} is not a regular file")
        chunks: list[bytes] = []
        size = 0
        while size <= MAX_CONFIG_BYTES:
            chunk = os.read(fd, MAX_CONFIG_BYTES + 1 - size)
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        if size > MAX_CONFIG_BYTES:
            raise ConfigError(f"{config} is larger than {MAX_CONFIG_BYTES} bytes")
        return b"".join(chunks)
    except OSError as error:
        raise ConfigError(f"cannot read {config}: {error.strerror or error}") from error
    finally:
        os.close(fd)


def allowed_endpoints(config: Path) -> frozenset[tuple[str, int]]:
    """Return the exact endpoints of an agent configuration that proves block mode.

    Args:
        config: harden-runner's agent configuration.

    Returns:
        Its non-empty set of exact ``(host, port)`` pairs.

    Raises:
        ConfigError: When the file does not prove block-mode egress with at
            least one exact endpoint; the message says why.
    """
    raw_bytes = read_config(config)
    try:
        data = json.loads(raw_bytes.decode("utf-8"))
    except RecursionError as error:
        raise ConfigError(f"{config} nests too deeply to parse") from error
    except ValueError as error:
        # JSONDecodeError and UnicodeDecodeError are ValueErrors. Nothing
        # broader is caught here, so the helper's Interrupted (raised by its
        # signal handler) still ends the run instead of reading as bad JSON.
        raise ConfigError(f"{config} is not valid UTF-8 JSON") from error
    if not isinstance(data, dict):
        raise ConfigError(f"{config} is not a JSON object")
    if data.get("egress_policy") != "block":
        raise ConfigError(f"{config} does not carry egress_policy block")
    raw = data.get("allowed_endpoints")
    allowed = parse_endpoints(raw) if isinstance(raw, str) else frozenset()
    if not allowed:
        raise ConfigError(f"{config} lists no exact host:port endpoint")
    return allowed


def load_policy(
    config: Path = AGENT_CONFIG,
    machine: str | None = None,
) -> tuple[MirrorPolicy | None, str]:
    """Build the policy from the job's egress configuration.

    Args:
        config: harden-runner's agent configuration.
        machine: ``platform.machine()`` (injected by tests).

    Returns:
        The policy, or None when nothing may be rewritten, and a log note
        saying why (empty when there is a policy).
    """
    machine = platform.machine() if machine is None else machine
    if machine.lower() not in ARCHIVE_MACHINES:
        return None, f"{machine} runner: Ubuntu ports sources left as they are"
    try:
        allowed = allowed_endpoints(config)
    except ConfigError as error:
        return None, f"egress enforcement not proven ({error})"
    archive = frozenset(pair for pair in allowed if is_archive_host(pair[0]))
    if not archive & TARGET_HOSTS:
        return None, f"the egress allow list in {config} allows no target archive host"
    return MirrorPolicy(archive, str(config)), ""
