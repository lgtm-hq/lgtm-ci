#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Check that every egress allow-listed host resolves the way harden-runner needs.

Under ``egress-policy: block`` the harden-runner agent resolves every
non-wildcard allowed host when it starts. One host that does not resolve makes
it revert, and the job then runs unhardened (#1203, #1547). This script
resolves every such host the way the agent does and reports the ones that
fail (#1548).

How the agent resolves (step-security/agent v0.18.0, the open-source agent
that harden-runner v2.22.3 installs for public repositories; checked
2026-11-16):

- ``dnsproxy.go`` ``ResolveDomain``: ``GET https://dns.google/resolve?name=
  <host>.&type=a`` with ``accept: application/dns-json``. Only when that
  request fails at the transport level does it retry once against
  ``https://cloudflare-dns.com/dns-query?name=<host>.&type=A``. It does not
  look at the HTTP status or the DNS ``Status``: it takes the first answer of
  type 1 (A) and fails when there is none (NXDOMAIN, or NOERROR with only a
  CNAME chain or no answer at all).
  https://github.com/step-security/agent/blob/v0.18.0/dnsproxy.go#L119-L170
- ``agent.go`` ``Run``: under block it calls ``getIPByDomain`` for every
  non-wildcard allowed host, and on the first error writes "Reverting agent
  since allowed endpoint ... could not be resolved" and reverts. Wildcard
  entries (``*.``) are kept apart by ``addImplicitEndpoints`` and resolved
  only when a job looks one up, so they are skipped here.
  https://github.com/step-security/agent/blob/v0.18.0/agent.go#L177-L193
- harden-runner picks that agent in ``src/install-agent.ts``:
  https://github.com/step-security/harden-runner/blob/46b06cea07f9e64621fdf066ba77ac6915163d43/src/install-agent.ts

So Google decides the verdict here, with the same query (FQDN, type A).
Cloudflare is only a second opinion, queried for a failing host and shown in
the report; it never changes the verdict.

Hosts checked: every host of every preset in ``egress_preset_names``, of
``egress_github_results_storage_endpoints`` and of
``egress_ai_review_provider_endpoints`` for every AI review matrix row (read
by sourcing ``scripts/ci/lib/egress/presets.sh``), plus the ``host:port``
values of ``*allowed-endpoints*`` keys in ``examples/`` and in the fenced code
blocks of ``docs/``, plus ``--extra-hosts``.

Verdict per host: it resolves when an attempt returns an A record. It fails
only when it collects the full number of DNS-level negative answers (with
backoff): NXDOMAIN, NOERROR without an A record, or another DNS status such as
SERVFAIL. A transport error, an HTTP error or an undecodable answer is not a
DNS answer: the query is repeated, within its own equal budget, so one resolver
hiccup does not hide a failing host. A host whose error budget runs out is
undetermined, which fails the whole run closed (exit 2), as does a run where
no host resolves or the deadline passes. Hosts that fail are resolved a second
time after a pause (60 s by default) and count as failing only if they fail
again, so a short outage of a vendor's DNS does not open the issue.

Usage:
    python3 scripts/ci/maintenance/check-egress-dns.py \
        [--issue-body /tmp/body.md] [--extra-hosts "bad.invalid:443"]

Exit codes:
    0 - every checked host resolves
    1 - at least one host fails to resolve; the report is printed (and the
        tracking-issue body written to ``--issue-body`` when given)
    2 - usage error, unreadable presets, a resolver that could not be reached
        or answered with errors, or any other unexpected error (never 1)
"""

# pylint: disable=invalid-name  # CLI script; hyphenated filename is the invocation contract

from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable, Iterable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from enum import StrEnum, auto
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from egress_allow_list_documents import (  # noqa: E402  # pylint: disable=wrong-import-position
    ENDPOINT,
    DnsCheckError,
    allow_list_entries,
    document_endpoints,
)

__all__ = ["allow_list_entries", "document_endpoints"]

ROOT = Path(__file__).resolve().parents[3]
PRESETS = ROOT / "scripts/ci/lib/egress/presets.sh"
AI_REVIEW_MATRIX = ROOT / "scripts/ci/lib/ai_review_matrix.sh"
ISSUE_MARKER = "<!-- lgtm-ci:egress-dns-check -->"
GOOGLE = "https://dns.google/resolve"
CLOUDFLARE = "https://cloudflare-dns.com/dns-query"
USER_AGENT = "lgtm-ci-egress-dns-check"
EXTRA_SOURCE = "workflow_dispatch input extra-hosts"
MAX_BODY_BYTES = 65536
# HTTPS only (no http:, file:, ftp: or data: handler) and no redirect handler:
# a 3xx answer is an HTTP error, never a fetch from another host.
OPENER = urllib.request.OpenerDirector()
for _handler in (
    urllib.request.HTTPSHandler(),
    urllib.request.HTTPDefaultErrorHandler(),
    urllib.request.HTTPErrorProcessor(),
):
    OPENER.add_handler(_handler)
DNS_STATUS_NAMES = {2: "SERVFAIL", 3: "NXDOMAIN", 5: "REFUSED"}
A_RECORD = 1

_LABEL = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
HOSTNAME = re.compile(rf"^{_LABEL}(?:\.{_LABEL})*\.[a-z][a-z0-9-]*[a-z0-9]$")

# Placeholder hosts in docs and examples, never meant to resolve. Only document
# sources are filtered; a preset or an extra host is always checked.
IGNORED_HOSTS: dict[str, str] = {
    "registry.example.com": "docs/onboarding.md placeholder (RFC 2606 domain)",
}

# Prints "<source>\t<endpoint>" for every preset, the results storage list and
# every AI review provider row. Any failing function aborts the script.
_COLLECT_SCRIPT = r"""
set -euo pipefail
source "$1"
source "$2"
emit() {
	local line
	while IFS= read -r line; do
		[[ -z "$line" ]] || printf '%s\t%s\n' "$1" "$line"
	done <<<"$2"
}
# Each list is a standalone assignment: a command substitution used as an
# argument would hide the function's failure from `set -e`.
names="$(egress_preset_names)"
for name in $names; do
	list="$(egress_preset_endpoints "$name")"
	emit "preset $name" "$list"
done
list="$(egress_github_results_storage_endpoints)"
emit egress_github_results_storage_endpoints "$list"
rows="$(ai_review_matrix_rows | cut -d '|' -f 1-3)"
while IFS='|' read -r provider transport auth; do
	list="$(egress_ai_review_provider_endpoints "$provider" "$transport" "$auth")"
	emit "egress_ai_review_provider_endpoints $provider/$transport/$auth" "$list"
done <<<"$rows"
"""

EXIT_CLEAN = 0
EXIT_FAILED = 1
EXIT_ERROR = 2


class ResolverError(Exception):
    """Raised by a fetch function when the resolver could not answer."""


class Outcome(StrEnum):
    """What one DNS-over-HTTPS query returned."""

    RESOLVES = auto()
    NEGATIVE = auto()
    ERROR = auto()


@dataclass(frozen=True)
class Attempt:
    """One query result.

    Attributes:
        outcome: Whether the answer had an A record, was negative, or failed.
        detail: A short description, such as ``NXDOMAIN`` or ``HTTP 503``.
    """

    outcome: Outcome
    detail: str


@dataclass
class Host:
    """One host to resolve and where the allow-lists name it.

    Attributes:
        name: The host name, without port.
        sources: Where it is allow-listed, e.g. ``preset docker``.
    """

    name: str
    sources: set[str] = field(default_factory=set)


@dataclass(frozen=True)
class Inventory:
    """Every allow-listed host, split by what the agent does with it.

    Attributes:
        hosts: Hosts the agent resolves at start-up, by name.
        wildcards: Wildcard entries the agent skips at start-up, with sources.
        ignored: Document placeholder hosts not checked, with their sources.
    """

    hosts: dict[str, Host]
    wildcards: dict[str, Host]
    ignored: dict[str, Host]


@dataclass(frozen=True)
class Verdict:
    """The result for one host.

    Attributes:
        host: The checked host.
        attempts: Every Google attempt, in order.
        second_opinion: The Cloudflare answer, queried only for a failing host.
    """

    host: Host
    attempts: tuple[Attempt, ...]
    second_opinion: Attempt | None = None

    @property
    def outcome(self) -> Outcome:
        """Return RESOLVES, NEGATIVE or ERROR.

        An A record on any attempt resolves. Otherwise the last attempt
        decides: lookups stop on a negative answer only once the budget of
        DNS answers is full, and on an error only once the error budget is.
        """
        if any(attempt.outcome is Outcome.RESOLVES for attempt in self.attempts):
            return Outcome.RESOLVES
        if self.attempts and self.attempts[-1].outcome is Outcome.NEGATIVE:
            return Outcome.NEGATIVE
        return Outcome.ERROR


Fetch = Callable[[str], bytes]


def parse_endpoint(token: str) -> tuple[str, bool]:
    """Split one allow-list entry into its host and whether it is a wildcard.

    Args:
        token: A ``host:port`` entry; the host may hold ``*``.

    Returns:
        The host name, lower-cased, and True for a wildcard entry. A
        wildcard keeps its ``*`` and is not checked as a DNS name: the agent
        never resolves it at start-up.

    Raises:
        DnsCheckError: When the entry is not a valid ``host:port``.
    """
    match = ENDPOINT.match(token.lower())
    if match is None or not 0 < int(match.group("port")) < 65536:
        raise DnsCheckError(f"not a host:port allow-list entry: {token!r}")
    host = match.group("host")
    if "*" in host:
        # The agent treats any name holding "*" as a wildcard, not only "*.".
        return host, True
    if not HOSTNAME.match(host):
        raise DnsCheckError(f"not a DNS host name: {token!r}")
    return host, False


def preset_endpoints(
    presets: Path = PRESETS,
    matrix: Path = AI_REVIEW_MATRIX,
) -> list[tuple[str, str]]:
    """Read every preset entry by sourcing ``presets.sh``.

    Args:
        presets: Path to ``scripts/ci/lib/egress/presets.sh``.
        matrix: Path to ``scripts/ci/lib/ai_review_matrix.sh``.

    Returns:
        ``(source, endpoint)`` pairs, in the order the functions print them.

    Raises:
        DnsCheckError: When bash fails or prints an unexpected line.
    """
    try:
        completed = subprocess.run(
            [
                "bash",
                "-c",
                _COLLECT_SCRIPT,
                "check-egress-dns",
                str(presets),
                str(matrix),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        raise DnsCheckError(f"could not run bash: {error}") from error
    if completed.returncode != 0:
        stderr = completed.stderr.strip()
        raise DnsCheckError(
            f"reading the presets failed ({completed.returncode}): {stderr}",
        )
    pairs: list[tuple[str, str]] = []
    for line in completed.stdout.splitlines():
        source, separator, endpoint = line.partition("\t")
        if not separator or not source or not endpoint:
            raise DnsCheckError(f"unexpected preset line {line!r}")
        pairs.append((source, endpoint))
    if not pairs:
        raise DnsCheckError("the presets printed no endpoint")
    return pairs


def build_inventory(
    pairs: Iterable[tuple[str, str]],
    documents: Iterable[tuple[str, str]] = (),
) -> Inventory:
    """Deduplicate entries by host and record every source.

    Args:
        pairs: ``(source, endpoint)`` pairs that are always checked.
        documents: ``(source, endpoint)`` pairs from documents, where
            :data:`IGNORED_HOSTS` placeholders are set aside.

    Returns:
        The hosts to resolve, the wildcards skipped and the ignored hosts.

    Raises:
        DnsCheckError: When an entry is not a valid ``host:port``.
    """
    hosts: dict[str, Host] = {}
    wildcards: dict[str, Host] = {}
    ignored: dict[str, Host] = {}
    tagged = [(source, endpoint, False) for source, endpoint in pairs]
    tagged += [(source, endpoint, True) for source, endpoint in documents]
    for source, endpoint, from_document in tagged:
        placeholder = endpoint.lower().rpartition(":")[0]
        if from_document and placeholder in IGNORED_HOSTS:
            ignored.setdefault(placeholder, Host(placeholder)).sources.add(source)
            continue
        host, wildcard = parse_endpoint(endpoint)
        bucket = wildcards if wildcard else hosts
        bucket.setdefault(host, Host(host)).sources.add(source)
    return Inventory(hosts=hosts, wildcards=wildcards, ignored=ignored)


def classify(body: bytes) -> Attempt:
    """Classify a DNS-over-HTTPS JSON answer as the agent would.

    Args:
        body: The response body.

    Returns:
        RESOLVES with the first A record, NEGATIVE with the DNS status, or
        ERROR when the body is not a DNS JSON answer.
    """
    try:
        payload: Any = json.loads(body)
    except ValueError:
        return Attempt(Outcome.ERROR, "undecodable answer")
    reason = _malformed(payload)
    if reason:
        return Attempt(Outcome.ERROR, reason)
    for answer in payload.get("Answer") or []:
        if answer.get("type") == A_RECORD:
            return Attempt(Outcome.RESOLVES, f"A {answer['data']}")
    status = payload["Status"]
    if status == 0:
        return Attempt(Outcome.NEGATIVE, "NOERROR without an A record")
    name = DNS_STATUS_NAMES.get(status, f"DNS status {status}")
    return Attempt(Outcome.NEGATIVE, name)


def _malformed(payload: Any) -> str:
    """Say why a decoded answer is not a usable DNS JSON answer, or ``""``.

    The agent decodes the whole answer into typed fields and rejects it on
    any mismatch, so every field it knows is checked before a record is used.

    Args:
        payload: The decoded JSON value.

    Returns:
        A short reason, or an empty string for a well-formed answer.
    """
    status = payload.get("Status") if isinstance(payload, dict) else None
    if not isinstance(status, int) or isinstance(status, bool):
        return "answer without a DNS Status"
    if not _valid_envelope(payload):
        return "answer with malformed flags or Question"
    answers = payload.get("Answer")
    if answers is not None and not (
        isinstance(answers, list) and all(_valid_answer(a) for a in answers)
    ):
        return "answer with a malformed Answer list"
    return ""


def _typed(record: Any, fields: tuple[tuple[str, type], ...]) -> bool:
    """Tell whether a JSON object's fields, where present, have their types."""
    if not isinstance(record, dict):
        return False
    for key, kind in fields:
        value = record.get(key)
        if value is None:
            continue
        if not isinstance(value, kind) or (kind is int and isinstance(value, bool)):
            return False
    return True


def _valid_envelope(payload: dict[str, Any]) -> bool:
    """Tell whether the answer's flags and Question list have their types.

    The agent decodes ``TC``, ``RD``, ``RA``, ``AD`` and ``CD`` as booleans
    and ``Question`` as a list of ``{name, type}`` records, and rejects the
    whole answer on a mismatch.

    Args:
        payload: The decoded answer.

    Returns:
        True when every flag and question has its documented type.
    """
    flags = tuple((name, bool) for name in ("TC", "RD", "RA", "AD", "CD"))
    if not _typed(payload, flags):
        return False
    questions = payload.get("Question")
    if questions is None:
        return True
    return isinstance(questions, list) and all(
        _typed(question, (("name", str), ("type", int))) for question in questions
    )


def _valid_answer(answer: Any) -> bool:
    """Tell whether one Answer record has the documented field types.

    The agent decodes the whole answer into typed fields and fails on any
    mismatch, so every record is checked, not only the first A record. An A
    record must also carry its address.

    Args:
        answer: One element of the ``Answer`` list.

    Returns:
        True when ``name`` and ``data`` are strings and ``type`` and ``TTL``
        are integers, where present.
    """
    fields = (("name", str), ("data", str), ("type", int), ("TTL", int))
    if not _typed(answer, fields):
        return False
    return answer.get("type") != A_RECORD or bool(answer.get("data"))


def query_url(resolver: str, host: str) -> str:
    """Return the agent's query URL for a host: its FQDN, type A."""
    name = urllib.parse.quote(f"{host}.", safe=".")
    return f"{resolver}?name={name}&type=A"


def query(fetch: Fetch, resolver: str, host: str) -> Attempt:
    """Ask one resolver for the A record of a host.

    Args:
        fetch: Returns the response body for a URL, or raises ResolverError.
        resolver: The resolver's JSON API URL.
        host: The host name.

    Returns:
        The classified answer; a ResolverError becomes an ERROR attempt.
    """
    try:
        body = fetch(query_url(resolver, host))
    except ResolverError as error:
        return Attempt(Outcome.ERROR, str(error))
    return classify(body)


@dataclass(frozen=True)
class Policy:
    """How hard to try before a host counts as failing.

    Attributes:
        attempts: DNS answers needed from Google before a host fails; also
            the number of resolver errors tolerated per host.
        retry_delay: Seconds before the second query; doubles each time.
        deadline: Monotonic time after which the run fails closed.
        sleep: The sleep function (a no-op when replaying fixtures).
        recheck_delay: Seconds to wait before failing hosts are resolved a
            second time.
    """

    attempts: int
    retry_delay: float
    deadline: float
    sleep: Callable[[float], None] = time.sleep
    recheck_delay: float = 0.0


def _pause(policy: Policy, seconds: float, what: str) -> None:
    """Sleep, unless the pause would end after the deadline.

    Args:
        policy: The sleep function and the deadline.
        seconds: How long to pause.
        what: What the pause is for, for the error.

    Raises:
        DnsCheckError: When the deadline would pass during the pause.
    """
    if time.monotonic() + seconds > policy.deadline:
        raise DnsCheckError(f"deadline would pass during {what}")
    policy.sleep(seconds)


def resolve(fetch: Fetch, host: Host, policy: Policy) -> Verdict:
    """Resolve one host with bounded retries, as the agent's resolver would.

    Args:
        fetch: The fetch function.
        host: The host to resolve.
        policy: Attempts, backoff and deadline.

    Returns:
        The verdict, with a Cloudflare second opinion when the host fails.

    Raises:
        DnsCheckError: When the deadline passes.
    """
    attempts: list[Attempt] = []
    negatives = errors = 0
    while negatives < policy.attempts and errors < policy.attempts:
        if time.monotonic() > policy.deadline:
            raise DnsCheckError(f"deadline passed while resolving {host.name}")
        if attempts:
            delay = policy.retry_delay * 2 ** min(len(attempts) - 1, 3)
            _pause(policy, delay, f"the backoff for {host.name}")
        attempt = query(fetch, GOOGLE, host.name)
        if time.monotonic() > policy.deadline:
            # An answer that arrives after the deadline is not used.
            raise DnsCheckError(f"deadline passed while resolving {host.name}")
        attempts.append(attempt)
        if attempt.outcome is Outcome.RESOLVES:
            break
        if attempt.outcome is Outcome.NEGATIVE:
            negatives += 1
        else:
            errors += 1
    verdict = Verdict(host=host, attempts=tuple(attempts))
    if verdict.outcome is Outcome.NEGATIVE:
        opinion = query(fetch, CLOUDFLARE, host.name)
        if time.monotonic() > policy.deadline:
            raise DnsCheckError(f"deadline passed while resolving {host.name}")
        return Verdict(host, verdict.attempts, opinion)
    return verdict


def _merged(first: Verdict, second: Verdict) -> Verdict:
    """Join a failing host's first verdict with its recheck; the recheck decides."""
    return Verdict(
        host=first.host,
        attempts=first.attempts + second.attempts,
        second_opinion=second.second_opinion or first.second_opinion,
    )


def resolve_all(
    fetch: Fetch,
    hosts: Iterable[Host],
    policy: Policy,
    workers: int,
) -> list[Verdict]:
    """Resolve every host with limited concurrency.

    Args:
        fetch: The fetch function.
        hosts: The hosts to resolve.
        policy: Attempts, backoff and deadline.
        workers: Concurrent lookups, at most.

    Returns:
        One verdict per host, sorted by host name.

    Raises:
        DnsCheckError: When the deadline passes, a host stays undetermined,
            or no host resolves at all (the resolver itself is unusable).
    """
    ordered = sorted(hosts, key=lambda host: host.name)
    pool = ThreadPoolExecutor(max_workers=workers)
    try:
        verdicts = list(pool.map(lambda host: resolve(fetch, host, policy), ordered))
        failing = [v for v in verdicts if v.outcome is Outcome.NEGATIVE]
        if failing:
            # A failure must persist: a short outage of a vendor's DNS clears.
            _pause(policy, policy.recheck_delay, "the pause before the recheck")
            again = pool.map(lambda v: resolve(fetch, v.host, policy), failing)
            merged = {
                first.host.name: _merged(first, second)
                for first, second in zip(failing, again, strict=True)
            }
            verdicts = [merged.get(v.host.name, v) for v in verdicts]
    finally:
        # Queued lookups are dropped. A running one ends at its next deadline
        # check, at most one request (bounded by the deadline) later.
        pool.shutdown(wait=True, cancel_futures=True)
    undetermined = [verdict for verdict in verdicts if verdict.outcome is Outcome.ERROR]
    if undetermined:
        named = [f"{v.host.name}: {v.attempts[-1].detail}" for v in undetermined]
        details = "; ".join(named[:5])
        raise DnsCheckError(
            f"{len(undetermined)} host(s) got no DNS answer from {GOOGLE} "
            f"(resolver unreachable or erroring): {details}",
        )
    if verdicts and not any(v.outcome is Outcome.RESOLVES for v in verdicts):
        raise DnsCheckError(f"no host resolved through {GOOGLE}; resolver unusable")
    return verdicts


def urllib_fetch(url: str, timeout: float = 10.0) -> bytes:
    """Fetch a DNS JSON answer over HTTPS.

    Args:
        url: A query URL under :data:`GOOGLE` or :data:`CLOUDFLARE`.
        timeout: Seconds per request.

    Returns:
        The response body.

    Raises:
        ResolverError: On a transport error or a non-200 response.
    """
    if not url.startswith((f"{GOOGLE}?", f"{CLOUDFLARE}?")):
        raise ResolverError(f"refusing to fetch {url}")
    request = urllib.request.Request(
        url,
        headers={"accept": "application/dns-json", "user-agent": USER_AGENT},
    )
    try:
        # The URL is one of the two fixed https resolver endpoints (checked above).
        with OPENER.open(request, timeout=timeout) as response:  # nosec B310
            if response.status != 200:
                raise ResolverError(f"HTTP {response.status}")
            return bytes(response.read(MAX_BODY_BYTES))
    except urllib.error.HTTPError as error:
        raise ResolverError(f"HTTP {error.code}") from error
    except (urllib.error.URLError, OSError, http.client.HTTPException) as error:
        # HTTPException (a truncated body, a bad status line) is not an
        # OSError; uncaught, it would abort the run instead of being retried.
        raise ResolverError(f"transport error: {error!r}") from error


class ReplayFetch:  # pylint: disable=too-few-public-methods  # a stateful callable
    """Answer queries from a recorded responses file (offline tests).

    The file is ``{"google": {host: [reply, ...]}, "cloudflare": {...},
    "default": reply}``. A reply is a DNS JSON answer (an object with
    ``Status``), ``{"http_status": N}`` or ``{"transport_error": "..."}``.
    Successive queries for a host take successive replies; the last repeats.
    A host without replies gets ``default``.

    Args:
        recorded: The parsed responses file.
    """

    def __init__(self, recorded: dict[str, Any]) -> None:
        self._recorded = recorded
        self._calls: dict[tuple[str, str], int] = {}
        self._lock = threading.Lock()

    def __call__(self, url: str) -> bytes:
        """Return the next recorded reply for the URL's resolver and host.

        Args:
            url: A query URL built by :func:`query_url`.

        Returns:
            The reply body.

        Raises:
            ResolverError: For a recorded HTTP or transport error.
        """
        base, _, query_string = url.partition("?")
        resolver = "google" if base == GOOGLE else "cloudflare"
        host = urllib.parse.parse_qs(query_string)["name"][0].rstrip(".")
        replies = self._recorded.get(resolver, {}).get(host)
        with self._lock:
            count = self._calls.get((resolver, host), 0)
            self._calls[(resolver, host)] = count + 1
        reply = replies[min(count, len(replies) - 1)] if replies else None
        if reply is None:
            reply = self._recorded.get("default", {"Status": 3})
        if "http_status" in reply:
            raise ResolverError(f"HTTP {reply['http_status']}")
        if "transport_error" in reply:
            raise ResolverError(f"transport error: {reply['transport_error']}")
        return json.dumps(reply).encode("utf-8")


def _sources(host: Host) -> str:
    """Render a host's sources as one comma-separated line."""
    return ", ".join(f"`{source}`" for source in sorted(host.sources))


def render_report(inventory: Inventory, verdicts: list[Verdict]) -> str:
    """Render the plain-text report for the job log.

    Args:
        inventory: The collected hosts.
        verdicts: One verdict per checked host.

    Returns:
        A summary line, then one line per failing, skipped or ignored host.
    """
    failing = [v for v in verdicts if v.outcome is Outcome.NEGATIVE]
    lines = [
        f"Checked {len(verdicts)} hosts: {len(verdicts) - len(failing)} resolve, "
        f"{len(failing)} fail; {len(inventory.wildcards)} wildcard entries skipped, "
        f"{len(inventory.ignored)} placeholders ignored.",
    ]
    for verdict in failing:
        second = verdict.second_opinion.detail if verdict.second_opinion else "n/a"
        lines.append(
            f"FAIL {verdict.host.name}: Google {verdict.attempts[-1].detail} "
            f"({len(verdict.attempts)} attempts); Cloudflare second opinion: "
            f"{second}; allow-listed in: {', '.join(sorted(verdict.host.sources))}",
        )
    for wildcard in sorted(inventory.wildcards.values(), key=lambda h: h.name):
        lines.append(
            f"SKIP {wildcard.name}: wildcard, not resolved by the agent at start-up; "
            f"in: {', '.join(sorted(wildcard.sources))}",
        )
    for host in sorted(inventory.ignored.values(), key=lambda h: h.name):
        lines.append(f"IGNORE {host.name}: {IGNORED_HOSTS[host.name]}")
    return "\n".join(lines)


def render_issue_body(verdicts: list[Verdict]) -> str:
    """Render the tracking-issue body for the failing hosts.

    The body is deterministic (no run URL, timestamp, IP or Cloudflare
    answer) so an unchanged failure leaves the issue untouched.

    Args:
        verdicts: One verdict per checked host.

    Returns:
        Markdown issue body, starting with the stable marker.
    """
    failing = [v for v in verdicts if v.outcome is Outcome.NEGATIVE]
    lines = [f"- `{v.host.name}`: {v.attempts[-1].detail}" for v in failing]
    rows = "\n".join(
        f"{line}; in {_sources(v.host)}" for line, v in zip(lines, failing, strict=True)
    )
    return f"""{ISSUE_MARKER}

## Summary

These allow-listed hosts do not resolve to an A record through
`{GOOGLE}`, the resolver the harden-runner agent queries at start-up.
Under `egress-policy: block` the agent resolves every non-wildcard allowed
host when it starts and reverts on the first one that fails, so every job
whose allow-list carries one of these hosts runs **unhardened** (#1203,
#1547).

## Failing hosts

{rows}

## What to change

1. Remove or correct each host where it is listed. A preset source is
   `egress_preset_endpoints <name>` (or the named function) in
   `scripts/ci/lib/egress/presets.sh`; an AI review provider source is a row
   of `scripts/ci/lib/ai_review_matrix.sh`; a `path:line` source is a document
   or example.
2. After a preset change, run `bash scripts/ci/egress/sync-workflow-presets.sh`
   and commit the regenerated workflows.

This issue is updated by the scheduled
`.github/workflows/egress-dns-check.yml` run and closed by it once every host
resolves again (#1548).
"""


def _bounded_fetch(deadline: float) -> Fetch:
    """Return the real fetch with each request's timeout cut to the deadline.

    Args:
        deadline: Monotonic time after which the run fails closed.

    Returns:
        A fetch whose request never waits more than 10 s, nor much past the
        deadline (1 s at least, so a request made at the deadline still ends).
    """

    def fetch(url: str) -> bytes:
        remaining = deadline - time.monotonic()
        return urllib_fetch(url, timeout=max(1.0, min(10.0, remaining)))

    return fetch


def _extra_endpoints(value: str) -> list[tuple[str, str]]:
    """Validate the ``--extra-hosts`` value strictly.

    Args:
        value: Space-separated ``host:port`` tokens.

    Returns:
        ``(source, endpoint)`` pairs.

    Raises:
        DnsCheckError: On a token that is not a plain ``host:port``.
    """
    pairs: list[tuple[str, str]] = []
    for token in value.split():
        _, wildcard = parse_endpoint(token)
        if wildcard:
            raise DnsCheckError(f"extra hosts take no wildcard: {token!r}")
        pairs.append((EXTRA_SOURCE, token))
    return pairs


def _load_replay(path: Path) -> ReplayFetch:
    """Load a recorded responses file.

    Args:
        path: The JSON file.

    Returns:
        A fetch function that replays it.

    Raises:
        DnsCheckError: When the file cannot be read or is not a JSON object.
    """
    try:
        recorded = json.loads(path.read_text("utf-8"))
    except (OSError, ValueError) as error:
        raise DnsCheckError(f"could not read responses {path}: {error}") from error
    if not isinstance(recorded, dict):
        raise DnsCheckError(f"responses {path} is not a JSON object")
    return ReplayFetch(recorded)


def _no_sleep(_seconds: float) -> None:
    """Skip the backoff: a replayed answer never changes by waiting."""


def _parser() -> argparse.ArgumentParser:
    """Build the command-line parser."""
    parser = argparse.ArgumentParser(
        description="Resolve every egress allow-listed host as harden-runner does.",
        epilog="See lgtm-ci#1548. Fails closed when the resolver cannot answer.",
    )
    parser.add_argument("--issue-body", type=Path, help="Write the issue body here.")
    parser.add_argument(
        "--extra-hosts",
        default="",
        help="Space-separated host:port entries to check as well.",
    )
    parser.add_argument(
        "--responses",
        type=Path,
        help="Replay recorded resolver answers from this JSON file (tests).",
    )
    parser.add_argument("--attempts", type=int, default=3, choices=range(1, 6))
    parser.add_argument("--retry-delay", type=float, default=2.0)
    parser.add_argument("--recheck-delay", type=float, default=60.0)
    parser.add_argument("--deadline", type=float, default=240.0, help="Seconds.")
    parser.add_argument("--workers", type=int, default=8, choices=range(1, 17))
    return parser


WATCHDOG_GRACE = 15.0


def _watchdog_expired() -> None:
    """End the process with the error status: the run outlived its deadline.

    A request's timeout bounds each socket wait, not the whole request, so a
    resolver that trickles its answer could hold a worker past the deadline.
    ``os._exit`` ends the process whatever its threads are doing.
    """
    print("[ERROR] the run outlived its deadline; stopped", file=sys.stderr)
    sys.stderr.flush()
    os._exit(EXIT_ERROR)


def _arm_watchdog(seconds: float) -> threading.Timer:
    """Start the timer that stops the process shortly after the deadline.

    Args:
        seconds: The run's deadline, in seconds from now.

    Returns:
        The started daemon timer.
    """
    timer = threading.Timer(seconds + WATCHDOG_GRACE, _watchdog_expired)
    timer.daemon = True
    timer.start()
    return timer


def _run(argv: list[str] | None) -> int:
    """Run the check.

    Args:
        argv: Optional argument vector (defaults to ``sys.argv[1:]``).

    Returns:
        0 when every host resolves, 1 when one fails, 2 on an error.
    """
    args = _parser().parse_args(argv)
    watchdog = _arm_watchdog(args.deadline)
    try:
        return _check(args)
    finally:
        watchdog.cancel()


def _check(args: argparse.Namespace) -> int:
    """Collect the hosts, resolve them and report.

    Args:
        args: The parsed command line.

    Returns:
        0 when every host resolves, 1 when one fails, 2 on an error.
    """
    try:
        deadline = time.monotonic() + args.deadline
        fetch: Fetch = _bounded_fetch(deadline)
        sleep: Callable[[float], None] = time.sleep
        if args.responses is not None:
            fetch = _load_replay(args.responses)
            sleep = _no_sleep
        inventory = build_inventory(
            preset_endpoints() + _extra_endpoints(args.extra_hosts),
            document_endpoints(),
        )
        policy = Policy(
            attempts=args.attempts,
            retry_delay=max(args.retry_delay, 0.0),
            deadline=deadline,
            sleep=sleep,
            recheck_delay=max(args.recheck_delay, 0.0),
        )
        verdicts = resolve_all(fetch, inventory.hosts.values(), policy, args.workers)
    except DnsCheckError as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        return EXIT_ERROR

    print(render_report(inventory, verdicts))
    if all(verdict.outcome is Outcome.RESOLVES for verdict in verdicts):
        print("[INFO] every allow-listed host resolves", file=sys.stderr)
        return EXIT_CLEAN
    print("[ERROR] allow-listed hosts fail to resolve; see FAIL lines", file=sys.stderr)
    if args.issue_body is not None:
        args.issue_body.write_text(render_issue_body(verdicts), encoding="utf-8")
    return EXIT_FAILED


def main(argv: list[str] | None = None) -> int:
    """Run the check, failing closed on any unexpected error.

    Exit 1 means "a host fails" and makes the caller update the tracking
    issue, so an unexpected exception must never surface as Python's default
    exit status 1.

    Args:
        argv: Optional argument vector (defaults to ``sys.argv[1:]``).

    Returns:
        0 when every host resolves, 1 when one fails, 2 on any error.
    """
    try:
        return _run(argv)
    except SystemExit as error:  # argparse usage errors exit 2 already
        return EXIT_ERROR if error.code not in (0, None) else EXIT_CLEAN
    except Exception as error:  # pylint: disable=broad-exception-caught
        print(f"[ERROR] DNS check failed: {error!r}", file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
