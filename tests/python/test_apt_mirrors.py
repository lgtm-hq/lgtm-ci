# SPDX-License-Identifier: MIT
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


# --- private mirror lists (#1664) ---------------------------------------------

AZURE = "http://azure.archive.ubuntu.com/ubuntu"
ARCHIVE_HTTP = "http://archive.ubuntu.com/ubuntu"
SECURITY_HTTP = "http://security.ubuntu.com/ubuntu"
# apt's default priority for a mirror without a ``priority`` tag (ULONG_MAX).
NO_PRIORITY = 2**64 - 1


def _parts(tmp_path: Path) -> Path:
    """Create a private SourceParts directory, as ``tempfile`` would."""
    parts = tmp_path / "parts"
    parts.mkdir(mode=0o700)
    return parts


def _listed_policy(
    mirrors: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    parts: Path,
    allowed: frozenset[tuple[str, int]] | None = None,
) -> Any:
    """Return a policy writing lists under ``parts``, whatever ``tmp_path``'s modes."""
    monkeypatch.setattr(mirrors.apt_failover, "sandbox_blocker", lambda _parts: None)
    hosts = mirrors.TARGET_HOSTS if allowed is None else allowed
    base = mirrors.MirrorPolicy(hosts, "test")
    return base.with_lists(parts)


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
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """Archive and security suites name their own private list of allowed hosts."""
    parts = _parts(tmp_path)
    policy = _listed_policy(mirrors, monkeypatch, parts)
    new = _rewrite(sources, policy, "ubuntu.sources", NOBLE_SOURCES)

    written = policy.write_lists()

    archive_list = parts / "mirrors/archive-ubuntu.txt"
    security_list = parts / "mirrors/security-ubuntu.txt"
    assert_that(written).is_equal_to([archive_list, security_list])
    archive, security = sources.deb822_paragraphs(new)
    assert_that(archive).contains_entry(
        {"uris": f"mirror+file:{archive_list}"},
        {"suites": "noble noble-updates noble-backports"},
        {"signed-by": KEYRING},
    )
    assert_that(security).contains_entry(
        {"uris": f"mirror+file:{security_list}"},
        {"suites": "noble-security"},
        {"signed-by": KEYRING},
    )
    assert_that(archive_list.read_text("utf-8").splitlines()[1:]).is_equal_to(
        [
            f"{ARCHIVE}\tpriority:1",
            f"{AZURE}\tpriority:2",
            f"{ARCHIVE_HTTP}\tpriority:3",
        ],
    )
    assert_that(security_list.read_text("utf-8").splitlines()[1:]).is_equal_to(
        [
            f"{SECURITY}\tpriority:1",
            f"{SECURITY_HTTP}\tpriority:2",
            f"{ARCHIVE}\tpriority:3",
            f"{AZURE}\tpriority:4",
            f"{ARCHIVE_HTTP}\tpriority:5",
        ],
    )


def test_lists_are_readable_by_the_sandbox_user_but_not_listable(
    mirrors: ModuleType,
    sources: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """``_apt`` may search the private directory and read the lists, not list it."""
    parts = _parts(tmp_path)
    policy = _listed_policy(mirrors, monkeypatch, parts)
    _rewrite(sources, policy, "ubuntu.sources", NOBLE_SOURCES)

    written = policy.write_lists()

    assert_that(stat.S_IMODE(parts.stat().st_mode)).is_equal_to(0o711)
    assert_that(stat.S_IMODE((parts / "mirrors").stat().st_mode)).is_equal_to(0o711)
    for path in written:
        assert_that(stat.S_IMODE(path.stat().st_mode)).is_equal_to(0o644)


def test_lists_hold_only_hosts_the_job_allows(
    mirrors: ModuleType,
    sources: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """A host the allow list lacks never appears, even if it is a target host."""
    parts = _parts(tmp_path)
    allowed = frozenset(
        {
            ("archive.ubuntu.com", 80),
            ("azure.archive.ubuntu.com", 80),
            ("github.com", 443),
        },
    )
    policy = _listed_policy(mirrors, monkeypatch, parts, allowed)
    _rewrite(sources, policy, "ubuntu.sources", NOBLE_SOURCES)

    policy.write_lists()

    lists = {p.name: p.read_text("utf-8") for p in (parts / "mirrors").iterdir()}
    expected = f"{AZURE}\tpriority:1\n{ARCHIVE_HTTP}\tpriority:2\n"
    assert_that(lists).is_length(2)
    for text in lists.values():
        assert_that(text).ends_with(expected)
        assert_that(text).does_not_contain("https://", "security.ubuntu.com", "github")


def test_one_allowed_host_gives_a_one_entry_list(
    mirrors: ModuleType,
    sources: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """With a single allowed archive host, both groups list just that host."""
    parts = _parts(tmp_path)
    allowed = frozenset({("azure.archive.ubuntu.com", 80)})
    policy = _listed_policy(mirrors, monkeypatch, parts, allowed)
    _rewrite(sources, policy, "ubuntu.sources", NOBLE_SOURCES)

    for path in policy.write_lists():
        entries = [x for x in path.read_text("utf-8").splitlines() if x[:1] != "#"]
        assert_that(entries).is_equal_to([f"{AZURE}\tpriority:1"])


def test_mirror_method_falls_through_to_the_next_allowed_host(
    mirrors: ModuleType,
    sources: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """Read as apt does, a dead first host moves the fetch to the second (#1664).

    Fixture runs 44520135974 and 44521089863 timed out on
    ``archive.ubuntu.com:443``; ``priority`` keeps the order whatever apt's
    random tie-break draws, and the next allowed host serves the file.
    """
    parts = _parts(tmp_path)
    policy = _listed_policy(mirrors, monkeypatch, parts)
    _rewrite(sources, policy, "ubuntu.sources", NOBLE_SOURCES)
    archive_list, security_list = policy.write_lists()

    for seed in range(50):
        rng = random.Random(seed)
        order = _read_mirror_list(archive_list.read_text("utf-8"), rng)
        assert_that(order).is_equal_to([ARCHIVE, AZURE, ARCHIVE_HTTP])
        got, tried = _fetch(order, "dists/noble/InRelease", dead={ARCHIVE})
        assert_that(got).is_equal_to(f"{AZURE}/dists/noble/InRelease")
        assert_that(tried).is_equal_to([ARCHIVE, AZURE])
        order = _read_mirror_list(security_list.read_text("utf-8"), rng)
        got, _ = _fetch(order, "dists/noble-security/InRelease", dead={SECURITY})
        assert_that(got).is_equal_to(f"{SECURITY_HTTP}/dists/noble-security/InRelease")


def test_untagged_mirrors_would_be_tried_in_random_order() -> None:
    """Without ``priority`` apt shuffles mirrors, which is why every line has one."""
    text = f"{ARCHIVE}\n{AZURE}\n{ARCHIVE_HTTP}\n"
    firsts = {_read_mirror_list(text, random.Random(seed))[0] for seed in range(50)}

    assert_that(firsts).is_length(3)


def test_summary_names_each_private_list_and_its_hosts(
    mirrors: ModuleType,
    sources: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """The log line names the replaced list, each private list and its hosts."""
    parts = _parts(tmp_path)
    policy = _listed_policy(mirrors, monkeypatch, parts)
    _rewrite(sources, policy, "ubuntu.sources", NOBLE_SOURCES)

    summary = policy.summary()

    assert_that(summary).contains(
        "overrode Ubuntu archive sources mirror+file:/etc/apt/apt-mirrors.txt",
        f"apt uses mirror+file:{parts}/mirrors/archive-ubuntu.txt"
        f" ({ARCHIVE}, {AZURE}, {ARCHIVE_HTTP})",
        f"mirror+file:{parts}/mirrors/security-ubuntu.txt"
        f" ({SECURITY}, {SECURITY_HTTP}, {ARCHIVE}, {AZURE}, {ARCHIVE_HTTP})",
        "(allowed archive hosts from test)",
    )
    assert_that(summary).does_not_contain("one host per suite")


def test_unsearchable_parent_names_the_first_host_directly(
    mirrors: ModuleType,
    sources: ModuleType,
    tmp_path: Path,
) -> None:
    """When ``_apt`` could not reach the lists, each suite names one host, as before."""
    closed = tmp_path / "closed"
    closed.mkdir(mode=0o700)
    parts = _parts(closed)
    policy = mirrors.MirrorPolicy(mirrors.TARGET_HOSTS, "test").with_lists(parts)

    new = _rewrite(sources, policy, "ubuntu.sources", NOBLE_SOURCES)

    assert_that(policy.lists_dir).is_none()
    assert_that(policy.write_lists()).is_empty()
    assert_that(list(parts.iterdir())).is_empty()
    assert_that(new).contains(f"URIs: {ARCHIVE}\n", f"URIs: {SECURITY}\n")
    assert_that(policy.summary()).contains(
        f"apt uses {ARCHIVE}, {SECURITY}",
        f"one host per suite: {closed} is not searchable by _apt",
    )


def test_sandbox_blocker_checks_every_parent(
    mirrors: ModuleType,
    tmp_path: Path,
) -> None:
    """Only a chain of other-searchable parents lets ``_apt`` reach the lists."""
    outer = tmp_path / "outer"
    inner = outer / "inner"
    inner.mkdir(parents=True)
    parts = inner / "parts"
    parts.mkdir(mode=0o700)
    outer.chmod(0o700)
    try:
        assert_that(mirrors.apt_failover.sandbox_blocker(parts)).is_equal_to(
            Path(os.path.realpath(outer)),
        )
        outer.chmod(0o711)
        blocker = mirrors.apt_failover.sandbox_blocker(parts)
        real_parents = Path(os.path.realpath(outer)).parents
        assert_that(blocker is None or blocker in real_parents).is_true()
    finally:
        outer.chmod(0o755)


def test_other_hosts_write_no_list(
    mirrors: ModuleType,
    sources: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """Sources off the Canonical archive leave the private directory as it is."""
    parts = _parts(tmp_path)
    policy = _listed_policy(mirrors, monkeypatch, parts)
    text = (
        f"{DEB}http://ports.ubuntu.com/ubuntu-ports\n"
        "Suites: noble\nComponents: main\n\n"
        f"{DEB}https://mirror.corp.example/ubuntu\nSuites: noble\nComponents: main\n"
    )

    assert_that(_rewrite(sources, policy, "ubuntu.sources", text)).is_equal_to(text)
    assert_that(policy.write_lists()).is_empty()
    assert_that(list(parts.iterdir())).is_empty()
    assert_that(stat.S_IMODE(parts.stat().st_mode)).is_equal_to(0o700)


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
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """``security.ubuntu.com:80`` is allowed, yet goes behind the security list."""
    parts = _parts(tmp_path)
    policy = _listed_policy(mirrors, monkeypatch, parts)

    new = _rewrite(sources, policy, "ubuntu.sources", NOBLE_TWO_STANZAS)
    policy.write_lists()

    security_list = parts / "mirrors/security-ubuntu.txt"
    archive, security = sources.deb822_paragraphs(new)
    assert_that(archive["uris"]).is_equal_to(
        f"mirror+file:{parts}/mirrors/archive-ubuntu.txt",
    )
    assert_that(security).contains_entry(
        {"uris": f"mirror+file:{security_list}"},
        {"suites": "noble-security"},
        {"signed-by": KEYRING},
    )
    assert_that(new.replace(f"mirror+file:{security_list}", SECURITY_HTTP)).is_equal_to(
        NOBLE_TWO_STANZAS.replace(
            "mirror+file:/etc/apt/apt-mirrors.txt",
            f"mirror+file:{parts}/mirrors/archive-ubuntu.txt",
        ),
    )
    assert_that(policy.summary()).contains(
        "overrode Ubuntu archive sources mirror+file:/etc/apt/apt-mirrors.txt,"
        f" {SECURITY_HTTP} (",
    )


def test_security_list_falls_back_to_the_archive_hosts(
    mirrors: ModuleType,
    sources: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """With both security ports dead, the -security pocket comes from the archive."""
    parts = _parts(tmp_path)
    policy = _listed_policy(mirrors, monkeypatch, parts)
    _rewrite(sources, policy, "ubuntu.sources", NOBLE_TWO_STANZAS)
    security_list = policy.write_lists()[1]

    order = _read_mirror_list(security_list.read_text("utf-8"), random.Random(0))
    dead = {SECURITY, SECURITY_HTTP}
    got, tried = _fetch(order, "dists/noble-security/InRelease", dead)

    assert_that(got).is_equal_to(f"{ARCHIVE}/dists/noble-security/InRelease")
    assert_that(tried).is_equal_to([SECURITY, SECURITY_HTTP, ARCHIVE])


def test_main_sources_list_mirror_uri_is_rewritten(
    mirrors: ModuleType,
    sources: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """``sources.list`` is a distribution file: its mirror list is replaced too."""
    parts = _parts(tmp_path)
    policy = _listed_policy(mirrors, monkeypatch, parts)
    text = (
        "deb mirror+file:/etc/apt/apt-mirrors.txt jammy main restricted\n"
        "deb [arch=amd64] http://security.ubuntu.com/ubuntu jammy-security main\n"
        "# deb http://archive.ubuntu.com/ubuntu jammy-backports main\n"
    )

    new = _rewrite(sources, policy, "sources.list", text)

    assert_that(new.splitlines()).is_equal_to(
        [
            f"deb mirror+file:{parts}/mirrors/archive-ubuntu.txt jammy main restricted",
            f"deb [arch=amd64] mirror+file:{parts}/mirrors/security-ubuntu.txt"
            " jammy-security main",
            "# deb http://archive.ubuntu.com/ubuntu jammy-backports main",
        ],
    )
    # A copied sources.list.d file with that name is no distribution file.
    plain = "deb mirror+file:/etc/apt/apt-mirrors.txt jammy main\n"
    assert_that(_rewrite(sources, policy, "other.list", plain)).is_equal_to(plain)


def test_copy_main_list_writes_a_private_copy_only_on_change(
    mirrors: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """The private ``sources.list`` exists only when a URI changed; /etc stays."""
    failover = mirrors.apt_failover
    parts = _parts(tmp_path)
    policy = _listed_policy(mirrors, monkeypatch, parts)
    etc = tmp_path / "etc"
    etc.mkdir()
    main = etc / "sources.list"
    comment = "# Ubuntu sources have moved to /etc/apt/sources.list.d/ubuntu.sources\n"
    main.write_text(comment, encoding="utf-8")

    rewrite = policy.rewrite_for(main.name)
    assert_that(failover.copy_main_list(main, parts, rewrite)).is_none()
    assert_that(list(parts.iterdir())).is_empty()

    original = b"deb mirror+file:/etc/apt/apt-mirrors.txt jammy main\n\xff\n"
    main.write_bytes(original)
    copy = failover.copy_main_list(main, parts, rewrite)

    assert_that(copy).is_equal_to(parts / "main/sources.list")
    line = f"deb mirror+file:{parts}/mirrors/archive-ubuntu.txt jammy main\n"
    assert_that(copy.read_bytes()).is_equal_to(line.encode() + b"\xff\n")
    assert_that(main.read_bytes()).is_equal_to(original)
    missing = failover.copy_main_list(etc / "missing", parts, rewrite)
    assert_that(missing).is_none()
