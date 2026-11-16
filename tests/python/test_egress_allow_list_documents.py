# SPDX-License-Identifier: MIT
"""Tests for the allow-list document reader of the egress DNS check (#1548).

``scripts/ci/maintenance/egress_allow_list_documents.py``, reached through
``check-egress-dns.py``, which re-exports it. Fully offline.
"""

from __future__ import annotations

import re
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
import yaml
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/maintenance/check-egress-dns.py"
PROJECT_ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture(name="dns")
def fixture_dns(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the DNS check without running it."""
    return load_script(SCRIPT_PATH)


def _tokens(dns: ModuleType, lines: list[str], markdown: bool) -> list[str]:
    """Return only the tokens a document yields."""
    return [token for _, token in dns.allow_list_entries(lines, markdown)]


def _layout(tmp_path: Path, files: dict[str, str | bytes]) -> Path:
    """Write files under a fresh repository root with docs/ and examples/."""
    (tmp_path / "docs").mkdir()
    (tmp_path / "examples").mkdir()
    for name, content in files.items():
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            path.write_bytes(content)
        else:
            path.write_text(content, encoding="utf-8")
    return tmp_path


# --- Units -------------------------------------------------------------------


def test_document_endpoints_read_each_unit_kind(
    dns: ModuleType,
    tmp_path: Path,
) -> None:
    """YAML files whole, Markdown fenced blocks one by one, anywhere below."""
    root = _layout(
        tmp_path,
        {
            "examples/a.yml": "allowed-endpoints: yml.invalid:443\n",
            "docs/deep/b.yaml": "x:\n  allowed-endpoints: yaml.invalid:443\n",
            "docs/c.md": "Text.\n\n```\nallowed-endpoints: md.invalid:443\n```\n",
            "examples/d.md": "~~~sh\n# allowed-endpoints\necho e.invalid:80\n~~~\n",
            "docs/e.txt": "allowed-endpoints: txt.invalid:443\n",
        },
    )

    pairs = dns.document_endpoints(root)

    assert_that(pairs).is_equal_to(
        [
            ("docs/c.md:4", "md.invalid:443"),
            ("docs/deep/b.yaml:2", "yaml.invalid:443"),
            ("examples/a.yml:1", "yml.invalid:443"),
            ("examples/d.md:3", "e.invalid:80"),
        ],
    )


def test_each_fenced_block_is_its_own_unit(dns: ModuleType) -> None:
    """A block is relevant on its own: a neighbour's key does not carry over."""
    lines = [
        "```yaml",
        "allowed-endpoints: >-",
        "  first.invalid:443",
        "```",
        "```sh",
        "curl https://unrelated.invalid:8443/",
        "```",
    ]

    entries = list(dns.allow_list_entries(lines, markdown=True))

    assert_that(entries).is_equal_to([(3, "first.invalid:443")])


# --- Relevance ---------------------------------------------------------------


@pytest.mark.parametrize(
    "lines",
    [
        pytest.param(["egress: a.invalid:443", "b.invalid:80"], id="no-key"),
        pytest.param(["allowed_endpoints: a.invalid:443"], id="other-spelling"),
        pytest.param(["Allowed-Endpoints: a.invalid:443"], id="other-case"),
    ],
)
def test_a_unit_without_the_marker_yields_nothing(
    dns: ModuleType,
    lines: list[str],
) -> None:
    """Without the substring ``allowed-endpoints`` no token is read."""
    assert_that(_tokens(dns, lines, markdown=False)).is_empty()


def test_a_relevant_unit_yields_every_token(dns: ModuleType) -> None:
    """Every host:port in the unit counts, under any key or none."""
    lines = [
        "egress-policy: block",
        "allowed-endpoints-mode: append",
        "other: unrelated.invalid:443",
        "# a comment naming comment.invalid:8080",
        "publish-allowed-endpoints: pypi.org:443",
    ]

    entries = list(dns.allow_list_entries(lines, markdown=False))

    assert_that(entries).is_equal_to(
        [
            (3, "unrelated.invalid:443"),
            (4, "comment.invalid:8080"),
            (5, "pypi.org:443"),
        ],
    )


# --- Shapes ------------------------------------------------------------------


@pytest.mark.parametrize(
    "lines",
    [
        pytest.param(
            ["allowed-endpoints: >", "  # the hosts:", "  host.invalid:443"],
            id="comment-between-key-and-value",
        ),
        pytest.param(
            ["allowed-endpoints:", "- host.invalid:443"],
            id="indentless-block-sequence",
        ),
        pytest.param(
            ["allowed-endpoints: >", "\thost.invalid:443"],
            id="tab-indented-value",
        ),
        pytest.param(
            ["+  allowed-endpoints: >-", "+    host.invalid:443", "-    old.x"],
            id="folded-value-in-a-diff",
        ),
        pytest.param(
            ["with: {allowed-endpoints: host.invalid:443,}"],
            id="flow-mapping-trailing-comma",
        ),
        pytest.param(
            ['"allowed-endpoints": "host.invalid:443"'],
            id="quoted-key",
        ),
        pytest.param(
            ['"allowed\\x2dendpoints": host.invalid:443  # allowed-endpoints'],
            id="escaped-key-with-the-marker-in-a-comment",
        ),
        pytest.param(
            ["printf 'allowed-endpoints: %s\\n' host.invalid:443 >> cfg"],
            id="shell-printf",
        ),
        pytest.param(
            ["yq -i '.with.allowed-endpoints = \"host.invalid:443\"' f.yml"],
            id="yq",
        ),
        pytest.param(
            ['{"with": {"allowed-endpoints": ["host.invalid:443"]}}'],
            id="json",
        ),
        pytest.param(
            [
                "# set allowed-endpoints to these:",
                "steps:",
                "  - run: host.invalid:443",
            ],
            id="key-in-a-comment-host-elsewhere",
        ),
        pytest.param(
            ["- - allowed-endpoints: host.invalid:443"],
            id="nested-sequence",
        ),
        pytest.param(
            ["x: {note: 'allowed-endpoints: host.invalid:443'}"],
            id="key-inside-a-quoted-value",
        ),
        pytest.param(
            ["with: {allowed-endpoints: [a.b,", "  host.invalid:443]}"],
            id="flow-mapping-over-two-lines",
        ),
    ],
)
def test_every_shape_yields_its_host(dns: ModuleType, lines: list[str]) -> None:
    """No YAML shape hides a host, and none is an error."""
    assert_that(_tokens(dns, lines, markdown=False)).is_equal_to(["host.invalid:443"])


def test_shapes_hold_their_hosts_inside_fenced_blocks(dns: ModuleType) -> None:
    """The same holds in a fenced block of any language."""
    lines = [
        "```diff",
        "+  allowed-endpoints: >-",
        "+    diff.invalid:443",
        "```",
        "```json",
        '{"allowed-endpoints": "json.invalid:443"}',
        "```",
    ]

    entries = list(dns.allow_list_entries(lines, markdown=True))

    assert_that(entries).is_equal_to([(3, "diff.invalid:443"), (6, "json.invalid:443")])


# --- Token boundaries --------------------------------------------------------


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        pytest.param("https://github.com:443/path", ["github.com:443"], id="url"),
        pytest.param("ghcr.io/owner/img:1.2.3", [], id="image-reference"),
        pytest.param("ghcr.io/owner/img.v2:1.2.3", [], id="dotted-image-name"),
        pytest.param("foo.bar:1.2.3", [], id="version-after-colon"),
        pytest.param("0.99.0:1", [], id="version-before-colon"),
        pytest.param("*.github.com:443", ["*.github.com:443"], id="wildcard"),
        pytest.param("api.*.example.org:443", ["api.*.example.org:443"], id="inner"),
        pytest.param("a.invalid:0", [], id="port-zero"),
        pytest.param("a.invalid:65536", [], id="port-too-large"),
        pytest.param("a.invalid:65535", ["a.invalid:65535"], id="port-max"),
        pytest.param("a.invalid:123456", [], id="port-six-digits"),
        pytest.param("GitHub.COM:443", ["github.com:443"], id="upper-case"),
        pytest.param("localhost:8080", [], id="no-dot"),
        pytest.param("my_host.invalid:443", [], id="underscore-before"),
        pytest.param("x-a.invalid:443", ["x-a.invalid:443"], id="hyphen-inside"),
        pytest.param("a.invalid:443_x a.invalid:44a", [], id="word-after-port"),
        pytest.param("a.invalid:443.", ["a.invalid:443"], id="sentence-dot"),
        pytest.param("(a.invalid:443),", ["a.invalid:443"], id="punctuation"),
        pytest.param("a.1nvalid:443 1.2.3.4:443", [], id="numeric-last-label"),
        pytest.param("a-.invalid:443", [], id="label-ending-in-hyphen"),
        pytest.param(
            "'a.invalid:443' \"b.invalid:80\"",
            ["a.invalid:443", "b.invalid:80"],
            id="quoted",
        ),
    ],
)
def test_token_boundaries(dns: ModuleType, text: str, expected: list[str]) -> None:
    """Only a whole host:port with a dotted host and a valid port is a token."""
    lines = [f"allowed-endpoints: {text}"]

    assert_that(_tokens(dns, lines, markdown=False)).is_equal_to(expected)


def test_every_token_is_a_valid_entry_for_the_checker(dns: ModuleType) -> None:
    """A collected token never makes the checker's entry parser fail."""
    text = "allowed-endpoints: a-b.c-d.example.io:1 *.x.dev:65535 X.Y.Z.Org:22"

    for token in _tokens(dns, [text], markdown=False):
        dns.parse_endpoint(token)


# --- Expressions -------------------------------------------------------------


def test_expressions_are_removed_also_across_lines(dns: ModuleType) -> None:
    """``${{ ... }}`` holds no host; line numbers stay right after it."""
    lines = [
        "allowed-endpoints: >-",
        "  ${{ fromJSON(env.PRESETS)['skip.invalid:443'] }}",
        "  ${{ inputs.extra ||",
        "      'inner.invalid:443' }} after.invalid:443",
        "  last.invalid:443",
    ]

    entries = list(dns.allow_list_entries(lines, markdown=False))

    assert_that(entries).is_equal_to(
        [(4, "after.invalid:443"), (5, "last.invalid:443")],
    )


def test_an_unclosed_expression_opener_removes_nothing(dns: ModuleType) -> None:
    """``${{`` without ``}}`` is plain text: the hosts after it are still read."""
    lines = ["allowed-endpoints: ${{ inputs.x", "github.com:443", "${{ " * 20000]

    entries = list(dns.allow_list_entries(lines, markdown=False))

    assert_that(entries).is_equal_to([(2, "github.com:443")])


@pytest.mark.parametrize(
    "token",
    ["*.\u017f.io:443", "\u0131nfo.example.io:443", "x.\u0130o:443"],
)
def test_every_collected_token_passes_the_checker(dns: ModuleType, token: str) -> None:
    """A letter outside ASCII never yields a token the checker would reject."""
    entries = list(dns.allow_list_entries([f"allowed-endpoints: {token}"], False))

    for _, entry in entries:
        dns.parse_endpoint(entry)
        assert_that(entry.isascii()).is_true()


def test_an_expression_does_not_join_its_neighbours(dns: ModuleType) -> None:
    """Text on either side of an expression stays apart."""
    lines = ["allowed-endpoints: a${{ x }}b.invalid:443"]

    assert_that(_tokens(dns, lines, markdown=False)).is_equal_to(["b.invalid:443"])


# --- Prose outside fences ----------------------------------------------------


@pytest.mark.parametrize(
    "lines",
    [
        pytest.param(
            ["Set allowed-endpoints: prose.invalid:443 to append."],
            id="sentence",
        ),
        pytest.param(
            ["| `allowed-endpoints` | `prose.invalid:443` |"],
            id="table-row",
        ),
        pytest.param(
            ["Example:", "", "    allowed-endpoints: prose.invalid:443"],
            id="indented-code-block",
        ),
        pytest.param(
            ["Use `allowed-endpoints:", "prose.invalid:443` here."],
            id="wrapped-inline-code",
        ),
        pytest.param(
            ["<pre>", "allowed-endpoints: prose.invalid:443", "</pre>"],
            id="html-block",
        ),
        pytest.param(
            ["allowed-endpoints: >", "  prose.invalid:443", "- - x: {a: '"],
            id="yaml-looking-prose",
        ),
    ],
)
def test_prose_is_never_read_and_never_fails(
    dns: ModuleType,
    lines: list[str],
) -> None:
    """Markdown text outside fenced blocks yields nothing and raises nothing."""
    assert_that(_tokens(dns, lines, markdown=True)).is_empty()


# --- Fences and containers ---------------------------------------------------


def test_a_fence_closes_only_on_its_own_marks(dns: ModuleType) -> None:
    """A shorter or different fence inside a block does not close it."""
    lines = [
        "````yaml",
        "```",
        "allowed-endpoints: inner.invalid:443",
        "~~~",
        "tilde.invalid:443",
        "````",
        "`allowed-endpoints`: prose.invalid:443",
        "~~~yaml",
        "allowed-endpoints: >-",
        "  last.invalid:443",
        "~~~",
    ]

    entries = list(dns.allow_list_entries(lines, markdown=True))

    assert_that(entries).is_equal_to(
        [
            (3, "inner.invalid:443"),
            (5, "tilde.invalid:443"),
            (10, "last.invalid:443"),
        ],
    )


@pytest.mark.parametrize(
    ("lines", "expected"),
    [
        pytest.param(
            [
                "1. Add the step:",
                "",
                "    ```yaml",
                "    allowed-endpoints: >",
                "      list.invalid:443",
                "    ```",
            ],
            [(5, "list.invalid:443")],
            id="list-item-indented-four",
        ),
        pytest.param(
            [
                "- ```yaml",
                "  with:",
                "    allowed-endpoints: marker.invalid:443",
                "  ```",
            ],
            [(3, "marker.invalid:443")],
            id="fence-on-the-list-marker-line",
        ),
        pytest.param(
            [
                "> ```yaml",
                "> allowed-endpoints: >-",
                ">   quote.invalid:443",
                ">",
                ">   second.invalid:443",
                "> ```",
            ],
            [(3, "quote.invalid:443"), (5, "second.invalid:443")],
            id="blockquote",
        ),
        pytest.param(
            [
                ">```yaml",
                ">allowed-endpoints: tight.invalid:443",
                ">```",
            ],
            [(2, "tight.invalid:443")],
            id="blockquote-without-space",
        ),
        pytest.param(
            [
                "> 1. Step:",
                ">",
                ">    ```yaml",
                ">    allowed-endpoints: >",
                ">      nested.invalid:443",
                ">    ```",
                "> > ~~~",
                "> > allowed-endpoints: deeper.invalid:443",
                "> > ~~~",
            ],
            [(5, "nested.invalid:443"), (8, "deeper.invalid:443")],
            id="nested-containers",
        ),
        pytest.param(
            [
                "-\t```yaml",
                "\tallowed-endpoints: >",
                "\t  tab.invalid:443",
                "\t```",
            ],
            [(3, "tab.invalid:443")],
            id="tab-indented-list",
        ),
        pytest.param(
            [
                "- Step:",
                "",
                "  ```yaml",
                "  allowed-endpoints: closed.invalid:443",
                "  ```",
                "",
                "  `allowed-endpoints`: prose.invalid:443",
            ],
            [(4, "closed.invalid:443")],
            id="fence-closed-inside-a-list-item",
        ),
        pytest.param(
            [
                "> ```yaml",
                "> allowed-endpoints: ended.invalid:443",
                "",
                "`allowed-endpoints`: prose.invalid:443",
                "```yaml",
                "allowed-endpoints: next.invalid:443",
                "```",
            ],
            [(2, "ended.invalid:443"), (6, "next.invalid:443")],
            id="blockquote-end-ends-the-block",
        ),
        pytest.param(
            [
                "    ```yaml",
                "    allowed-endpoints: unclosed.invalid:443",
            ],
            [(2, "unclosed.invalid:443")],
            id="block-closed-by-the-document-end",
        ),
        pytest.param(
            [
                "   ```yaml",
                "   allowed-endpoints: >",
                " short.invalid:443",
                "   ```",
            ],
            [(3, "short.invalid:443")],
            id="line-left-of-its-fence",
        ),
    ],
)
def test_fences_inside_containers_are_read(
    dns: ModuleType,
    lines: list[str],
    expected: list[tuple[int, str]],
) -> None:
    """List items and blockquotes, nested or not, lose their prefix."""
    entries = list(dns.allow_list_entries(lines, markdown=True))

    assert_that(entries).is_equal_to(expected)


@pytest.mark.parametrize(
    "lines",
    [
        pytest.param(
            ["- > ```yaml", "  > allowed-endpoints: host.invalid:443", "  > ```"],
            id="list-then-quote",
        ),
        pytest.param(
            ["> - ```yaml", ">   allowed-endpoints: host.invalid:443", ">   ```"],
            id="quote-then-list",
        ),
        pytest.param(
            [
                "> - > ```yaml",
                ">   > allowed-endpoints: host.invalid:443",
                ">   > ```",
            ],
            id="quote-list-quote",
        ),
        pytest.param(
            ["-\t> ```yaml", "\t> allowed-endpoints: host.invalid:443", "\t> ```"],
            id="tab-list-then-quote",
        ),
        pytest.param(
            [
                "1.  item",
                "",
                "    > ```yaml",
                "    > allowed-endpoints: host.invalid:443",
                "    > ```",
            ],
            id="quote-in-a-list-item-indented-four",
        ),
        pytest.param(
            ["2) * + ```", "       allowed-endpoints: host.invalid:443", "       ```"],
            id="ordered-and-bullet-markers",
        ),
    ],
)
def test_fences_in_mixed_containers_are_read(
    dns: ModuleType,
    lines: list[str],
) -> None:
    """List and blockquote markers are consumed in any order and nesting."""
    assert_that(_tokens(dns, lines, markdown=True)).is_equal_to(["host.invalid:443"])


def test_a_long_marker_run_is_scanned_promptly(dns: ModuleType) -> None:
    """A run of list markers is consumed in one pass, without backtracking."""
    lines = ["-  " * 24 + "paragraph", "-  " * 5000 + "```yaml", "a: b", "```"]

    assert_that(list(dns.allow_list_entries(lines, markdown=True))).is_empty()


def test_a_long_line_is_scanned_promptly(dns: ModuleType) -> None:
    """Long runs of labels without a port do not backtrack badly."""
    lines = ["allowed-endpoints: " + "a." * 50000 + " " + "b-" * 50000]

    assert_that(_tokens(dns, lines, markdown=False)).is_empty()


# --- Reading files -----------------------------------------------------------


@pytest.mark.parametrize(
    ("name", "text"),
    [
        ("docs/bom.md", "\ufeff```yaml\nallowed-endpoints: bom.invalid:443\n```\n"),
        ("examples/bom.yml", "\ufeffallowed-endpoints: bom.invalid:443\n"),
    ],
)
def test_a_byte_order_mark_is_ignored(
    dns: ModuleType,
    tmp_path: Path,
    name: str,
    text: str,
) -> None:
    """A leading BOM hides neither the first fence nor the first key."""
    root = _layout(tmp_path, {name: text})

    pairs = dns.document_endpoints(root)

    assert_that([token for _, token in pairs]).is_equal_to(["bom.invalid:443"])


def test_an_undecodable_file_is_an_error_naming_it(
    dns: ModuleType,
    tmp_path: Path,
) -> None:
    """A file that is not UTF-8 cannot be read, so the run cannot vouch for it."""
    root = _layout(tmp_path, {"docs/bad.md": b"allowed-endpoints: \xff\n"})

    with pytest.raises(dns.DnsCheckError, match=r"could not read .*docs/bad\.md"):
        dns.document_endpoints(root)


def test_an_unreadable_file_is_an_error_naming_it(
    dns: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """An OS error while reading names the file."""
    root = _layout(tmp_path, {"examples/locked.yml": "a: b\n"})
    real = Path.read_text

    def read_text(self: Path, *args: Any, **kwargs: Any) -> str:
        if self.name == "locked.yml":
            raise PermissionError(13, "Permission denied")
        return real(self, *args, **kwargs)

    monkeypatch.setattr(Path, "read_text", read_text)

    with pytest.raises(dns.DnsCheckError, match=r"could not read .*locked\.yml"):
        dns.document_endpoints(root)


# --- The repository's examples -----------------------------------------------


def _yaml_allow_list_tokens(node: Any, under_key: bool = False) -> set[str]:
    """Collect the host:port tokens of allow-list values in parsed YAML."""
    if isinstance(node, dict):
        tokens: set[str] = set()
        for key, value in node.items():
            name = str(key)
            listed = "allowed-endpoints" in name and not name.endswith("-mode")
            tokens |= _yaml_allow_list_tokens(value, listed)
        return tokens
    if isinstance(node, list):
        return set().union(*(_yaml_allow_list_tokens(v, under_key) for v in node))
    if not under_key or not isinstance(node, str):
        return set()
    text = re.sub(r"\$\{\{.*?\}\}", " ", node, flags=re.DOTALL)
    return {
        token.strip("'\"").lower()
        for token in re.split(r"[\s,{}\[\]]+", text)
        if token.strip("'\"")
    }


# Every YAML file the reader takes as a whole unit: both folders, both
# extensions.
EXAMPLES = sorted(
    path
    for folder in ("docs", "examples")
    for pattern in ("**/*.yml", "**/*.yaml")
    for path in (PROJECT_ROOT / folder).glob(pattern)
)


@pytest.mark.parametrize(
    "path",
    EXAMPLES,
    ids=lambda path: path.relative_to(PROJECT_ROOT).as_posix(),
)
def test_the_scanner_finds_every_host_a_yaml_parser_finds(
    dns: ModuleType,
    path: Path,
) -> None:
    """Each example's allow-list hosts, read by PyYAML, are all scanned.

    The scanner may read more (any host:port in a relevant file), never less.
    """
    text = path.read_text("utf-8")
    expected = _yaml_allow_list_tokens(yaml.safe_load(text))

    scanned = {token for _, token in dns.allow_list_entries(text.splitlines(), False)}

    assert_that(sorted(expected - scanned)).is_empty()


def test_the_examples_hold_allow_lists() -> None:
    """The comparison above is not vacuous: several examples list hosts."""
    contributing = [
        path
        for path in EXAMPLES
        if _yaml_allow_list_tokens(yaml.safe_load(path.read_text("utf-8")))
    ]

    assert_that(len(contributing)).is_greater_than_or_equal_to(3)
