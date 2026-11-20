# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/lib/comment_sanitize.py`` (#1676).

A table-driven corpus of hostile values runs through every mode, and each
mode's invariants are checked on every value: inline text never carries a
raw ``<``, a working mention, reference or URL, a second line or a hidden
character; code spans and fences cannot be closed early; no mode lets the
reserved ``<!-- lgtm-ci:`` marker through; only plain HTTPS URLs link.
"""

from __future__ import annotations

import html
import os
import re
import subprocess
import sys
import unicodedata
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/ci/lib/comment_sanitize.py"
MARKER = "<!-- lgtm-ci:"

HOSTILE: dict[str, str] = {
    "team-mention": "@org/team",
    "user-mention": "ping @someone now",
    "history-marker": "<!-- lgtm-ci:history:start -->",
    "marker-variants": "<!--lgtm-ci:x--> <!--   LGTM-CI:y -->",
    "details-close": "</details>",
    "script": "<script>alert(1)</script>",
    "javascript-url": "javascript:alert(1)",
    "http-url": "http://example.com/x",
    "userinfo-url": "https://user@example.com/",
    "idn-host": "https://пример.испытание/",
    "punycode-host": "https://xn--e1afmkfd.xn--80akhbyknj4f/",
    "bidi": "abc\u202edcba\u2066x\u2069 \u200e\u200f",
    "zero-width": "a\u200bb\u200c\u200dc\ufeffd\u2060",
    "hangul-filler": "a\u3164b\u115fc",
    "pipes": "a | b || c \\| d",
    "backticks": "a ` b `` c ``` d ```` e",
    "edge-backticks": "`start and end`",
    "newlines": "line1\nline2\r\nline3\rline4\u2028line5\u2029line6\x85line7",
    "issue-refs": "fixes #123, o/r#4 and GH-5",
    "autolinks": "<https://evil.example> www.evil.example a@b.example HTTPS://X.Y",
    "emphasis": "*b* _i_ ~~s~~ **B** __U__",
    "link-syntax": "[x](https://e.example) ![i](https://e.x/i.png) [r]: https://e",
    "pre-escaped": "&#64;org &lt;b&gt; \\* &amp; @&#8203;x",
    "math": "$x^2$ and $$y$$",
    "ansi": "\x1b[31mred\x1b[0m \x1b]8;;https://e\x07link\x1b]8;;\x07",
    "controls": "a\x00b\x07c\x7fd\x1be",
    "lone-surrogate": "a\udc80b",
    "heading-close": "title ## ",
    "large": "@x <!-- lgtm-ci:y --> |`" * 600,
    "email-autolinks": "foo@-bar.com a@.b c@_d.e x+y@z.example",
    "hostile-file-name": "docs/@octocat #1 <img src=x> ![a](https://x.y/i.png).md",
}
NORMAL: list[str] = [
    "Shell Tests",
    "Unit Tests (py3.12)",
    "my_build-artifact",
    "src/app_main.py",
    "R&D suite, part 2",
    "lodash 4.17.21",
    "docs,README.md",
    "80",
    "shard 3 timed out",
]
SAFE_URLS: list[str] = [
    "https://o.github.io/r/report/",
    "https://github.com/o/r/actions/runs/42/artifacts/7",
    "https://example.com:8443/a?b=c&d=e#f",
    "HTTPS://Example.COM/x",
]
UNSAFE_URLS: list[str] = [
    "",
    "http://example.com/",
    "javascript:alert(1)",
    "data:text/html,<b>x</b>",
    "https://user@example.com/",
    # Built in two parts so secret scanners do not read it as a credential.
    "https://user" + ":pw@example.com/",
    "https://good.com:443" + "@evil.com/",
    "https://good.com\\@evil.com/",
    "https://пример.испытание/",
    "https://xn--e1afmkfd.com/",
    "https://[::1]/",
    "https://exa mple.com/",
    "https://example.com/a b",
    "https://example.com/\u202e",
    "https://example.com/\x00",
    "https:///evil.com",
    "https:evil.com",
    "//evil.com",
    "https://-bad-.com/",
    "https://example.com:0/",
    "https://example.com:99999/",
    "https://example..com/",
    "https://" + "a" * 2050 + ".com/",
]


@pytest.fixture(name="sanitize")
def fixture_sanitize(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the sanitiser module by path."""
    return load_script("scripts/ci/lib/comment_sanitize.py")


def _hidden(value: str) -> list[str]:
    """List the control and ``Cf`` characters left in ``value``."""
    hidden = {"Cc", "Cf", "Cs"}
    return [c for c in value if unicodedata.category(c) in hidden and c not in "\n\t"]


def _closes_early(span: str) -> bool:
    """Tell whether a code span's content holds its own delimiter run."""
    ticks = re.match(r"`+", span)
    if ticks is None:
        return True
    run = ticks.group(0)
    inner = span[len(run) : -len(run)]
    runs = re.findall(r"`+", inner)
    return not span.endswith(run) or any(len(r) == len(run) for r in runs)


@pytest.mark.parametrize("value", list(HOSTILE.values()), ids=list(HOSTILE))
@pytest.mark.parametrize("mode", ["text", "cell"])
def test_inline_text_invariants(sanitize: ModuleType, mode: str, value: str) -> None:
    """Inline text has no raw ``<``, line break, hidden character or live link."""
    out = getattr(sanitize, mode)(value)
    assert_that(out).does_not_contain("<", "\n", "\r", MARKER)
    assert_that(_hidden(out)).is_empty()
    # GitHub links and mentions on the text after entities are decoded.
    shown = html.unescape(out)
    assert_that(re.search(r"@[A-Za-z0-9_.+-]", shown)).is_none()
    assert_that(re.search(r"#[0-9]", shown)).is_none()
    assert_that(re.search(r"(?i)gh-[0-9]", shown)).is_none()
    assert_that(re.search(r"[A-Za-z]://", shown)).is_none()
    assert_that(re.search(r"(?i)www\.", shown)).is_none()
    without_pairs = out.replace("\\\\", "")
    assert_that(re.search(r"(?<!\\)[|*`\[\]~$]", without_pairs)).is_none()


@pytest.mark.parametrize("value", list(HOSTILE.values()), ids=list(HOSTILE))
@pytest.mark.parametrize("mode", ["code", "cell_code"])
def test_code_span_invariants(sanitize: ModuleType, mode: str, value: str) -> None:
    """A code span is one line, cannot close early and hides no marker."""
    out = getattr(sanitize, mode)(value)
    assert_that(out).does_not_contain("\n", "\r", MARKER)
    assert_that([c for c in _hidden(out) if c != "\u200b"]).is_empty()
    assert_that(_closes_early(out)).is_false()
    if mode == "cell_code":
        unescaped = re.search(r"(?<!\\)\|", out)
        doubled = re.search(r"\\\\\|", out)
        assert_that([unescaped, doubled]).is_equal_to([None, None])


@pytest.mark.parametrize("value", list(HOSTILE.values()), ids=list(HOSTILE))
def test_fence_invariants(sanitize: ModuleType, value: str) -> None:
    """A fence is longer than any backtick run inside and hides no marker."""
    out = sanitize.fence(value)
    lines = out.split("\n")
    fence = lines[0]
    assert_that(fence).matches(r"^`{3,}$")
    assert_that(lines[-1]).is_equal_to(fence)
    inner = "\n".join(lines[1:-1])
    longest = max((len(r) for r in re.findall(r"`+", inner)), default=0)
    assert_that(longest).is_less_than(len(fence))
    assert_that(out).does_not_contain(MARKER, "\r")
    assert_that([c for c in _hidden(out) if c != "\u200b"]).is_empty()


@pytest.mark.parametrize("value", list(HOSTILE.values()), ids=list(HOSTILE))
def test_markdown_keeps_markup_but_not_hidden_content(
    sanitize: ModuleType,
    value: str,
) -> None:
    """Markdown mode removes hidden characters and the marker, nothing else."""
    out = sanitize.markdown(value)
    assert_that(out).does_not_contain(MARKER, "\r")
    assert_that([c for c in _hidden(out) if c != "\u200b"]).is_empty()
    if value == HOSTILE["link-syntax"]:
        assert_that(out).is_equal_to(value)


@pytest.mark.parametrize("value", list(HOSTILE.values()), ids=list(HOSTILE))
def test_link_never_names_another_host(sanitize: ModuleType, value: str) -> None:
    """``link`` shows the host itself, or inert text for an unsafe URL."""
    out = sanitize.link(value)
    match = re.fullmatch(r"\[([^\]]*)\]\((\S+)\)", out)
    if match is None:
        assert_that(out).is_equal_to(sanitize.text(value))
    else:
        assert_that(match.group(1)).is_equal_to(sanitize.host(value))


@pytest.mark.parametrize("value", UNSAFE_URLS)
def test_unsafe_urls_are_refused(sanitize: ModuleType, value: str) -> None:
    """Only HTTPS with a plain ASCII host and no userinfo is linked."""
    assert_that([sanitize.url(value), sanitize.host(value)]).is_equal_to([None, None])
    assert_that(sanitize.labelled_link(value, "Report")).does_not_contain("](")
    assert_that(sanitize.link(value)).does_not_contain("](")


@pytest.mark.parametrize("value", SAFE_URLS)
def test_safe_urls_are_kept_byte_for_byte(sanitize: ModuleType, value: str) -> None:
    """A plain HTTPS URL passes unchanged and links with its host as text."""
    host = re.sub(r"(?i)^https://([^/:?#]+).*$", r"\1", value).lower()
    assert_that(sanitize.url(value)).is_equal_to(value)
    assert_that(sanitize.host(value)).is_equal_to(host)
    assert_that(sanitize.link(value)).is_equal_to(f"[{host}]({value})")
    labelled = sanitize.labelled_link(value, "View report")
    assert_that(labelled).is_equal_to(f"[View report]({value})")


def test_url_parentheses_cannot_end_a_link(sanitize: ModuleType) -> None:
    """Brackets are refused and parentheses encoded: a URL cannot end a link early."""
    assert_that(sanitize.url("https://example.com/a)[x](https://e.example")).is_none()
    assert_that(sanitize.url("https://example.com/wiki/A_(b)")).is_equal_to(
        "https://example.com/wiki/A_%28b%29",
    )


@pytest.mark.parametrize("value", NORMAL)
@pytest.mark.parametrize("mode", ["text", "cell"])
def test_normal_values_are_unchanged(
    sanitize: ModuleType,
    mode: str,
    value: str,
) -> None:
    """Ordinary names, paths and numbers pass through byte for byte."""
    assert_that(getattr(sanitize, mode)(value)).is_equal_to(value)


@pytest.mark.parametrize("value", NORMAL)
def test_normal_code_and_fence_are_unchanged(sanitize: ModuleType, value: str) -> None:
    """Ordinary values keep the single-backtick span and triple-backtick fence."""
    assert_that(sanitize.code(value)).is_equal_to(f"`{value}`")
    assert_that(sanitize.fence(value + "\n\n")).is_equal_to(f"```\n{value}\n```")


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("&lt;b&gt;", "&amp;lt;b&amp;gt;"),
        ("&#64;org", "&amp;\\#&#8203;64;org"),
        ("\\*not bold\\*", "\\\\\\*not bold\\\\\\*"),
        ("@\u200borg", "@&#8203;org"),
    ],
    ids=["entity", "numeric-entity", "backslash-escape", "pre-broken-mention"],
)
def test_already_escaped_input_is_not_trusted(
    sanitize: ModuleType, value: str, expected: str
) -> None:
    """Input is raw text: earlier escaping shows literally and pre-breaks nothing."""
    assert_that(sanitize.text(value)).is_equal_to(expected)


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("my_suite", "my_suite"),
        ("_lead and trail_", "\\_lead and trail\\_"),
        ("a | b", "a \\| b"),
        ("$5", "\\$5"),
        ("C:\\x", "C:\\\\x"),
        ("a < b > c", "a &lt; b &gt; c"),
        ("R&D", "R&D"),
        ("pkg@1.2.3", "pkg@&#8203;1.2.3"),
        ("[GHSA-x]", "\\[GHSA-x\\]"),
        ("foo@-bar.com", "foo@&#8203;-bar.com"),
        ("a@.b", "a@&#8203;.b"),
        ("x @ y", "x @ y"),
    ],
)
def test_text_escapes(sanitize: ModuleType, value: str, expected: str) -> None:
    """Each special character gets the documented escape and no more."""
    assert_that(sanitize.text(value)).is_equal_to(expected)


def test_text_caps_long_values(sanitize: ModuleType) -> None:
    """A 10 KB value is cut to the cap before escaping."""
    out = sanitize.text("a" * 10_000)
    assert_that(out).is_length(sanitize.MAX_TEXT_CHARS).ends_with("\u2026")
    assert_that(sanitize.text("abcdef", max_chars=4)).is_equal_to("abc\u2026")


def test_fence_strips_trailing_newlines_and_caps_on_request(
    sanitize: ModuleType,
) -> None:
    """Fences drop trailing line breaks; a cap adds a truncation line."""
    assert_that(sanitize.fence("a\n\tb\n\n")).is_equal_to("```\na\n\tb\n```")
    assert_that(sanitize.fence("abcdef", max_chars=3)).is_equal_to(
        "```\nabc\n\u2026 (truncated)\n```"
    )
    assert_that(sanitize.fence("x", info="text")).is_equal_to("```text\nx\n```")


def test_markdown_keeps_trailing_newlines(sanitize: ModuleType) -> None:
    """Report files keep their exact trailing newlines."""
    assert_that(sanitize.markdown("## R\n\n| a |\n\n")).is_equal_to("## R\n\n| a |\n\n")


def test_code_pads_edge_backticks(sanitize: ModuleType) -> None:
    """A value starting or ending with a backtick is padded inside a longer run."""
    assert_that(sanitize.code("`x`")).is_equal_to("`` `x` ``")
    assert_that(sanitize.code("")).is_equal_to("` `")


def _cli(
    *args: str,
    data: bytes = b"",
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[bytes]:
    """Run the command line in isolated mode."""
    return subprocess.run(
        [sys.executable, "-I", "-S", str(SCRIPT), *args],
        input=data,
        capture_output=True,
        check=False,
        env={**os.environ, **(env or {})},
    )


def test_cli_reads_stdin_and_prints_without_newline() -> None:
    """A value comes from stdin, is never an option, and gets no trailing newline."""
    result = _cli("text", data=b"--max @team")
    expected = [0, b"--max @&#8203;team"]
    assert_that([result.returncode, result.stdout]).is_equal_to(expected)


def test_cli_env_and_batches() -> None:
    """``--env``, ``--nul`` and ``--json`` give the same results as the API."""
    env_result = _cli(
        "text",
        "--env",
        "LGTM_CI_TEST_VALUE",
        env={"LGTM_CI_TEST_VALUE": "<b>"},
    )
    nul_result = _cli("cell", "--nul", data=b"a|b\0\0#1\0")
    json_result = _cli("url", "--json", data=b'["https://e.com/", "http://e.com/"]')
    assert_that(env_result.stdout).is_equal_to(b"&lt;b&gt;")
    assert_that(nul_result.stdout).is_equal_to(b"a\\|b\0\0\\#&#8203;1\0")
    assert_that(json_result.stdout).is_equal_to(b'["https://e.com/", ""]')


def test_cli_max_applies_to_capped_modes() -> None:
    """``--max`` caps the inline and code modes."""
    result = _cli("text", "--max", "3", data=b"abcdef")
    assert_that(result.stdout).is_equal_to("ab\u2026".encode())


@pytest.mark.parametrize(
    "args",
    [
        [],
        ["nope"],
        ["text", "--max", "x"],
        ["url", "--max", "3"],
        ["text", "--nul", "--json"],
        ["text", "--env", "X", "--nul"],
        ["text", "extra"],
    ],
)
def test_cli_usage_errors(args: list[str]) -> None:
    """Unknown modes and malformed flags exit 2 with usage on stderr."""
    result = _cli(*args)
    assert_that(result.returncode).is_equal_to(2)
    assert_that(result.stderr.decode()).contains("usage:")


def test_cli_json_rejects_non_strings() -> None:
    """``--json`` needs an array of strings."""
    assert_that(_cli("text", "--json", data=b'[1, "a"]').returncode).is_equal_to(2)
