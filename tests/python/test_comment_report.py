# SPDX-License-Identifier: MIT
"""Tests for ``report`` mode (``scripts/ci/lib/comment_report.py``, #1676).

The mode inserts zero-width spaces and never parses markdown. These tests
check what must hold however GitHub reads the structure: every reviewer
input and a generated corpus come out with no live mention, reference, tag,
image, link, URL or entity except the allowed ones, never contain the
reserved marker, and give the same text on a second pass. lgtm-ci's own
report bodies pass unchanged.
"""

from __future__ import annotations

import html
import itertools
import random
import re
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest
from assertpy import assert_that

ZWSP = chr(0x200B)
GOLDEN_DIR = Path(__file__).resolve().parents[1] / "fixtures" / "comment-golden"
ALLOWED_TAGS = ("<details>", "</details>", "<summary>", "</summary>", "<sub>", "</sub>")
SAFE_ENTITIES = ("&amp;", "&lt;", "&gt;", "&quot;", "&#8203;")
THREAD_PATH = r"(?i:/(?:issues|pulls?|discussions)/[0-9])"
COMMIT_PATH = r"(?i:/commits?/[0-9a-f]{7})"
#: Anything in a URL that would hold a break point other than its ``://``.
URL_BREAKS = r"[@$&()|`\\]|#[0-9]|(?i:gh)-[0-9]|(?i:www\.)|://|" + THREAD_PATH
SHA = "7fd1a60b01f91b314f59955a4e4d4e80d8edf11d"

#: Every input a reviewer used to get past the earlier, parsing design.
REVIEWER_INPUTS: dict[str, str] = {
    "html-block-fence": '<p>\n```\n<img src="https://e.x/p.png">\n@octocat #1\n```\n',
    "removed-link-joins-mention": "[@](javascript:x)octocat",
    "removed-link-joins-image": "[!](javascript:x)[a](https://e.example/p.png)",
    "removed-link-joins-html": '[<](javascript:x)img src="https://e.example/p.png">',
    "removed-link-joins-marker": "[<](javascript:x)!-- lgtm-ci:test -->",
    "nested-removal-two-passes": "[[@](javascript:x)](javascript:y)octocat",
    "list-tilde-fence": "- item\n  ~~~\n<img src=x>\n@octocat #1\n",
    "list-backtick-fence": "- ```\n  x\n  ```\n@octocat <img src=x> #1\n```",
    "list-fence-blank": "- ```\n  code\n  ```\n\n@octocat #123 <img src=x>\n",
    "details-html-block": "<details>\n```\n\n@octocat <img src=x> #1\n```",
    "table-cell-split-code": "| a | b |\n|---|---|\n| `a | <img src=x> ` | c |",
    "multi-line-code-span": "x `\n` <img src=x> @octocat `",
    "protocol-relative": "[x]( //e.example/a) [[x]](//e.example/a)",
    "backslash-destination": "[[x]](https:\\e.example/a)",
    "entity-destinations": "[a](&#47;/e.example/p) [b](http&#58;//e.example)",
    "entity-userinfo": "[c](https&#58;//github.com@e.example/) &#64;octocat",
    "rebuilt-outer-link": "[[a](x:y)](//e.example/p) [[a](x:y)](http:e.example)",
    "github-issue-url": "https://github.com/octocat/Hello-World/issues/1",
    "github-pull-link": "[x](https://github.com/o/r/pull/1)",
    "fence-made-by-removal": "[](x:y)```\n@octocat",
    "badge-image-in-link": "[![x](javascript:foo)](https://ok.example)",
    "image-userinfo": "[ ![a](https://user@e.example/)",
    "quoted-reference": "> [r]: //e.example/path\n>\n> [click][r]",
    "reference-next-line": "[r]:\n //e.example/path\n\n[click][r]",
    "lychee-file-name": "### Errors in d/@octocat #1 <img src=x> ![a](https://x.y/i).md",
    "marker": "<!-- lgtm-ci:history:start -->\n<!--LGTM-CI:x-->",
    # Third round: exemptions judged on boundaries GitHub does not use.
    "relative-www": "\\[a](www.evil.example)",
    "relative-scheme-path": "\\[b](x/http://evil.example/p)",
    "relative-code-span": "`[a](`x/http://evil.example/p)",
    "relative-commit": f"\\[a](x/https://github.com/octocat/Hello-World/commit/{SHA})",
    "relative-gist": "\\[b](x/https://gist.github.com/x)",
    "bare-gt-userinfo": "see https://example.com>@evil.example/p now",
    "bare-gt-github": "see https://example.com>@github.com/o/r/commit/7fd1a60 now",
    "bare-nbsp": "https://example.com\u00a0.evil.example/x",
    "bare-gt-path": "https://example.com/a>b",
    "table-pipe-destination": "| a | b |\n|---|---|\n|[x](a|http://example.com)|",
    "table-pipe-www": "| a | b |\n|---|---|\n|[x](a|www.example.com)|",
    "code-span-destination": "`[x](a`http://example.com`)",
    "commit-paths": f"see e.example/o/r/commit/{SHA} and o/r@{SHA}",
    "math": "$x$ and $$\\href{evil.example}{y}$$",
    # Fourth round: a backslash turns a link or autolink into a bare URL.
    "escaped-link-userinfo": "\\[a](https://example.com)@evil.example/p",
    "escaped-autolink-userinfo": "\\<https://example.com>@github.com/o/Hello-World",
    "escaped-link-in-table": "| a |\n|---|\n| \\[a](https://e.example)@evil.example |",
    "escaped-link-in-details": "<details>\n\n\\[a](https://example.com)@evil.example/p",
    "link-then-host": "[a](https://example.com).evil.example/p",
    "autolink-then-path": "<https://example.com>/../x",
}

#: Pieces the generated corpus combines, inside and outside block syntax.
TOKENS = (
    *("@octocat", "a@b.co", "#12", "o/r#3", "GH-4", "<img src=x>", "<!--"),
    *("lgtm-ci:x -->", "![a](https://e.example/i.png)", "[ok](https://e.example/a)"),
    *("[x](javascript:y)", "[x][r]", "[r]: https://e.example"),
    *("](", "][", "]:", "[", "]", "`", "```", "~~~", "https://e.example/p"),
    *("http://e.example", "www.e.example", "https://github.com/o/r/issues/1"),
    *("o/r/pull/2", "/discussions/3", "&#64;", "&amp;", "&lt;", "<details>"),
    *("</details>", "<summary>", "<sub>", "<https://e.example/a>"),
    *("<https://e.example/@x>", ZWSP, "\\", "!", "(", ")", ":", "|", "$", "$$"),
    *("\\[ok](https://e.example/a)", "`[ok](https://e.example/a)`"),
    *("|[ok](https://e.example/a)|", "[x](a|http://e.x)", "\\[a](www.e.x)"),
    *("[x](https://e.example/a|b)", "[x](https://e.example/a`b)", "[r](docs/a.md)"),
    *("https://e.example>@evil.example/p", "https://e.example/a)", "\u00a0"),
    *(f"/commit/{SHA[:12]}", f"o/r@{SHA[:12]}", SHA, "https://www.e.example/"),
)
FRAMES = ("{}", "- {}", "> {}", "| {} | x |", "```\n{}\n```", "<p>\n{}", "  {}")


def _corpus() -> list[str]:
    """Generate a deterministic corpus of token combinations in block frames."""
    rng = random.Random(1676)
    corpus = [a + b for a, b in itertools.product(TOKENS, repeat=2)]
    for _ in range(2500):
        pieces = rng.choices(TOKENS, k=rng.randint(2, 6))
        joined = "".join(rng.choice(("", " ", "\n")) + piece for piece in pieces)
        corpus.append(rng.choice(FRAMES).format(joined))
    return corpus


CORPUS = _corpus()


def _allowed_url(sanitize: ModuleType, value: str) -> bool:
    """Restate the rule for a URL that may stay linked, independently."""
    host = sanitize.host(value) or ""
    names = ["github.com", "githubusercontent.com", "githubassets.com", "github.io"]
    names += ["github.dev", "gh.io", "git.io"]
    github = any(host == name or host.endswith("." + name) for name in names)
    tail = value[len("https://") :]
    return (
        value.lower().startswith("https://")
        and sanitize.url(value) == value
        and not re.search(URL_BREAKS + "|" + COMMIT_PATH, tail)
        and not github
    )


def _bare_url(out: str, start: int) -> str:
    """Return the bare URL at ``start`` as GitHub's autolink would take it."""
    found = re.match(r"https://[^ \t\n<]*", out[start:], re.IGNORECASE)
    url = found.group(0) if found else ""
    while url:
        unbalanced = url[-1] == ")" and url.count(")") > url.count("(")
        if url[-1] not in ".,:;!?'\"*_~" and not unbalanced:
            break
        url = url[:-1]
    return url


def _live_links(sanitize: ModuleType, out: str) -> list[str]:
    """List each ``](`` and ``://`` that is not part of an allowed link or URL."""
    found = []
    links = [
        m
        for m in re.finditer(r"\[[^\[\]`!\n]*\]\(([^\s)]*)\)", out)
        if _allowed_url(sanitize, m.group(1))
    ]
    closers = ".,:;!?'\"*_~)>"
    for close in re.finditer(r"\]\(", out):
        if not any(m.start() < close.start() < m.end() for m in links):
            found.append(f"link at {close.start()}")
    for scheme in re.finditer(f"(?<!{ZWSP})://", out):
        start = out.rfind("https", 0, scheme.start())
        own = start >= 0 and start + 5 == scheme.start()
        # However the URL is written (link, autolink or bare), GitHub can be
        # made to read it as a bare URL up to the next space or ``<``, so that
        # whole run must be an allowed URL plus closing punctuation only.
        run = re.match(r"https://[^ \t\n<]*", out[max(start, 0) :], re.IGNORECASE)
        whole = run.group(0) if own and run else ""
        core = whole.rstrip(closers)
        if not (core and _allowed_url(sanitize, core)):
            found.append(f"URL at {scheme.start()}")
    return found


def _rebuilt_syntax(sanitize: ModuleType, out: str) -> list[str]:
    """List the live syntax left in report output; empty means inert."""
    found = []
    refs = r"#[0-9]|(?i:gh)-[0-9]|!\[|\]\[|\]:|" + THREAD_PATH
    if re.search(r"@\w", out) or re.search(refs, out):
        found.append("mention, reference, image or reference link")
    if re.search(r"(?i)<!--\s*lgtm-ci", out):
        found.append("reserved marker")
    for tag in re.finditer(r"<[A-Za-z/!?]", out):
        if any(out.startswith(allowed, tag.start()) for allowed in ALLOWED_TAGS):
            continue
        autolink = re.match(r"<(https://[^\s<>]+)>", out[tag.start() :])
        if not (autolink and _allowed_url(sanitize, autolink.group(1))):
            found.append(f"tag at {tag.start()}")
    for entity in re.finditer(r"&(?:#|[A-Za-z0-9]+;)", out):
        if not any(out.startswith(safe, entity.start()) for safe in SAFE_ENTITIES):
            found.append(f"entity at {entity.start()}")
    found.extend(_live_links(sanitize, out))
    math = re.search(f"(?<!{ZWSP})\\$|\\$(?!{ZWSP})", out)
    if re.search(r"(?i)www\.", out) or math:
        found.append("www or math")
    if re.search(COMMIT_PATH + "|@[0-9a-f]", out):
        found.append("commit reference")
    return found


@pytest.fixture(name="sanitize", scope="module")
def fixture_sanitize(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the sanitiser module."""
    return load_script("scripts/ci/lib/comment_sanitize.py")


@pytest.mark.parametrize(
    "value",
    list(REVIEWER_INPUTS.values()),
    ids=list(REVIEWER_INPUTS),
)
def test_reviewer_inputs_come_out_inert(sanitize: ModuleType, value: str) -> None:
    """No reviewer input keeps live syntax, on the first or the second pass."""
    once = sanitize.report(value)
    assert_that(_rebuilt_syntax(sanitize, once)).is_empty()
    assert_that(sanitize.report(once)).is_equal_to(once)


def test_generated_corpus_is_inert_and_idempotent(sanitize: ModuleType) -> None:
    """Thousands of token combinations in block frames: inert and idempotent."""
    failures = []
    for value in CORPUS:
        once = sanitize.report(value)
        if _rebuilt_syntax(sanitize, once) or sanitize.report(once) != once:
            failures.append(value)
    assert_that(failures).is_empty()


def test_output_is_input_with_zero_width_spaces_only(sanitize: ModuleType) -> None:
    """Nothing is deleted or reordered: removing U+200B gives back the input."""
    for value in CORPUS:
        cleaned = sanitize.strip_invisible(value, keep_tabs=True)
        assert_that(sanitize.report(value).replace(ZWSP, "")).is_equal_to(cleaned)


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("@octocat a@b.co", "@~octocat a@~b.co"),
        ("#12 o/r#3 GH-4 gh-5 #x", "#~12 o/r#~3 GH~-4 gh~-5 #x"),
        ("<img> <!-- x --> </p> <?x> a < b", "<~img> <~!-- x --> <~/p> <~?x> a < b"),
        ("<details><summary>S</summary></details> <sub>f</sub>", None),
        ("<Details> <details open>", "<~Details> <~details open>"),
        ("![a](https://e.example/i.png)", "!~[a](https://e.example/i.png)"),
        (
            "[ok](https://e.example/a) [r](docs/a.md#L3)",
            "[ok](https://e.example/a) [r]~(docs/a.md#L3)",
        ),
        ("[x](javascript:y) [x](/abs) [x](../up) [x](//h)", None),
        ("see https://e.x/y. or http://e.x", "see https://e.x/y. or http~://e.x"),
        ("www.e.x https://www.e.x/", "www~.e.x https~://www~.e.x/"),
        ("$x$ $$", "~$~x~$~ ~$~$~"),
        ("(see https://e.x/a) https://e.x/b>c", "(see https://e.x/a) https~://e.x/b>c"),
        ("[a](https://e.x/a|b) [b](https://e.x/b)", "[a]~(https~://e.x/a|b) [b](https://e.x/b)"),
        (
            f"/commit/{SHA[:7]} o/r@{SHA[:7]} {SHA}",
            f"/commit/~{SHA[:7]} o/r@~{SHA[:7]} {SHA}",
        ),
        ("&#64;x &amp; &lt; &#8203; &copy;", "&~#~64;x &amp; &lt; &#8203; &~copy;"),
        ("[x][r]\n[r]: https://e.example", "[x]~[r]\n[r]~: https://e.example"),
    ],
)
def test_rules(sanitize: ModuleType, value: str, expected: str | None) -> None:
    """Each rule inserts U+200B (shown as ``~``) where the module docstring says."""
    out = sanitize.report(value).replace(ZWSP, "~")
    if expected is None:
        bad = value.startswith("[x](javascript")
        refused = "[x]~(javascript:y) [x]~(/abs) [x]~(../up) [x]~(//h)"
        expected = refused if bad else value
    assert_that(out).is_equal_to(expected)


def test_github_links_show_as_text(sanitize: ModuleType) -> None:
    """Issue, pull request and commit URLs on GitHub hosts never stay linked."""
    value = " ".join(
        (
            "[pr](https://github.com/o/r/pull/1)",
            "https://api.github.com/x",
            "https://raw.githubusercontent.com/x",
            "https://octocat.github.io/x",
            "https://github.dev/o/r",
            "https://gh.io/x",
            "https://git.io/x",
            "https://github.githubassets.com/x",
        ),
    )
    out = sanitize.report(value)
    assert_that(out.count(f"{ZWSP}://")).is_equal_to(8)
    assert_that(out).contains(f"]{ZWSP}(")


@pytest.mark.parametrize("name", ["validate", "link-check", "artifact-report"])
def test_lgtm_ci_bodies_pass_unchanged(sanitize: ModuleType, name: str) -> None:
    """lgtm-ci's own bodies (layout tags, fences, tables) pass byte for byte."""
    body = (GOLDEN_DIR / f"{name}.txt").read_text(encoding="utf-8")
    assert_that(sanitize.report(body)).is_equal_to(body)


def test_lychee_report_passes_unchanged(sanitize: ModuleType) -> None:
    """A lychee report, ``<https://...>`` autolinks included, passes byte for byte."""
    report = (
        "# Summary\n\n| Status | Count |\n|---|---|\n"
        "| 🔍 Total | 2 |\n| 🚫 Errors | 1 |\n\n"
        "## Errors per input\n\n### Errors in README.md\n\n"
        "* [404] <https://e.example/missing> | Failed: Network error: Not Found\n"
    )
    out = sanitize.report(report)
    assert_that(out).is_equal_to(report)
    hostile = sanitize.report("<http://e.example/x> <https://github.com/o/r/pull/1>")
    broken_http = f"<{ZWSP}http{ZWSP}://e.example/x>"
    broken_github = f"<{ZWSP}https{ZWSP}://github.com/o/r/pull/{ZWSP}1>"
    assert_that(hostile).is_equal_to(f"{broken_http} {broken_github}")
    assert_that(html.unescape(out)).does_not_contain("@")
