# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/maintenance/check-egress-dns.py`` (#1548).

Fully offline: every lookup goes through an injected fetch function or the
recorded answers in ``tests/fixtures/egress-dns-check``; the one test of the
real fetch function replaces the opener. Host collection sources the real
``presets.sh`` with bash and reads the real ``docs/`` and ``examples/``.
"""

from __future__ import annotations

import http.client
import io
import json
import time
import urllib.error
from collections.abc import Callable
from email.message import Message
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/maintenance/check-egress-dns.py"
RESPONSES = Path("egress-dns-check/responses.json")
UNREACHABLE = Path("egress-dns-check/unreachable.json")
PROOF_HOST = "dns-check-proof.invalid"
A_RECORD: dict[str, Any] = {"type": 1, "data": "192.0.2.1"}
A_ANSWER = {"Status": 0, "Answer": [A_RECORD]}
MALFORMED = "answer with a malformed Answer list"
ENVELOPE = "answer with malformed flags or Question"


@pytest.fixture(name="dns")
def fixture_dns(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the DNS check without running it."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(autouse=True)
def _no_network(dns: ModuleType, monkeypatch: pytest.MonkeyPatch) -> None:
    """Make any real request fail, so no test can reach the network."""

    def refuse(*_args: Any, **_kwargs: Any) -> None:
        raise AssertionError("a test tried to reach the network")

    monkeypatch.setattr(dns.OPENER, "open", refuse)


def _body(payload: Any) -> bytes:
    """Encode a resolver answer."""
    return json.dumps(payload).encode("utf-8")


def _policy(dns: ModuleType, sleeps: list[float] | None = None, **kwargs: Any) -> Any:
    """Return a retry policy that records sleeps instead of sleeping."""
    record = sleeps if sleeps is not None else []
    values: dict[str, Any] = {
        "attempts": 3,
        "retry_delay": 1.0,
        "deadline": time.monotonic() + 60,
        "sleep": record.append,
    }
    values.update(kwargs)
    return dns.Policy(**values)


def _scripted(dns: ModuleType, replies: dict[str, list[Any]]) -> Any:
    """Return a fetch function answering per resolver from a reply list."""
    return dns.ReplayFetch(
        {"google": {"h.example.org": replies.get("google", [])}}
        | {"cloudflare": {"h.example.org": replies.get("cloudflare", [])}},
    )


def _run(
    dns: ModuleType,
    fixtures_dir: Path,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    *extra: str,
    responses: Path = RESPONSES,
) -> tuple[int, str, str, Path]:
    """Run the CLI against recorded answers.

    Returns:
        Exit code, stdout, stderr and the issue-body path.
    """
    body = tmp_path / "body.md"
    argv = ["--responses", str(fixtures_dir / responses), "--issue-body", str(body)]
    code = dns.main(argv=[*argv, *extra])
    captured = capsys.readouterr()
    return code, captured.out, captured.err, body


# --- classify ---------------------------------------------------------------


@pytest.mark.parametrize(
    ("payload", "outcome", "detail"),
    [
        (
            {
                "Status": 0,
                "Answer": [
                    {"type": 5, "data": "edge.example."},
                    {"type": 1, "data": "192.0.2.7"},
                ],
            },
            "resolves",
            "A 192.0.2.7",
        ),
        (
            {"Status": 0, "Answer": [{"type": 5, "data": "edge.example."}]},
            "negative",
            "NOERROR without an A record",
        ),
        ({"Status": 0}, "negative", "NOERROR without an A record"),
        ({"Status": 3}, "negative", "NXDOMAIN"),
        ({"Status": 2}, "negative", "SERVFAIL"),
        ({"Status": 9}, "negative", "DNS status 9"),
        ({"Answer": []}, "error", "answer without a DNS Status"),
        ({"Status": True}, "error", "answer without a DNS Status"),
        ({"Status": 0, "Answer": "x"}, "error", MALFORMED),
        (["not", "an", "object"], "error", "answer without a DNS Status"),
        ({"Status": 3, "Answer": False}, "error", MALFORMED),
        ({"Status": 0, "Answer": [A_RECORD | {"type": True}]}, "error", MALFORMED),
        ({"Status": 0, "Answer": [A_RECORD | {"data": 7}]}, "error", MALFORMED),
        ({"Status": 0, "Answer": [{"type": 1}]}, "error", MALFORMED),
        ({"Status": 0, "Answer": [{"type": 1, "data": ""}]}, "error", MALFORMED),
        (
            {"Status": 0, "Answer": [A_RECORD, {"type": "invalid"}]},
            "error",
            MALFORMED,
        ),
        ({"Status": 0, "Answer": [A_RECORD, "x"]}, "error", MALFORMED),
        ({"Status": 0, "Answer": [{"type": 5, "TTL": "60"}]}, "error", MALFORMED),
        ({"Status": 0, "Answer": None}, "negative", "NOERROR without an A record"),
        (A_ANSWER | {"Question": False}, "error", ENVELOPE),
        (A_ANSWER | {"Question": [{"type": True}]}, "error", ENVELOPE),
        (A_ANSWER | {"Question": ["x"]}, "error", ENVELOPE),
        (A_ANSWER | {"TC": "false"}, "error", ENVELOPE),
        (A_ANSWER | {"AD": 0}, "error", ENVELOPE),
        (
            A_ANSWER | {"TC": False, "Question": [{"name": "h.", "type": 1}]},
            "resolves",
            "A 192.0.2.1",
        ),
    ],
)
def test_classify_follows_the_agent(
    dns: ModuleType,
    payload: Any,
    outcome: str,
    detail: str,
) -> None:
    """Only a type-1 answer resolves, after any CNAME chain, as in the agent."""
    attempt = dns.classify(_body(payload))

    assert_that(str(attempt.outcome)).is_equal_to(outcome)
    assert_that(attempt.detail).is_equal_to(detail)


def test_classify_rejects_a_non_json_body(dns: ModuleType) -> None:
    """An HTML error page is an error, never a negative answer."""
    attempt = dns.classify(b"<html>rate limited</html>")

    assert_that(attempt.outcome).is_equal_to(dns.Outcome.ERROR)


def test_query_url_asks_for_the_fqdn_and_type_a(dns: ModuleType) -> None:
    """The query mirrors dnsproxy.go: trailing-dot name, type A."""
    url = dns.query_url(dns.GOOGLE, "api.github.com")

    assert_that(url).is_equal_to(
        "https://dns.google/resolve?name=api.github.com.&type=A",
    )


# --- allow-list parsing -----------------------------------------------------


@pytest.mark.parametrize(
    ("token", "host", "wildcard"),
    [
        ("github.com:443", "github.com", False),
        ("Archive.Ubuntu.com:80", "archive.ubuntu.com", False),
        ("*.blob.core.windows.net:443", "*.blob.core.windows.net", True),
    ],
)
def test_parse_endpoint_accepts_host_port(
    dns: ModuleType,
    token: str,
    host: str,
    wildcard: bool,
) -> None:
    """A host:port entry splits into the lower-case host and a wildcard flag."""
    assert_that(dns.parse_endpoint(token)).is_equal_to((host, wildcard))


@pytest.mark.parametrize(
    "token",
    ["github.com", "github.com:0", "github.com:70000", "127.0.0.1:443", "a..b:443"],
)
def test_parse_endpoint_rejects_malformed_entries(dns: ModuleType, token: str) -> None:
    """No port, an out-of-range port, an IP or an empty label is refused."""
    with pytest.raises(dns.DnsCheckError):
        dns.parse_endpoint(token)


def test_build_inventory_dedupes_and_keeps_every_source(dns: ModuleType) -> None:
    """One host per name with all its sources; wildcards and placeholders apart."""
    inventory = dns.build_inventory(
        [
            ("preset a", "github.com:443"),
            ("preset b", "github.com:443"),
            ("preset b", "archive.ubuntu.com:80"),
            ("preset c", "*.example.org:443"),
            ("preset d", "example.com:443"),
        ],
        [
            ("docs/x.md:3", "github.com:443"),
            ("docs/x.md:4", "registry.example.com:443"),
            ("docs/x.md:5", "unlisted.example.net:8080"),
            ("docs/x.md:6", "prod*sa.blob.example.org:443"),
        ],
    )

    assert_that(sorted(inventory.hosts)).is_equal_to(
        ["archive.ubuntu.com", "example.com", "github.com", "unlisted.example.net"],
    )
    assert_that(inventory.hosts["github.com"].sources).is_equal_to(
        {"preset a", "preset b", "docs/x.md:3"},
    )
    assert_that(sorted(inventory.wildcards)).is_equal_to(
        ["*.example.org", "prod*sa.blob.example.org"],
    )
    assert_that(sorted(inventory.ignored)).is_equal_to(["registry.example.com"])


def test_every_ignored_placeholder_is_still_in_a_document(dns: ModuleType) -> None:
    """The ignore list holds no dead entry: each one is in docs or examples."""
    inventory = dns.build_inventory([], dns.document_endpoints())

    assert_that(sorted(inventory.ignored)).is_equal_to(sorted(dns.IGNORED_HOSTS))


def test_ignored_placeholders_carry_a_reason(dns: ModuleType) -> None:
    """The ignore list stays small and every entry says why."""
    assert_that(len(dns.IGNORED_HOSTS)).is_less_than_or_equal_to(5)
    for host, reason in dns.IGNORED_HOSTS.items():
        assert_that(reason).described_as(host).is_not_empty()


# --- host collection from the repository ------------------------------------


def test_preset_endpoints_cover_every_preset_and_function(dns: ModuleType) -> None:
    """Every preset name, the results storage list and every AI review row."""
    sources = {source for source, _ in dns.preset_endpoints()}
    presets = [source for source in sources if source.startswith("preset ")]
    names = {source.split(" ", 1)[1] for source in presets}

    assert_that(names).contains(
        "github-minimal",
        "github-results",
        "results-hosts-drift",
        "egress-dns-check",
        "runner-governor",
    )
    assert_that(sources).contains("egress_github_results_storage_endpoints")
    assert_that(sources).contains(
        "egress_ai_review_provider_endpoints anthropic/api/api_key",
        "egress_ai_review_provider_endpoints cursor/cli/api_key",
    )


def test_own_preset_lists_only_github_and_the_resolvers(dns: ModuleType) -> None:
    """The job never allow-lists a host it checks besides its own four."""
    own = [
        endpoint
        for source, endpoint in dns.preset_endpoints()
        if source == "preset egress-dns-check"
    ]

    assert_that(own).is_equal_to(
        [
            "github.com:443",
            "api.github.com:443",
            "dns.google:443",
            "cloudflare-dns.com:443",
        ],
    )


def test_preset_endpoints_fail_closed_on_a_broken_presets_file(
    dns: ModuleType,
    tmp_path: Path,
) -> None:
    """A presets file whose functions fail is an error, never an empty list."""
    broken = tmp_path / "presets.sh"
    broken.write_text("egress_preset_names() { return 3; }\n", encoding="utf-8")

    with pytest.raises(dns.DnsCheckError, match="reading the presets failed"):
        dns.preset_endpoints(presets=broken)


def test_document_endpoints_read_docs_and_examples(dns: ModuleType) -> None:
    """The real docs and examples contribute allow-list entries with path:line."""
    pairs = dns.document_endpoints()
    files = {source.rsplit(":", 1)[0] for source, _ in pairs}

    assert_that(files).contains(
        "docs/workflow-contract.md",
        "examples/publish-python-release.yml",
        "docs/onboarding.md",
    )
    assert_that([endpoint for _, endpoint in pairs]).contains(
        "registry.example.com:443",
    )


# --- resolution -------------------------------------------------------------


def test_resolve_retries_with_backoff_until_an_a_record(dns: ModuleType) -> None:
    """A blip (HTTP error, SERVFAIL) is retried; one A record resolves."""
    sleeps: list[float] = []
    fetch = _scripted(dns, {"google": [{"http_status": 503}, {"Status": 2}, A_ANSWER]})

    verdict = dns.resolve(fetch, dns.Host("h.example.org"), _policy(dns, sleeps))

    assert_that(verdict.outcome).is_equal_to(dns.Outcome.RESOLVES)
    assert_that(sleeps).is_equal_to([1.0, 2.0])
    assert_that(verdict.second_opinion).is_none()


def test_resolve_fails_only_when_every_attempt_is_negative(dns: ModuleType) -> None:
    """Three negative answers fail the host; Cloudflare is asked once."""
    fetch = _scripted(dns, {"google": [{"Status": 3}], "cloudflare": [A_ANSWER]})

    verdict = dns.resolve(fetch, dns.Host("h.example.org"), _policy(dns))

    assert_that(verdict.outcome).is_equal_to(dns.Outcome.NEGATIVE)
    assert_that(len(verdict.attempts)).is_equal_to(3)
    assert_that(verdict.second_opinion.detail).is_equal_to("A 192.0.2.1")


def test_resolve_retries_an_error_so_a_failing_host_is_not_hidden(
    dns: ModuleType,
) -> None:
    """A resolver error is not a DNS answer: the host still gets three."""
    fetch = _scripted(
        dns,
        {
            "google": [{"Status": 3}, {"http_status": 503}, {"Status": 3}],
            "cloudflare": [{"Status": 3}],
        },
    )

    verdict = dns.resolve(fetch, dns.Host("h.example.org"), _policy(dns))

    assert_that(verdict.outcome).is_equal_to(dns.Outcome.NEGATIVE)
    assert_that([str(a.outcome) for a in verdict.attempts]).is_equal_to(
        ["negative", "error", "negative", "negative"],
    )


def test_resolve_is_undetermined_once_the_error_budget_is_spent(
    dns: ModuleType,
) -> None:
    """Three resolver errors prove nothing, whatever came between them."""
    error = {"transport_error": "reset"}
    fetch = _scripted(dns, {"google": [{"Status": 3}, error, {"Status": 3}, error]})

    verdict = dns.resolve(fetch, dns.Host("h.example.org"), _policy(dns))

    assert_that(verdict.outcome).is_equal_to(dns.Outcome.ERROR)
    assert_that(len(verdict.attempts)).is_equal_to(5)
    assert_that(verdict.second_opinion).is_none()


def test_resolve_all_rechecks_a_failing_host_after_a_pause(dns: ModuleType) -> None:
    """A host that fails, then resolves on the recheck, does not fail."""
    sleeps: list[float] = []
    negative = {"Status": 3}
    fetch = _scripted(dns, {"google": [negative, negative, negative, A_ANSWER]})
    hosts = [dns.Host("h.example.org")]
    policy = _policy(
        dns,
        sleeps,
        retry_delay=0.0,
        recheck_delay=60.0,
        deadline=time.monotonic() + 600,
    )

    verdicts = dns.resolve_all(fetch, hosts, policy, workers=1)

    assert_that(verdicts[0].outcome).is_equal_to(dns.Outcome.RESOLVES)
    assert_that(len(verdicts[0].attempts)).is_equal_to(4)
    assert_that(sleeps).contains(60.0)


def test_resolve_all_fails_a_host_that_fails_the_recheck_too(dns: ModuleType) -> None:
    """Only a failure that persists across the pause is reported."""
    fetch = dns.ReplayFetch(
        {
            "google": {"bad.example.org": [{"Status": 3}]},
            "cloudflare": {"bad.example.org": [{"Status": 3}]},
            "default": A_ANSWER,
        },
    )
    hosts = [dns.Host("bad.example.org"), dns.Host("good.example.org")]

    verdicts = dns.resolve_all(fetch, hosts, _policy(dns), workers=2)

    outcomes = {v.host.name: str(v.outcome) for v in verdicts}
    assert_that(outcomes).is_equal_to(
        {"bad.example.org": "negative", "good.example.org": "resolves"},
    )
    assert_that(len(verdicts[0].attempts)).is_equal_to(6)


def test_resolve_stops_at_the_deadline(dns: ModuleType) -> None:
    """A run past its deadline fails closed instead of running on."""
    fetch = _scripted(dns, {"google": [A_ANSWER]})
    policy = _policy(dns, deadline=time.monotonic() - 1)

    with pytest.raises(dns.DnsCheckError, match="deadline"):
        dns.resolve(fetch, dns.Host("h.example.org"), policy)


def test_resolve_all_fails_closed_on_an_undetermined_host(dns: ModuleType) -> None:
    """A host the resolver never answered makes the run an error."""
    fetch = dns.ReplayFetch(
        {"default": A_ANSWER, "google": {"down.example.org": [{"http_status": 500}]}},
    )
    hosts = [dns.Host("up.example.org"), dns.Host("down.example.org")]

    with pytest.raises(dns.DnsCheckError, match="1 host"):
        dns.resolve_all(fetch, hosts, _policy(dns), workers=2)


def test_resolve_all_fails_closed_when_nothing_resolves(dns: ModuleType) -> None:
    """Every host negative means the resolver is unusable, not every host gone."""
    fetch = dns.ReplayFetch({"default": {"Status": 2}})
    hosts = [dns.Host("a.example.org"), dns.Host("b.example.org")]

    with pytest.raises(dns.DnsCheckError, match="no host resolved"):
        dns.resolve_all(fetch, hosts, _policy(dns, attempts=1), workers=2)


def test_resolve_all_sorts_verdicts(dns: ModuleType) -> None:
    """Verdicts come back in host order whatever the concurrency."""
    fetch = dns.ReplayFetch({"default": A_ANSWER})
    hosts = [dns.Host(f"h{n}.example.org") for n in (3, 1, 2)]

    verdicts = dns.resolve_all(fetch, hosts, _policy(dns), workers=3)

    assert_that([v.host.name for v in verdicts]).is_equal_to(
        ["h1.example.org", "h2.example.org", "h3.example.org"],
    )


def test_replay_repeats_the_last_reply_and_falls_back_to_default(
    dns: ModuleType,
) -> None:
    """Successive queries take successive replies; unknown hosts get default."""
    replies = [{"Status": 2}, {"Status": 3}]
    fetch = dns.ReplayFetch({"default": A_ANSWER, "google": {"h.example.org": replies}})
    url = dns.query_url(dns.GOOGLE, "h.example.org")

    statuses = [json.loads(fetch(url))["Status"] for _ in range(3)]
    other = json.loads(fetch(dns.query_url(dns.CLOUDFLARE, "h.example.org")))

    assert_that(statuses).is_equal_to([2, 3, 3])
    assert_that(other).is_equal_to(A_ANSWER)


# --- the real fetch function, without network --------------------------------


class _Response(io.BytesIO):
    """A minimal opener response."""

    def __init__(self, body: bytes, status: int = 200) -> None:
        super().__init__(body)
        self.status = status


def test_urllib_fetch_sends_the_agent_headers(
    dns: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The request asks for application/dns-json and returns the body."""
    seen: list[Any] = []

    def fake_open(request: Any, timeout: float) -> _Response:
        seen.append((request, timeout))
        return _Response(_body(A_ANSWER))

    monkeypatch.setattr(dns.OPENER, "open", fake_open)

    body = dns.urllib_fetch(dns.query_url(dns.GOOGLE, "github.com"))

    assert_that(json.loads(body)).is_equal_to(A_ANSWER)
    request, timeout = seen[0]
    assert_that(request.get_header("Accept")).is_equal_to("application/dns-json")
    assert_that(timeout).is_equal_to(10.0)


@pytest.mark.parametrize(
    "error",
    [
        urllib.error.HTTPError("u", 429, "Too Many Requests", Message(), None),
        urllib.error.URLError("no route"),
        TimeoutError("timed out"),
        http.client.IncompleteRead(b"{"),
        http.client.BadStatusLine("garbage"),
        http.client.RemoteDisconnected("closed"),
    ],
)
def test_urllib_fetch_turns_failures_into_resolver_errors(
    dns: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    error: Exception,
) -> None:
    """HTTP and transport failures are resolver errors, never DNS answers."""

    def fake_open(request: Any, timeout: float) -> _Response:
        raise error

    monkeypatch.setattr(dns.OPENER, "open", fake_open)

    with pytest.raises(dns.ResolverError):
        dns.urllib_fetch(dns.query_url(dns.CLOUDFLARE, "github.com"))


def test_preset_endpoints_ignore_an_inherited_shell_environment(
    dns: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """BASH_ENV and a tracer's settings never reach the preset shell."""
    planted = tmp_path / "bash_env.sh"
    planted.write_text("echo planted >&2; exit 9\n", encoding="utf-8")
    monkeypatch.setenv("BASH_ENV", str(planted))
    monkeypatch.setenv("BASH_XTRACEFD", "16384")
    monkeypatch.setenv("PS4", "trace@${BASH_SOURCE}@")
    monkeypatch.setenv("SHELLOPTS", "xtrace")

    pairs = dns.preset_endpoints()

    assert_that(pairs).is_not_empty()


def test_preset_endpoints_fail_closed_when_a_later_preset_fails(
    dns: ModuleType,
    tmp_path: Path,
) -> None:
    """A preset that fails after another printed hosts is never dropped."""
    broken = tmp_path / "presets.sh"
    broken.write_text(
        "egress_preset_names() { printf '%s\\n' good broken; }\n"
        "egress_preset_endpoints() {\n"
        '  case "$1" in\n'
        "    good) echo good.example.org:443 ;;\n"
        "    *) return 23 ;;\n"
        "  esac\n"
        "}\n",
        encoding="utf-8",
    )

    with pytest.raises(dns.DnsCheckError, match=r"reading the presets failed \(23\)"):
        dns.preset_endpoints(presets=broken)


@pytest.mark.parametrize(
    "token",
    ["*.internal:443", "*.example.org:443", "prod*sa.example.org:443", "*:443"],
)
def test_parse_endpoint_keeps_any_wildcard_as_written(
    dns: ModuleType,
    token: str,
) -> None:
    """A wildcard is never judged as a DNS name: the agent does not resolve it."""
    host, wildcard = dns.parse_endpoint(token)

    assert_that(host).is_equal_to(token.rpartition(":")[0])
    assert_that(wildcard).is_true()


def test_resolve_refuses_a_backoff_that_would_pass_the_deadline(
    dns: ModuleType,
) -> None:
    """The deadline bounds the pauses too, not only the queries."""
    sleeps: list[float] = []
    fetch = _scripted(dns, {"google": [{"Status": 3}]})
    policy = _policy(dns, sleeps, retry_delay=30.0, deadline=time.monotonic() + 5)

    with pytest.raises(dns.DnsCheckError, match="would pass during the backoff"):
        dns.resolve(fetch, dns.Host("h.example.org"), policy)
    assert_that(sleeps).is_empty()


def test_resolve_discards_an_answer_that_arrives_after_the_deadline(
    dns: ModuleType,
) -> None:
    """A slow answer past the deadline is not a verdict."""
    policy = _policy(dns, deadline=time.monotonic() + 0.05)

    def slow(_url: str) -> bytes:
        time.sleep(0.1)
        return _body(A_ANSWER)

    with pytest.raises(dns.DnsCheckError, match="deadline passed"):
        dns.resolve(slow, dns.Host("h.example.org"), policy)


def test_resolve_all_refuses_a_recheck_pause_past_the_deadline(
    dns: ModuleType,
) -> None:
    """No time left for the recheck is an error, never a reported failure."""
    sleeps: list[float] = []
    fetch = dns.ReplayFetch(
        {"google": {"bad.example.org": [{"Status": 3}]}, "default": A_ANSWER},
    )
    hosts = [dns.Host("bad.example.org"), dns.Host("good.example.org")]
    policy = _policy(
        dns,
        sleeps,
        retry_delay=0.0,
        recheck_delay=60.0,
        deadline=time.monotonic() + 30,
    )

    with pytest.raises(dns.DnsCheckError, match="the pause before the recheck"):
        dns.resolve_all(fetch, hosts, policy, workers=2)
    assert_that(sleeps).does_not_contain(60.0)


def test_resolve_discards_a_second_opinion_that_arrives_after_the_deadline(
    dns: ModuleType,
) -> None:
    """A late Cloudflare answer cannot turn the run into a reported failure."""
    deadline = time.monotonic() + 0.2

    def fetch(url: str) -> bytes:
        if url.startswith(dns.CLOUDFLARE):
            time.sleep(0.3)
        return _body({"Status": 3})

    policy = _policy(dns, retry_delay=0.0, deadline=deadline)

    with pytest.raises(dns.DnsCheckError, match="deadline passed"):
        dns.resolve(fetch, dns.Host("h.example.org"), policy)


def test_watchdog_ends_the_process_with_the_error_status(
    dns: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A run that outlives its deadline exits 2, whatever its threads do."""
    codes: list[int] = []
    monkeypatch.setattr(dns.os, "_exit", codes.append)

    dns._watchdog_expired()  # pylint: disable=protected-access

    assert_that(codes).is_equal_to([dns.EXIT_ERROR])
    assert_that(capsys.readouterr().err).contains("outlived its deadline")


def test_watchdog_is_armed_past_the_deadline_and_cancelled_after_the_run(
    dns: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    fixtures_dir: Path,
) -> None:
    """The timer fires a grace period after the deadline, as a daemon."""
    timers: list[Any] = []
    real = dns._arm_watchdog  # pylint: disable=protected-access

    def arm(seconds: float) -> Any:
        timers.append(real(seconds))
        return timers[-1]

    monkeypatch.setattr(dns, "_arm_watchdog", arm)

    code = dns.main(["--responses", str(fixtures_dir / RESPONSES), "--deadline", "100"])

    assert_that(code).is_equal_to(dns.EXIT_CLEAN)
    assert_that(timers[0].interval).is_equal_to(100 + dns.WATCHDOG_GRACE)
    assert_that(timers[0].daemon).is_true()
    assert_that(timers[0].finished.is_set()).is_true()


def test_bounded_fetch_cuts_the_request_timeout_to_the_deadline(
    dns: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A request never waits past the deadline (one second at least)."""
    seen: list[float] = []

    def record(_url: str, timeout: float) -> bytes:
        seen.append(timeout)
        return b"{}"

    monkeypatch.setattr(dns, "urllib_fetch", record)

    dns._bounded_fetch(time.monotonic() + 600)("u")  # pylint: disable=protected-access
    dns._bounded_fetch(time.monotonic() + 4)("u")  # pylint: disable=protected-access
    dns._bounded_fetch(time.monotonic() - 9)("u")  # pylint: disable=protected-access

    assert_that(seen[0]).is_equal_to(10.0)
    assert_that(seen[1]).is_between(3.0, 4.0)
    assert_that(seen[2]).is_equal_to(1.0)


def test_urllib_fetch_does_not_follow_redirects(dns: ModuleType) -> None:
    """A 3xx from a resolver is an error, never a fetch from another host."""
    names = {type(handler).__name__ for handler in dns.OPENER.handlers}

    assert_that(names).does_not_contain("HTTPRedirectHandler")


def test_urllib_fetch_refuses_any_other_url(dns: ModuleType) -> None:
    """Only the two resolver endpoints are ever fetched."""
    with pytest.raises(dns.ResolverError, match="refusing"):
        dns.urllib_fetch("https://attacker.example.org/resolve?name=x.&type=A")


def test_opener_speaks_https_only(dns: ModuleType) -> None:
    """No plain http, file or ftp handler, so no redirect can downgrade."""
    schemes = {
        scheme
        for handler in dns.OPENER.handlers
        for scheme in ("http", "https", "file", "ftp", "data")
        if hasattr(handler, f"{scheme}_open")
    }

    assert_that(schemes).is_equal_to({"https"})


# --- the command line -------------------------------------------------------


def test_cli_clean_run_exits_0_without_issue_body(
    dns: ModuleType,
    fixtures_dir: Path,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Every repository host resolves: exit 0, a report, no issue body."""
    code, out, err, body = _run(dns, fixtures_dir, tmp_path, capsys)

    assert_that(code).is_equal_to(0)
    assert_that(out).matches(r"Checked \d+ hosts: \d+ resolve, 0 fail")
    assert_that(out).contains("IGNORE registry.example.com")
    assert_that(err).contains("every allow-listed host resolves")
    assert_that(body.exists()).is_false()


def test_cli_unresolvable_host_fails_and_reports(
    dns: ModuleType,
    fixtures_dir: Path,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A deliberately unresolvable host exits 1 with a report and issue body."""
    code, out, _, body = _run(
        dns,
        fixtures_dir,
        tmp_path,
        capsys,
        "--extra-hosts",
        f"{PROOF_HOST}:443 flaky.example.org:443",
    )

    assert_that(code).is_equal_to(1)
    assert_that(out).contains(
        f"FAIL {PROOF_HOST}: Google NXDOMAIN (6 attempts); Cloudflare second",
    )
    assert_that(out).contains("second opinion: NXDOMAIN")
    assert_that(out).does_not_contain("FAIL flaky.example.org")
    text = body.read_text("utf-8")
    assert_that(text).starts_with(dns.ISSUE_MARKER)
    assert_that(text).contains(
        f"- `{PROOF_HOST}`: NXDOMAIN; in `workflow_dispatch input extra-hosts`",
    )
    assert_that(text).does_not_contain("192.0.2")


def test_cli_issue_body_is_deterministic(
    dns: ModuleType,
    fixtures_dir: Path,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Two runs with the same failure write the same body."""
    _, _, _, first = _run(
        dns,
        fixtures_dir,
        tmp_path,
        capsys,
        "--extra-hosts",
        f"{PROOF_HOST}:443",
    )
    first_text = first.read_text("utf-8")
    _, _, _, second = _run(
        dns,
        fixtures_dir,
        tmp_path,
        capsys,
        "--extra-hosts",
        f"{PROOF_HOST}:443",
    )

    assert_that(second.read_text("utf-8")).is_equal_to(first_text)


def test_cli_unreachable_resolver_exits_2(
    dns: ModuleType,
    fixtures_dir: Path,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """HTTP errors for the whole run fail closed: exit 2, no issue body."""
    code, out, err, body = _run(
        dns,
        fixtures_dir,
        tmp_path,
        capsys,
        "--attempts",
        "1",
        responses=UNREACHABLE,
    )

    assert_that(code).is_equal_to(2)
    assert_that(out).is_empty()
    assert_that(err).contains("got no DNS answer")
    assert_that(body.exists()).is_false()


@pytest.mark.parametrize(
    "extra",
    ["*.example.org:443", "example.org", "$(id):443", "example.org:99999"],
)
def test_cli_rejects_malformed_extra_hosts(
    dns: ModuleType,
    fixtures_dir: Path,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    extra: str,
) -> None:
    """Extra hosts must be plain host:port entries; anything else is exit 2."""
    code, _, err, _ = _run(
        dns,
        fixtures_dir,
        tmp_path,
        capsys,
        "--extra-hosts",
        extra,
    )

    assert_that(code).is_equal_to(2)
    assert_that(err).contains("[ERROR]")


def test_cli_unexpected_exception_exits_2(
    dns: ModuleType,
    fixtures_dir: Path,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A crash is never exit 1, which would rewrite the tracking issue."""

    def explode() -> list[tuple[str, str]]:
        raise RuntimeError("boom")

    monkeypatch.setattr(dns, "preset_endpoints", explode)

    code, _, err, _ = _run(dns, fixtures_dir, tmp_path, capsys)

    assert_that(code).is_equal_to(2)
    assert_that(err).contains("boom")


def test_cli_usage_error_exits_2(dns: ModuleType) -> None:
    """An unknown option is a usage error (2), never a failure (1)."""
    assert_that(dns.main(argv=["--no-such-option"])).is_equal_to(2)
