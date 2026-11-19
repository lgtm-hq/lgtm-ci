# SPDX-License-Identifier: MIT
# pylint: disable=too-many-lines  # One case per rewrite rule; a split would
# clone the fixtures, which the duplicate-code ratchet forbids.
"""Tests for ``scripts/ci/lib/apt_mirrors.py`` and ``apt_sources.py`` rewrites (#1661).

The runner's ``ubuntu.sources`` reads the archive through
``mirror+file:/etc/apt/apt-mirrors.txt``, which named an EC2 mirror no egress
preset allows (fixture run 44503491578). These tests prove the helper's
private copies name only allowed archive hosts and change nothing else.
"""

from __future__ import annotations

import json
import os
import random
import stat
import subprocess
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
from assertpy import assert_that

MIRRORS_PATH = "scripts/ci/lib/apt_mirrors.py"
EC2 = "http://us-east-2.ec2.archive.ubuntu.com/ubuntu"
ARCHIVE = "https://archive.ubuntu.com/ubuntu"
SECURITY = "https://security.ubuntu.com/ubuntu"
KEYRING = "/usr/share/keyrings/ubuntu-archive-keyring.gpg"
# The shape of ubuntu.sources on GitHub's ubuntu-24.04 image: one mirror
# list stanza for every suite, security included.
NOBLE_SOURCES = f"""\
# Ubuntu sources have moved to /etc/apt/sources.list.d/ubuntu.sources
Types: deb
URIs: mirror+file:/etc/apt/apt-mirrors.txt
Suites: noble noble-updates noble-backports noble-security
Components: main universe restricted multiverse
Signed-By: {KEYRING}
"""
AGENT = {"egress_policy": "block", "allowed_endpoints": ""}
DEB = "Types: deb\nURIs: "
# A port in Arabic-Indic digits: str.isdigit() is true, int() would accept it.
ARABIC_PORT = "archive.ubuntu.com:\u0668\u0660"


@pytest.fixture(name="mirrors")
def fixture_mirrors(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load ``apt_mirrors`` without running anything."""
    return load_script(MIRRORS_PATH)


@pytest.fixture(name="sources")
def fixture_sources(mirrors: ModuleType) -> ModuleType:
    """Return ``apt_sources``, the module the loaded policy rewrites through."""
    module: ModuleType = mirrors.apt_sources
    return module


@pytest.fixture(name="policy")
def fixture_policy(mirrors: ModuleType) -> Any:
    """Return a policy whose job allow list holds every target host."""
    return mirrors.MirrorPolicy(mirrors.TARGET_HOSTS, "test")


def _rewrite(sources: ModuleType, policy: Any, name: str, text: str) -> str:
    """Rewrite one sources file's text as ``filter_sources`` would."""
    rewrite = policy.rewrite_for(name)
    return str(sources.rewrite_text(text, name.endswith(".sources"), rewrite))


def _agent(tmp_path: Path, **fields: object) -> Path:
    """Write a harden-runner ``agent.json`` and return its path."""
    path = tmp_path / "agent.json"
    path.write_text(json.dumps({**AGENT, **fields}), encoding="utf-8")
    return path


# --- rewrites ----------------------------------------------------------------


def test_mirror_file_source_is_split_into_archive_and_security(
    sources: ModuleType,
    policy: Any,
) -> None:
    """A deb822 ``mirror+file:`` stanza names the allowed archive and security hosts."""
    new = _rewrite(sources, policy, "ubuntu.sources", NOBLE_SOURCES)

    paragraphs = sources.deb822_paragraphs(new)
    assert_that(paragraphs).is_length(2)
    archive, security = paragraphs
    assert_that(archive).contains_entry(
        {"uris": ARCHIVE},
        {"suites": "noble noble-updates noble-backports"},
    )
    assert_that(security).contains_entry(
        {"uris": SECURITY},
        {"suites": "noble-security"},
    )
    for paragraph in paragraphs:
        assert_that(paragraph).contains_entry(
            {"types": "deb"},
            {"components": "main universe restricted multiverse"},
            {"signed-by": KEYRING},
        )
    assert_that(new).starts_with("# Ubuntu sources have moved")


def test_inline_signed_by_key_is_kept_byte_for_byte(
    sources: ModuleType,
    policy: Any,
) -> None:
    """A multi-line ``Signed-By`` key block survives the rewrite unchanged."""
    key = "Signed-By:\n -----BEGIN PGP PUBLIC KEY BLOCK-----\n .\n mQINBFufwdoBEADv\n"
    text = f"Types: deb\nURIs: {EC2}\nSuites: noble\nComponents: main\n{key}"

    new = _rewrite(sources, policy, "ubuntu.sources", text)

    assert_that(new).is_equal_to(
        f"Types: deb\nURIs: {ARCHIVE}\nSuites: noble\nComponents: main\n{key}"
    )


def test_one_line_list_on_an_ec2_host_is_rewritten(
    sources: ModuleType,
    policy: Any,
) -> None:
    """A ``.list`` entry on an EC2 mirror keeps its options, suite and components."""
    text = (
        f"deb [arch=amd64 signed-by={KEYRING}] {EC2} noble main universe\n"
        f"# deb {EC2} noble-proposed main\n"
        f"deb-src {EC2}/ noble-security main\n"
    )

    new = _rewrite(sources, policy, "regional.list", text)

    assert_that(new).is_equal_to(
        f"deb [arch=amd64 signed-by={KEYRING}] {ARCHIVE} noble main universe\n"
        f"# deb {EC2} noble-proposed main\n"
        f"deb-src {SECURITY} noble-security main\n",
    )


@pytest.mark.parametrize(
    "uri",
    [
        "http://azure.archive.ubuntu.com/ubuntu",
        "http://archive.ubuntu.com/ubuntu",
        "https://archive.ubuntu.com/ubuntu",
        "http://security.ubuntu.com/ubuntu",
    ],
)
def test_already_allowed_host_is_left_unchanged(
    sources: ModuleType,
    policy: Any,
    uri: str,
) -> None:
    """A host and port the allowed set holds stays, security suites included."""
    text = f"Types: deb\nURIs: {uri}\nSuites: noble noble-security\nComponents: main\n"

    assert_that(_rewrite(sources, policy, "ubuntu.sources", text)).is_equal_to(text)
    assert_that(policy.changes).is_empty()


def test_disallowed_port_on_an_allowed_host_is_rewritten(policy: Any) -> None:
    """``azure.archive.ubuntu.com`` is allowed on :80 only, so HTTPS to it moves."""
    uri = "https://azure.archive.ubuntu.com/ubuntu"

    assert_that(policy.target(uri, "noble", False)).is_equal_to(ARCHIVE)


def test_security_suite_uses_the_security_host(policy: Any) -> None:
    """``*-security`` goes to ``security.ubuntu.com``; other suites to the archive."""
    target = policy.target

    assert_that(target(EC2, "noble-security", False)).is_equal_to(SECURITY)
    assert_that(target(EC2, "noble-updates", False)).is_equal_to(ARCHIVE)


def test_security_suite_falls_back_to_the_archive_host(mirrors: ModuleType) -> None:
    """Without ``security.ubuntu.com`` allowed, the archive serves security."""
    policy = mirrors.MirrorPolicy(frozenset({("archive.ubuntu.com", 80)}), "test")

    target = policy.target(EC2, "noble-security", True)

    assert_that(target).is_equal_to("http://archive.ubuntu.com/ubuntu")


@pytest.mark.parametrize(
    ("name", "text"),
    [
        ("corporate.list", "deb https://artifactory.corp.example/ubuntu noble main\n"),
        ("ports.list", "deb http://ports.ubuntu.com/ubuntu-ports noble main\n"),
        ("debian.sources", f"{DEB}http://deb.debian.org/debian\nSuites: trixie\n"),
        ("debian.sources", f"{DEB}mirror+file:/etc/apt/m.txt\nSuites: trixie\n"),
        ("local.list", "deb [trusted=yes] file:/srv/repo ./\n"),
        ("corporate.sources", f"{DEB}mirror+file:/etc/apt/corp.txt\nSuites: x\n"),
        ("ubuntu.sources", f"Types: deb\nURIs: {EC2}\nSuites: noble\nEnabled: no\n"),
    ],
)
def test_other_hosts_and_disabled_entries_are_left_alone(
    sources: ModuleType,
    policy: Any,
    name: str,
    text: str,
) -> None:
    """Other hosts, Debian, ports, other mirror lists and disabled stanzas stay."""
    assert_that(_rewrite(sources, policy, name, text)).is_equal_to(text)


def test_filter_sources_rewrites_copies_and_still_excludes_third_party(
    sources: ModuleType,
    policy: Any,
    tmp_path: Path,
) -> None:
    """Third-party files stay out; untouched copies are byte for byte; /etc stays."""
    real = tmp_path / "sources.list.d"
    real.mkdir()
    (real / "ubuntu.sources").write_text(NOBLE_SOURCES, encoding="utf-8")
    (real / "microsoft-prod.list").write_text(
        "deb https://packages.microsoft.com/ubuntu/24.04/prod noble main\n",
        encoding="utf-8",
    )
    corporate = b"deb https://mirror.corp.example/ubuntu noble main\r\n\xff\n"
    (real / "corporate.list").write_bytes(corporate)
    dest = tmp_path / "parts"
    dest.mkdir()

    skipped = sources.filter_sources(real, dest, False, policy.rewrite_for)

    assert_that(skipped).is_equal_to(["microsoft-prod.list"])
    assert_that(sorted(p.name for p in dest.iterdir())).is_equal_to(
        ["corporate.list", "ubuntu.sources"],
    )
    assert_that((dest / "corporate.list").read_bytes()).is_equal_to(corporate)
    copy = (dest / "ubuntu.sources").read_text("utf-8")
    assert_that(copy).contains(f"URIs: {ARCHIVE}")
    assert_that((real / "ubuntu.sources").read_text("utf-8")).is_equal_to(NOBLE_SOURCES)


def test_summary_names_the_overridden_list_and_the_hosts(
    sources: ModuleType,
    policy: Any,
) -> None:
    """The log line names the mirror list replaced and every host apt uses."""
    _rewrite(sources, policy, "ubuntu.sources", NOBLE_SOURCES)

    summary = policy.summary()

    assert_that(summary).contains(
        "mirror+file:/etc/apt/apt-mirrors.txt",
        f"apt uses {ARCHIVE}, {SECURITY}",
        "(allowed archive hosts from test)",
    )


def test_uris_continuation_after_a_comment_is_rewritten(
    sources: ModuleType,
    policy: Any,
) -> None:
    """apt drops comments first, so a ``URIs`` continuation after one is the field."""
    other = "http://eu-west-1.ec2.archive.ubuntu.com/ubuntu"
    text = (
        "Types: deb\n"
        f"URIs: {EC2}\n"
        "# a second regional mirror\n"
        f" {other}\n"
        "Suites: noble\n"
        "Components: main\n"
        f"Signed-By: {KEYRING}\n"
    )

    new = _rewrite(sources, policy, "ubuntu.sources", text)

    assert_that(sources.deb822_paragraphs(new)).is_equal_to(
        [
            {
                "types": "deb",
                "uris": ARCHIVE,
                "suites": "noble",
                "components": "main",
                "signed-by": KEYRING,
            },
        ],
    )
    assert_that(new).does_not_contain(other).contains("# a second regional mirror\n")


def test_suites_continuation_after_a_comment_is_split(
    sources: ModuleType,
    policy: Any,
) -> None:
    """A commented ``Suites`` continuation goes to exactly one stanza of a split."""
    text = (
        "Types: deb\n"
        "URIs: mirror+file:/etc/apt/apt-mirrors.txt\n"
        "Suites: noble noble-updates\n"
        "# security comes from the same list\n"
        " noble-security\n"
        "Components: main\n"
        f"Signed-By: {KEYRING}\n"
    )

    new = _rewrite(sources, policy, "ubuntu.sources", text)

    paragraphs = sources.deb822_paragraphs(new)
    assert_that([(p["uris"], p["suites"]) for p in paragraphs]).is_equal_to(
        [(ARCHIVE, "noble noble-updates"), (SECURITY, "noble-security")],
    )
    for paragraph in paragraphs:
        assert_that(paragraph).contains_entry({"signed-by": KEYRING})


def test_rewritten_lines_keep_crlf_endings(sources: ModuleType, policy: Any) -> None:
    """Lines the rewrite writes reuse the file's ``\\r\\n`` endings."""
    text = NOBLE_SOURCES.replace("\n", "\r\n")

    new = _rewrite(sources, policy, "ubuntu.sources", text)

    assert_that(new.replace("\r\n", "")).does_not_contain("\n")
    split = f"Signed-By: {KEYRING}\r\n\r\n# Ubuntu"
    assert_that(new).contains(f"URIs: {ARCHIVE}\r\n", split)
    listed = _rewrite(sources, policy, "a.list", f"deb {EC2} noble main\r\n")
    assert_that(listed).is_equal_to(f"deb {ARCHIVE} noble main\r\n")


def test_enabled_stanza_without_uris_is_kept(sources: ModuleType, policy: Any) -> None:
    """An enabled stanza with no ``URIs`` field is returned as it is, not dropped."""
    text = "Types: deb\nSuites: noble\nComponents: main\n\n" + NOBLE_SOURCES

    new = _rewrite(sources, policy, "ubuntu.sources", text)

    assert_that(new).starts_with("Types: deb\nSuites: noble\nComponents: main\n\n")
    assert_that(sources.deb822_paragraphs(new)).is_length(3)


# --- the allowed set ---------------------------------------------------------


def test_allowed_set_comes_from_the_agent_config(
    mirrors: ModuleType,
    tmp_path: Path,
) -> None:
    """Block mode with exact endpoints: only its archive hosts are targets."""
    config = _agent(
        tmp_path,
        allowed_endpoints="github.com:443 archive.ubuntu.com:80 security.ubuntu.com:80 "
        "*.archive.ubuntu.com:443 azure.archive.ubuntu.com",
    )

    policy, note = mirrors.load_policy(config, machine="x86_64")

    assert_that(note).is_empty()
    assert_that(policy.allowed).is_equal_to(
        frozenset({("archive.ubuntu.com", 80), ("security.ubuntu.com", 80)}),
    )
    assert_that(policy.target(EC2, "noble", True)).is_equal_to(
        "http://archive.ubuntu.com/ubuntu",
    )
    assert_that(policy.target(EC2, "noble-security", True)).is_equal_to(
        "http://security.ubuntu.com/ubuntu",
    )


@pytest.mark.parametrize(
    ("content", "reason"),
    [
        (None, "cannot read"),
        ("{not json", "is not valid UTF-8 JSON"),
        ('{"egress_policy": "block", "x": "\udcff"}', "is not valid UTF-8 JSON"),
        ("[" * 200_000, "nests too deeply"),
        ("[]", "is not a JSON object"),
        (json.dumps({"egress_policy": "audit"}), "does not carry egress_policy block"),
        (json.dumps({"allowed_endpoints": "archive.ubuntu.com:80"}), "egress_policy"),
        (json.dumps(AGENT), "lists no exact host:port endpoint"),
        (json.dumps({**AGENT, "allowed_endpoints": "*.ubuntu.com:80"}), "no exact"),
        (json.dumps({**AGENT, "allowed_endpoints": f"{ARABIC_PORT}"}), "no exact"),
    ],
)
def test_unproven_egress_rewrites_nothing(
    mirrors: ModuleType,
    tmp_path: Path,
    content: str | None,
    reason: str,
) -> None:
    """Without an agent config that proves block mode, nothing is rewritten."""
    config = tmp_path / "agent.json"
    if content is not None:
        config.write_bytes(content.encode("utf-8", errors="surrogateescape"))

    policy, note = mirrors.load_policy(config, machine="x86_64")

    assert_that(policy).is_none()
    assert_that(note).contains("egress enforcement not proven", reason)


def test_symlinked_agent_config_is_refused(mirrors: ModuleType, tmp_path: Path) -> None:
    """A symbolic link is never followed, even to a valid block-mode config."""
    real = _agent(tmp_path, allowed_endpoints="archive.ubuntu.com:443")
    link = tmp_path / "link.json"
    link.symlink_to(real)

    policy, note = mirrors.load_policy(link, machine="x86_64")

    assert_that(policy).is_none()
    assert_that(note).contains("is a symbolic link")


def test_fifo_agent_config_neither_blocks_nor_is_read(
    mirrors: ModuleType,
    tmp_path: Path,
) -> None:
    """A FIFO with no writer is refused at once instead of blocking the open."""
    fifo = tmp_path / "agent.json"
    os.mkfifo(fifo)

    policy, note = mirrors.load_policy(fifo, machine="x86_64")

    assert_that(policy).is_none()
    assert_that(note).contains("is not a regular file")


def test_oversized_agent_config_is_refused(mirrors: ModuleType, tmp_path: Path) -> None:
    """A config over ``MAX_CONFIG_BYTES`` is not parsed."""
    padding = " " * mirrors.MAX_CONFIG_BYTES
    config = tmp_path / "agent.json"
    config.write_text(
        json.dumps({**AGENT, "allowed_endpoints": "archive.ubuntu.com:443"}) + padding,
        encoding="utf-8",
    )

    policy, note = mirrors.load_policy(config, machine="x86_64")

    assert_that(policy).is_none()
    assert_that(note).contains(f"larger than {mirrors.MAX_CONFIG_BYTES} bytes")


def test_interrupt_while_parsing_agent_config_is_not_swallowed(
    mirrors: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """An exception that is not a parse error (the helper's Interrupted) propagates."""

    class Stop(Exception):
        """Stands in for the helper's signal-raised Interrupted."""

    def interrupted(*_args: object, **_kwargs: object) -> object:
        raise Stop

    config = _agent(tmp_path, allowed_endpoints="archive.ubuntu.com:443")
    monkeypatch.setattr(mirrors.json, "loads", interrupted)

    with pytest.raises(Stop):
        mirrors.load_policy(config, machine="x86_64")


def test_parse_endpoints_ignores_non_ascii_digit_ports(mirrors: ModuleType) -> None:
    """``str.isdigit`` accepts "²" and Arabic-Indic digits; they never reach ``int``."""
    pairs = mirrors.parse_endpoints("a.example:\u00b2 b.example:\u0668 c.example:443")

    assert_that(pairs).is_equal_to(frozenset({("c.example", 443)}))


@pytest.mark.parametrize(
    "endpoints",
    [
        "github.com:443 deb.debian.org:80",
        "github.com:443 us-east-2.ec2.archive.ubuntu.com:80",
    ],
)
def test_allow_list_without_a_target_host_rewrites_nothing(
    mirrors: ModuleType,
    tmp_path: Path,
    endpoints: str,
) -> None:
    """A list that allows no target archive host leaves the sources alone."""
    config = _agent(tmp_path, allowed_endpoints=endpoints)

    policy, note = mirrors.load_policy(config, machine="x86_64")

    assert_that(policy).is_none()
    assert_that(note).contains("allows no target archive host")


def test_non_x86_runner_rewrites_nothing(mirrors: ModuleType, tmp_path: Path) -> None:
    """An arm64 runner's archive is ``ports.ubuntu.com``; nothing is rewritten."""
    policy, note = mirrors.load_policy(_agent(tmp_path), machine="aarch64")

    assert_that(policy).is_none()
    assert_that(note).contains("aarch64 runner")


def test_target_hosts_are_the_rewrite_targets(mirrors: ModuleType) -> None:
    """``TARGET_HOSTS`` is exactly the set of hosts and ports a rewrite can name."""
    targets = {
        (host, mirrors.PORTS[scheme])
        for scheme, host in mirrors.ARCHIVE_TARGETS + mirrors.SECURITY_TARGETS
    }

    assert_that(targets).is_equal_to(set(mirrors.TARGET_HOSTS))


def test_target_hosts_are_in_every_apt_preset(
    mirrors: ModuleType,
    fixtures_dir: Path,
) -> None:
    """Every egress preset that carries an Ubuntu host carries every target host."""
    presets = fixtures_dir.parent.parent / "scripts/ci/lib/egress/presets.sh"
    script = (
        f'source "{presets}"; for name in $(egress_preset_names); do '
        'hosts=$(egress_preset_endpoints "$name" | tr "\\n" " "); '
        'printf "%s %s\\n" "$name" "$hosts"; done'
    )
    out = subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        check=True,
        timeout=60,
    ).stdout
    apt_presets = {}
    for line in out.splitlines():
        name, _, endpoints = line.partition(" ")
        if "ubuntu.com" in endpoints:
            apt_presets[name] = mirrors.parse_endpoints(endpoints)

    assert_that(apt_presets).contains_key("playwright", "shell-test", "rust-release")
    for name, endpoints in apt_presets.items():
        archive = {pair for pair in endpoints if mirrors.is_archive_host(pair[0])}
        expected = set(mirrors.TARGET_HOSTS)
        assert_that(archive, description=name).is_equal_to(expected)


# --- stable mirror lists (#1664) ----------------------------------------------

AZURE = "http://azure.archive.ubuntu.com/ubuntu"
ARCHIVE_HTTP = "http://archive.ubuntu.com/ubuntu"
SECURITY_HTTP = "http://security.ubuntu.com/ubuntu"
# apt's default priority for a mirror without a ``priority`` tag (ULONG_MAX).
NO_PRIORITY = 2**64 - 1
ARCHIVE_ENTRIES = [ARCHIVE, AZURE, ARCHIVE_HTTP]
# The security ports, then only the first allowed archive host.
SECURITY_ENTRIES = [SECURITY, SECURITY_HTTP, ARCHIVE]


@pytest.fixture(name="failover")
def fixture_failover(mirrors: ModuleType) -> ModuleType:
    """Return ``apt_failover``, the module the loaded policy writes lists with."""
    module: ModuleType = mirrors.apt_failover
    return module


def _root(tmp_path: Path) -> Path:
    """Create the helper's temporary root, as ``/tmp`` is on a runner."""
    root = tmp_path / "tmp"
    root.mkdir(parents=True)
    return root


def _listed_policy(
    mirrors: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    root: Path,
    allowed: frozenset[tuple[str, int]] | None = None,
) -> Any:
    """Return a policy using the stable lists under ``root``, whatever its parents."""
    monkeypatch.setattr(mirrors.apt_failover, "sandbox_blocker", lambda _path: None)
    hosts = mirrors.TARGET_HOSTS if allowed is None else allowed
    return mirrors.MirrorPolicy(hosts, "test").with_lists(root)


def _entries(path: Path) -> list[str]:
    """Return a list's non-comment lines."""
    return [line for line in path.read_text("utf-8").splitlines() if line[:1] != "#"]


def _read_mirror_list(text: str, rng: random.Random) -> list[str]:
    """Order a mirror list as apt's mirror method does (``methods/mirror.cc``).

    ``MirrorListFileReceived``: skip empty and ``#`` lines; the URI ends at the
    first tab, the rest are space-separated ``key:value`` tags.
    ``RedirectItem``: sort by ``priority`` (default ULONG_MAX), ties by a
    random seed; the first is the request URI, the rest its alternates.
    """
    entries = []
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        uri, _, tagline = line.partition("\t")
        priority = NO_PRIORITY
        for tag in tagline.replace("\t", " ").split():
            name, colon, value = tag.partition(":")
            if colon and name == "priority":
                priority = int(value)
        entries.append((priority, rng.random(), uri))
    return [uri for _, _, uri in sorted(entries)]


def _fetch(order: list[str], path: str, dead: set[str]) -> tuple[str, list[str]]:
    """Fetch ``path`` as apt's worker does: on failure, pop the next alternate.

    ``pkgAcquire::Worker::HandleFailure`` moves to the next alternate URI
    once a mirror fails (after its retries for a transient error).
    """
    tried = []
    for base in order:
        tried.append(base)
        if base not in dead:
            return f"{base}/{path}", tried
    return "", tried


def test_lists_hold_every_allowed_host_in_preference_order(
    mirrors: ModuleType,
    sources: ModuleType,
    failover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """Archive and security suites name their own stable list of allowed hosts."""
    root = _root(tmp_path)
    policy = _listed_policy(mirrors, monkeypatch, root)
    new = _rewrite(sources, policy, "ubuntu.sources", NOBLE_SOURCES)

    stable = failover.lists_dir(root)
    assert_that(stable).is_equal_to(root / f"lgtm-ci-apt-mirrors-{os.geteuid()}")
    archive, security = sources.deb822_paragraphs(new)
    assert_that(archive).contains_entry(
        {"uris": f"mirror+file:{stable}/archive-ubuntu.txt"},
        {"suites": "noble noble-updates noble-backports"},
        {"signed-by": KEYRING},
    )
    assert_that(security).contains_entry(
        {"uris": f"mirror+file:{stable}/security-ubuntu.txt"},
        {"suites": "noble-security"},
        {"signed-by": KEYRING},
    )
    assert_that(_entries(stable / "archive-ubuntu.txt")).is_equal_to(
        [f"{uri}\tpriority:{rank}" for rank, uri in enumerate(ARCHIVE_ENTRIES, 1)],
    )
    assert_that(_entries(stable / "security-ubuntu.txt")).is_equal_to(
        [f"{uri}\tpriority:{rank}" for rank, uri in enumerate(SECURITY_ENTRIES, 1)],
    )


def test_two_runs_name_the_identical_source_uri(
    mirrors: ModuleType,
    sources: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """Separate calls rewrite to one URI, so apt finds its indexes and dates."""
    root = _root(tmp_path)
    first = _rewrite(
        sources,
        _listed_policy(mirrors, monkeypatch, root),
        "ubuntu.sources",
        NOBLE_SOURCES,
    )
    second = _rewrite(
        sources,
        _listed_policy(mirrors, monkeypatch, root),
        "ubuntu.sources",
        NOBLE_SOURCES,
    )

    assert_that(second).is_equal_to(first)
    assert_that(first).does_not_contain(str(tmp_path / "parts"))


def test_two_tmpdirs_name_two_source_uris(
    mirrors: ModuleType,
    sources: ModuleType,
    failover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """The stable path follows the helper's TMPDIR, so two TMPDIRs differ.

    The helper therefore never trusts one TMPDIR's update for another: its
    update record sits in the same directory and holds a digest of the
    sources (test_apt_helper.py).
    """
    roots = [_root(tmp_path), _root(tmp_path / "other")]
    texts = [
        _rewrite(
            sources,
            _listed_policy(mirrors, monkeypatch, root),
            "ubuntu.sources",
            NOBLE_SOURCES,
        )
        for root in roots
    ]

    assert_that(texts[0]).is_not_equal_to(texts[1])
    for root, text in zip(roots, texts, strict=True):
        assert_that(text).contains(f"mirror+file:{failover.lists_dir(root)}/")


def test_lists_are_readable_by_the_sandbox_user_but_not_listable(
    mirrors: ModuleType,
    failover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """``_apt`` may search the stable directory and read the lists, not list it."""
    root = _root(tmp_path)
    _listed_policy(mirrors, monkeypatch, root)

    stable = failover.lists_dir(root)
    assert_that(stat.S_IMODE(stable.stat().st_mode)).is_equal_to(0o711)
    names = sorted(path.name for path in stable.iterdir())
    assert_that(names).is_equal_to(["archive-ubuntu.txt", "security-ubuntu.txt"])
    for name in names:
        assert_that(stat.S_IMODE((stable / name).stat().st_mode)).is_equal_to(0o644)


def test_lists_hold_only_hosts_the_job_allows(
    mirrors: ModuleType,
    failover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """A host the allow list lacks never appears, even if it is a target host."""
    root = _root(tmp_path)
    allowed = frozenset(
        {
            ("archive.ubuntu.com", 80),
            ("azure.archive.ubuntu.com", 80),
            ("github.com", 443),
        },
    )
    _listed_policy(mirrors, monkeypatch, root, allowed)

    stable = failover.lists_dir(root)
    archive = [f"{AZURE}\tpriority:1", f"{ARCHIVE_HTTP}\tpriority:2"]
    assert_that(_entries(stable / "archive-ubuntu.txt")).is_equal_to(archive)
    # No security port is allowed: the first allowed archive host only.
    security = _entries(stable / "security-ubuntu.txt")
    assert_that(security).is_equal_to([f"{AZURE}\tpriority:1"])


def test_one_allowed_host_gives_a_one_entry_list(
    mirrors: ModuleType,
    failover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """With a single allowed archive host, both groups list just that host."""
    root = _root(tmp_path)
    allowed = frozenset({("azure.archive.ubuntu.com", 80)})
    _listed_policy(mirrors, monkeypatch, root, allowed)

    stable = failover.lists_dir(root)
    for name in ("archive-ubuntu.txt", "security-ubuntu.txt"):
        assert_that(_entries(stable / name)).is_equal_to([f"{AZURE}\tpriority:1"])


def test_a_new_allowed_set_rewrites_the_same_names(
    mirrors: ModuleType,
    failover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """The names stay fixed when the allowed set changes; only the content follows.

    A fixed name keeps apt's source identity, and with it the check that a
    new ``InRelease`` is not older than the last one.
    """
    root = _root(tmp_path)
    _listed_policy(mirrors, monkeypatch, root)
    stable = failover.lists_dir(root)

    narrow = frozenset({("archive.ubuntu.com", 80)})
    policy = _listed_policy(mirrors, monkeypatch, root, narrow)

    assert_that(sorted(policy.lists)).is_equal_to(
        ["archive-ubuntu.txt", "security-ubuntu.txt"],
    )
    for name in policy.lists:
        expected = [f"{ARCHIVE_HTTP}\tpriority:1"]
        assert_that(_entries(stable / name)).is_equal_to(expected)


def test_mirror_method_falls_through_to_the_next_allowed_host(
    mirrors: ModuleType,
    failover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """Read as apt does, a dead first host moves the fetch to the second (#1664).

    Fixture runs 44520135974 and 44521089863 timed out on
    ``archive.ubuntu.com:443``; ``priority`` keeps the order whatever apt's
    random tie-break draws, and the next allowed host serves the file.
    """
    root = _root(tmp_path)
    _listed_policy(mirrors, monkeypatch, root)
    stable = failover.lists_dir(root)
    archive_text = (stable / "archive-ubuntu.txt").read_text("utf-8")
    security_text = (stable / "security-ubuntu.txt").read_text("utf-8")

    for seed in range(50):
        rng = random.Random(seed)
        order = _read_mirror_list(archive_text, rng)
        assert_that(order).is_equal_to(ARCHIVE_ENTRIES)
        got, tried = _fetch(order, "dists/noble/InRelease", dead={ARCHIVE})
        assert_that(got).is_equal_to(f"{AZURE}/dists/noble/InRelease")
        assert_that(tried).is_equal_to([ARCHIVE, AZURE])
        order = _read_mirror_list(security_text, rng)
        got, _ = _fetch(order, "dists/noble-security/InRelease", dead={SECURITY})
        assert_that(got).is_equal_to(f"{SECURITY_HTTP}/dists/noble-security/InRelease")


def test_security_list_falls_back_to_the_first_archive_host_only(
    mirrors: ModuleType,
    failover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """Both security ports dead: the archive serves -security, as the third try."""
    root = _root(tmp_path)
    _listed_policy(mirrors, monkeypatch, root)
    text = (failover.lists_dir(root) / "security-ubuntu.txt").read_text("utf-8")

    order = _read_mirror_list(text, random.Random(0))
    dead = {SECURITY, SECURITY_HTTP}
    got, tried = _fetch(order, "dists/noble-security/InRelease", dead)

    assert_that(order).is_equal_to(SECURITY_ENTRIES)
    assert_that(got).is_equal_to(f"{ARCHIVE}/dists/noble-security/InRelease")
    assert_that(tried).is_equal_to([SECURITY, SECURITY_HTTP, ARCHIVE])


def test_untagged_mirrors_would_be_tried_in_random_order() -> None:
    """Without ``priority`` apt shuffles mirrors, which is why every line has one."""
    text = f"{ARCHIVE}\n{AZURE}\n{ARCHIVE_HTTP}\n"
    firsts = {_read_mirror_list(text, random.Random(seed))[0] for seed in range(50)}

    assert_that(firsts).is_length(3)


def test_summary_names_each_list_and_its_hosts(
    mirrors: ModuleType,
    sources: ModuleType,
    failover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """The log line names the replaced list, each stable list and its hosts."""
    root = _root(tmp_path)
    policy = _listed_policy(mirrors, monkeypatch, root)
    _rewrite(sources, policy, "ubuntu.sources", NOBLE_SOURCES)
    stable = failover.lists_dir(root)

    summary = policy.summary()

    assert_that(summary).contains(
        "overrode Ubuntu archive sources mirror+file:/etc/apt/apt-mirrors.txt",
        f"apt uses mirror+file:{stable}/archive-ubuntu.txt"
        f" ({ARCHIVE}, {AZURE}, {ARCHIVE_HTTP})",
        f"mirror+file:{stable}/security-ubuntu.txt ({', '.join(SECURITY_ENTRIES)})",
        "(allowed archive hosts from test)",
    )
    assert_that(summary).does_not_contain("one host per suite")


def test_unsearchable_parent_names_the_first_host_directly(
    mirrors: ModuleType,
    sources: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """When ``_apt`` could not reach the lists, each suite names one host, as before.

    The blocker is fixed, not read from ``tmp_path``'s real parents, so the
    result is the same for any user, umask or parent mode.
    """
    closed = tmp_path / "closed"
    monkeypatch.setattr(mirrors.apt_failover, "sandbox_blocker", lambda _path: closed)
    root = _root(tmp_path)
    policy = mirrors.MirrorPolicy(mirrors.TARGET_HOSTS, "test").with_lists(root)

    new = _rewrite(sources, policy, "ubuntu.sources", NOBLE_SOURCES)

    assert_that(policy.lists_dir).is_none()
    assert_that(list(root.iterdir())).is_empty()
    assert_that(new).contains(f"URIs: {ARCHIVE}\n", f"URIs: {SECURITY}\n")
    assert_that(policy.summary()).contains(
        f"apt uses {ARCHIVE}, {SECURITY}",
        f"; one host per suite: {closed} is not searchable by _apt",
    )


def test_sandbox_blocker_names_the_first_unsearchable_parent(
    failover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Every parent is checked; the first without ``o+x`` (or unreadable) blocks."""
    modes = {"/": 0o755, "/a": 0o755, "/a/b": 0o750, "/a/b/c": 0o711}

    def fake_stat(path: object) -> os.stat_result:
        mode = modes.get(str(path))
        if mode is None:
            raise FileNotFoundError(str(path))
        return os.stat_result((stat.S_IFDIR | mode, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    monkeypatch.setattr(failover.os.path, "realpath", str)
    monkeypatch.setattr(failover.os, "stat", fake_stat)
    lists = Path("/a/b/c/lists")

    assert_that(failover.sandbox_blocker(lists)).is_equal_to(Path("/a/b"))
    modes["/a/b"] = 0o711
    assert_that(failover.sandbox_blocker(lists)).is_none()
    del modes["/a"]
    assert_that(failover.sandbox_blocker(lists)).is_equal_to(Path("/a"))


def test_symlinked_lists_directory_falls_back(
    mirrors: ModuleType,
    sources: ModuleType,
    failover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """A symlink at the stable path is refused: one host per suite, nothing written."""
    root = _root(tmp_path)
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    failover.lists_dir(root).symlink_to(elsewhere)

    policy = _listed_policy(mirrors, monkeypatch, root)
    new = _rewrite(sources, policy, "ubuntu.sources", NOBLE_SOURCES)

    assert_that(policy.lists_dir).is_none()
    assert_that(list(elsewhere.iterdir())).is_empty()
    assert_that(new).contains(f"URIs: {ARCHIVE}\n")
    assert_that(policy.summary()).contains("is not a directory (or is a symlink)")


def test_foreign_or_writable_lists_directory_is_refused(
    failover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """Another owner, or group or other write access, refuses the directory."""
    directory = tmp_path / "lists"
    directory.mkdir(mode=0o700)
    lists = {"archive-ubuntu.txt": [ARCHIVE]}

    directory.chmod(0o775)
    with pytest.raises(failover.ListsRefused, match="writable by group or others"):
        failover.publish_lists(directory, lists)
    directory.chmod(0o711)
    owner = os.geteuid()
    monkeypatch.setattr(failover.os, "geteuid", lambda: owner + 1)
    with pytest.raises(failover.ListsRefused, match=f"owned by uid {owner}"):
        failover.publish_lists(directory, lists)
    assert_that(list(directory.iterdir())).is_empty()


def test_symlinked_or_writable_list_file_is_refused(
    failover: ModuleType,
    tmp_path: Path,
) -> None:
    """An existing list that is a symlink or writable by others is never trusted."""
    directory = tmp_path / "lists"
    directory.mkdir(mode=0o700)
    target = tmp_path / "target"
    target.write_text("x", encoding="utf-8")
    (directory / "archive-ubuntu.txt").symlink_to(target)
    lists = {"archive-ubuntu.txt": [ARCHIVE]}

    with pytest.raises(failover.ListsRefused, match="not a regular file"):
        failover.publish_lists(directory, lists)
    (directory / "archive-ubuntu.txt").unlink()
    (directory / "archive-ubuntu.txt").write_text("x", encoding="utf-8")
    (directory / "archive-ubuntu.txt").chmod(0o666)
    with pytest.raises(failover.ListsRefused, match="writable by group or others"):
        failover.publish_lists(directory, lists)
    assert_that(target.read_text("utf-8")).is_equal_to("x")


def test_lists_are_replaced_atomically_and_only_on_change(
    failover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """Stale content is renamed over, equal content stays, a failed write keeps it."""
    directory = tmp_path / "lists"
    lists = {"archive-ubuntu.txt": [ARCHIVE, AZURE]}
    path = directory / "archive-ubuntu.txt"
    expected = failover.list_bytes([ARCHIVE, AZURE])

    failover.publish_lists(directory, lists)
    first = path.stat().st_ino
    failover.publish_lists(directory, lists)
    assert_that(path.stat().st_ino).is_equal_to(first)

    path.write_bytes(expected.replace(b"priority:2", b"priority:9"))
    failover.publish_lists(directory, lists)
    assert_that(path.read_bytes()).is_equal_to(expected)
    assert_that(path.stat().st_ino).is_not_equal_to(first)

    path.write_bytes(b"stale\n")

    def broken_fsync(_fd: int) -> None:
        raise OSError(5, "Input/output error")

    monkeypatch.setattr(failover.os, "fsync", broken_fsync)
    with pytest.raises(OSError, match="Input/output error"):
        failover.publish_lists(directory, lists)
    assert_that(path.read_bytes()).is_equal_to(b"stale\n")
    assert_that(sorted(p.name for p in directory.iterdir())).is_equal_to(
        ["archive-ubuntu.txt"],
    )


def test_other_hosts_are_left_alone(
    mirrors: ModuleType,
    sources: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """Sources off the Canonical archive keep their URIs and log no override."""
    policy = _listed_policy(mirrors, monkeypatch, _root(tmp_path))
    text = (
        f"{DEB}http://ports.ubuntu.com/ubuntu-ports\n"
        "Suites: noble\nComponents: main\n\n"
        f"{DEB}https://mirror.corp.example/ubuntu\nSuites: noble\nComponents: main\n"
    )

    assert_that(_rewrite(sources, policy, "ubuntu.sources", text)).is_equal_to(text)
    assert_that(policy.changes).is_empty()


def test_other_archive_paths_name_one_host_directly(
    mirrors: ModuleType,
    sources: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """Only ``/ubuntu`` has lists, so ``/a/b`` and ``/a-b`` cannot share one."""
    policy = _listed_policy(mirrors, monkeypatch, _root(tmp_path))
    ec2 = "http://us-east-2.ec2.archive.ubuntu.com"
    text = f"deb {ec2}/a/b noble main\ndeb {ec2}/a-b noble main\n"

    new = _rewrite(sources, policy, "extra.list", text)

    assert_that(new.splitlines()).is_equal_to(
        [
            "deb https://archive.ubuntu.com/a/b noble main",
            "deb https://archive.ubuntu.com/a-b noble main",
        ],
    )
    # An allowed host on another path keeps its URI.
    allowed = f"deb {ARCHIVE_HTTP}-alt noble main\n"
    assert_that(_rewrite(sources, policy, "x.list", allowed)).is_equal_to(allowed)


# The ubuntu-24.04 shape behind fixture run 44523617881: the mirror list for
# the archive suites, and security.ubuntu.com:80 named directly.
NOBLE_TWO_STANZAS = f"""\
Types: deb
URIs: mirror+file:/etc/apt/apt-mirrors.txt
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: {KEYRING}

Types: deb
URIs: http://security.ubuntu.com/ubuntu
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: {KEYRING}
"""


def test_allowed_security_host_gets_failover_too(
    mirrors: ModuleType,
    sources: ModuleType,
    failover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """``security.ubuntu.com:80`` is allowed, yet goes behind the security list."""
    root = _root(tmp_path)
    policy = _listed_policy(mirrors, monkeypatch, root)
    stable = failover.lists_dir(root)

    new = _rewrite(sources, policy, "ubuntu.sources", NOBLE_TWO_STANZAS)

    archive, security = sources.deb822_paragraphs(new)
    assert_that(archive["uris"]).is_equal_to(f"mirror+file:{stable}/archive-ubuntu.txt")
    assert_that(security).contains_entry(
        {"uris": f"mirror+file:{stable}/security-ubuntu.txt"},
        {"suites": "noble-security"},
        {"signed-by": KEYRING},
    )
    assert_that(policy.summary()).contains(
        "overrode Ubuntu archive sources mirror+file:/etc/apt/apt-mirrors.txt,"
        f" {SECURITY_HTTP} (",
    )


def test_main_sources_list_mirror_uri_is_rewritten(
    mirrors: ModuleType,
    sources: ModuleType,
    failover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """``sources.list`` is a distribution file: its mirror list is replaced too."""
    root = _root(tmp_path)
    policy = _listed_policy(mirrors, monkeypatch, root)
    stable = failover.lists_dir(root)
    text = (
        "deb mirror+file:/etc/apt/apt-mirrors.txt jammy main restricted\n"
        "deb [arch=amd64] http://security.ubuntu.com/ubuntu jammy-security main\n"
        "# deb http://archive.ubuntu.com/ubuntu jammy-backports main\n"
    )

    new = _rewrite(sources, policy, "sources.list", text)

    security = f"mirror+file:{stable}/security-ubuntu.txt"
    assert_that(new.splitlines()).is_equal_to(
        [
            f"deb mirror+file:{stable}/archive-ubuntu.txt jammy main restricted",
            f"deb [arch=amd64] {security} jammy-security main",
            "# deb http://archive.ubuntu.com/ubuntu jammy-backports main",
        ],
    )
    # A copied sources.list.d file with that name is no distribution file.
    plain = "deb mirror+file:/etc/apt/apt-mirrors.txt jammy main\n"
    assert_that(_rewrite(sources, policy, "other.list", plain)).is_equal_to(plain)


def test_copy_main_list_writes_a_private_copy_only_on_change(
    mirrors: ModuleType,
    failover: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """The private ``sources.list`` exists only when a URI changed; /etc stays."""
    root = _root(tmp_path)
    policy = _listed_policy(mirrors, monkeypatch, root)
    parts = tmp_path / "parts"
    parts.mkdir(mode=0o700)
    (tmp_path / "etc").mkdir()
    main = tmp_path / "etc/sources.list"
    main.write_text("# Ubuntu sources have moved\n", encoding="utf-8")
    rewrite = policy.rewrite_for(main.name)

    assert_that(failover.copy_main_list(main, parts, rewrite)).is_none()
    assert_that(list(parts.iterdir())).is_empty()

    original = b"deb mirror+file:/etc/apt/apt-mirrors.txt jammy main\n\xff\n"
    main.write_bytes(original)
    copy = failover.copy_main_list(main, parts, rewrite)

    stable = failover.lists_dir(root)
    line = f"deb mirror+file:{stable}/archive-ubuntu.txt jammy main\n"
    assert_that(copy).is_equal_to(parts / "main/sources.list")
    assert_that(copy.read_bytes()).is_equal_to(line.encode() + b"\xff\n")
    assert_that(main.read_bytes()).is_equal_to(original)
    missing = failover.copy_main_list(tmp_path / "etc/missing", parts, rewrite)
    assert_that(missing).is_none()
