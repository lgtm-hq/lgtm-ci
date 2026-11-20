# SPDX-License-Identifier: MIT
"""The Python half of the comment renderer guard, on synthetic modules (#1676, #1692).

``tests/helpers/comment_guard_python.py`` reads a Python formatter function
by function. These cases show what it rejects and what it accepts: raw values
added to ``sections`` or written out (``print`` with ``sep``/``end``,
``write`` on ``sys.stdout`` or an alias, ``os.write``, ``write_text`` and
opened files), control-flow merges, return safety from tracked values only,
and names a parameter or binding shadows. The real renderers are checked in
``test_comment_renderer_guard.py``.
"""

from __future__ import annotations

import pytest
from assertpy import assert_that
from comment_guard_python import python_offences

#: A module function that returns a constant, and the pathlib import.
SAFE_BODY = "def body():\n    return 'ok'\n\n"
PATH_IMPORT = "from pathlib import Path\n\n"


def _script(*lines: str) -> str:
    """Join source lines, one per argument, each ending in a newline."""
    return "".join(line + "\n" for line in lines)


@pytest.mark.parametrize(
    ("body", "bad"),
    [
        pytest.param(
            _script(
                "safe = comment_sanitize.cell(raw)",
                "safe = raw",
                "sections.append(f'| {safe} |')",
            ),
            True,
            id="raw-after-safe",
        ),
        pytest.param(
            _script(
                "safe = raw",
                "safe = comment_sanitize.cell(raw)",
                "sections.append(f'| {safe} |')",
            ),
            False,
            id="safe-after-raw",
        ),
        pytest.param(
            _script(
                "safe = comment_sanitize.cell(raw)",
                "safe = other = raw",
                "sections.append(safe)",
            ),
            True,
            id="chained-assignment-after-safe",
        ),
        pytest.param(
            _script(
                "safe = comment_sanitize.cell(raw)",
                "safe, extra = raw, 1",
                "sections.append(safe)",
            ),
            True,
            id="unpacking-after-safe",
        ),
        pytest.param(
            _script(
                "a = b = comment_sanitize.cell(raw)",
                "sections.append(f'{a} {b} {NOTE}')",
            ),
            False,
            id="chained-safe-and-module-constant",
        ),
        pytest.param(
            _script("for safe in [raw]:", "    sections.append(safe)"),
            True,
            id="for-target",
        ),
        pytest.param(
            _script(
                "safe = comment_sanitize.cell(raw)",
                "with open(raw) as safe:",
                "    sections.append(safe)",
            ),
            True,
            id="with-target",
        ),
        pytest.param(
            _script(
                "safe = comment_sanitize.cell(raw)",
                "if (safe := raw):",
                "    sections.append(safe)",
            ),
            True,
            id="walrus-target",
        ),
        pytest.param(
            _script(
                "safe = comment_sanitize.cell(raw)",
                "sections.extend([safe for safe in raw])",
            ),
            True,
            id="comprehension-target",
        ),
        pytest.param(
            _script("sections.extend([comment_sanitize.cell(r) for r in raw])"),
            False,
            id="comprehension-of-sanitised",
        ),
        pytest.param(
            _script("sections[len(sections):] = [raw]"),
            True,
            id="subscript-assignment",
        ),
        pytest.param(
            _script("sections.append(comment_sanitize.cap(raw, 10))"),
            True,
            id="helper-is-not-a-mode",
        ),
        pytest.param("sections.extend([raw])", True, id="extend"),
        pytest.param("sections.insert(0, raw)", True, id="insert"),
        pytest.param("sections += [f'{raw}']", True, id="augmented"),
        pytest.param("sections = sections + [raw]", True, id="rebinding"),
        pytest.param("sections.append(str(_count(raw)))", True, id="unknown-call"),
        pytest.param(
            _script("n = _count(raw)", "sections.append(f'{n} found')"),
            False,
            id="count",
        ),
        pytest.param(
            _script(
                "safe = comment_sanitize.cell(raw)",
                "other = (safe := raw)",
                "sections.append(safe)",
            ),
            True,
            id="walrus-inside-an-assignment",
        ),
        pytest.param(
            _script(
                "other = (safe := comment_sanitize.cell(raw))",
                "sections.append(safe)",
            ),
            False,
            id="walrus-of-sanitised-inside-an-assignment",
        ),
        pytest.param(
            _script("extra = []", "extra.append(raw)", "sections.extend(extra)"),
            True,
            id="list-mutated-before-extend",
        ),
        pytest.param(
            _script("extra = ['a']", "extra[0] = raw", "sections.extend(extra)"),
            True,
            id="list-item-replaced-before-extend",
        ),
        pytest.param(
            _script(
                "extra = []",
                "extra.append(comment_sanitize.cell(raw))",
                "sections.extend(extra)",
            ),
            False,
            id="list-of-sanitised-before-extend",
        ),
        pytest.param("print(raw)", True, id="print-to-stdout"),
        pytest.param("print(raw, file=sys.stdout)", True, id="print-to-sys-stdout"),
        pytest.param("print(raw, file=sys.stderr)", False, id="print-to-stderr"),
        pytest.param(
            "print(comment_sanitize.text(raw))",
            False,
            id="print-of-sanitised",
        ),
        pytest.param('print("a", "b", sep=raw)', True, id="print-sep"),
        pytest.param('print("prefix", end=raw)', True, id="print-end"),
        pytest.param('print("a", **raw)', True, id="print-kwargs"),
        pytest.param(
            'print("a", sep=" ", end="", flush=True)',
            False,
            id="print-constants",
        ),
        pytest.param("sys.stdout.write(raw)", True, id="stdout-write"),
        pytest.param(
            "sys.stdout.buffer.write(raw.encode())",
            True,
            id="stdout-buffer-write",
        ),
        pytest.param("sys.stdout.writelines([raw])", True, id="stdout-writelines"),
        pytest.param("os.write(1, raw.encode())", True, id="os-write"),
        pytest.param(
            _script("out = sys.stdout", "out.write(raw)"),
            True,
            id="stdout-alias-write",
        ),
        pytest.param(
            _script("out = sys.stdout", "print(raw, file=out)"),
            True,
            id="stdout-alias-print",
        ),
        pytest.param("sys.stderr.write(raw)", False, id="stderr-write"),
        pytest.param(
            "sys.stdout.buffer.write(comment_sanitize.text(raw).encode('utf-8'))",
            False,
            id="stdout-write-of-sanitised",
        ),
        pytest.param(
            "print(raw)  # comment-safe: a reviewed log line",
            False,
            id="reviewed-print",
        ),
        pytest.param(
            _script(
                "value = raw",
                "if raw:",
                "    value = 'fixed'",
                "sections.append(value)",
            ),
            True,
            id="safe-on-one-branch-only",
        ),
        pytest.param(
            _script(
                "if raw:",
                "    value = 'fixed'",
                "else:",
                "    value = comment_sanitize.cell(raw)",
                "sections.append(value)",
            ),
            False,
            id="safe-on-every-branch",
        ),
        pytest.param(
            _script(
                "value = raw",
                "for item in raw:",
                "    value = 'fixed'",
                "sections.append(value)",
            ),
            True,
            id="safe-only-if-the-loop-ran",
        ),
        pytest.param(
            _script(
                "value = raw",
                "try:",
                "    value = comment_sanitize.cell(raw)",
                "except ValueError:",
                "    pass",
                "sections.append(value)",
            ),
            True,
            id="safe-only-if-try-succeeded",
        ),
    ],
)
def test_python_guard_catches_raw_values(body: str, bad: bool) -> None:
    """The Python analysis is order-sensitive and covers every way to add a section."""
    indented = "\n".join("    " + line for line in body.splitlines())
    source = f"NOTE = 'constant'\n\ndef build(raw, sections):\n{indented}\n"
    assert_that(bool(python_offences(source, "fake.py"))).is_equal_to(bad)


def test_python_guard_follows_what_a_function_returns_to_print() -> None:
    """``print(format_comment(...))`` passes only when every return is safe."""
    safe_body = (
        "def body(raw):\n"
        "    sections = []\n"
        "    sections.append(comment_sanitize.cell(raw))\n"
        "    if not raw:\n"
        "        return None\n"
        '    return "\\n".join(sections)\n\n'
        "def main(raw):\n"
        "    print(body(raw))\n"
    )
    leaky = safe_body + (
        "\ndef leak(raw):\n    return raw\n\ndef other(raw):\n    print(leak(raw))\n"
    )
    joined = 'def glue(raw):\n    print("\\n".join([raw]))\n'
    assert_that(python_offences(safe_body, "fake.py")).is_empty()
    assert_that(python_offences(leaky, "fake.py")).is_equal_to(["fake.py:15 in other"])
    assert_that(python_offences(joined, "fake.py")).is_equal_to(["fake.py:2 in glue"])


@pytest.mark.parametrize(
    ("source", "offending"),
    [
        pytest.param(
            'def body(sections):\n    return "\\n".join(sections)\n\n'
            "def main(raw):\n    print(body(raw))\n",
            ["fake.py:5 in main"],
            id="caller-sections-is-not-a-safe-return",
        ),
        pytest.param(
            "def body(raw):\n    value = raw\n    if raw:\n        value = 'fixed'\n"
            "    return value\n\ndef main(raw):\n    print(body(raw))\n",
            ["fake.py:8 in main"],
            id="return-safe-on-one-branch-only",
        ),
        pytest.param(
            "def body(raw):\n    if raw:\n        return 'fixed'\n    return raw\n\n"
            "def main(raw):\n    print(body(raw))\n",
            ["fake.py:7 in main"],
            id="one-unsafe-return",
        ),
        pytest.param(
            "CACHE = ['x']\n\ndef load(p):\n    CACHE[0] = open(p).read()\n\n"
            'def fmt():\n    return "\\n".join(CACHE)\n\n'
            "def main():\n    print(fmt())\n",
            ["fake.py:10 in main"],
            id="module-list-filled-by-another-function",
        ),
        pytest.param(
            "CACHE = ['x']\n\ndef load(p):\n    CACHE.append(open(p).read())\n\n"
            "def main():\n    print(CACHE)\n",
            ["fake.py:7 in main"],
            id="module-list-appended-by-another-function",
        ),
        pytest.param(
            "class A:\n    def fmt(self):\n        return 'ok'\n\n"
            "def fmt(p):\n    return open(p).read()\n\n"
            "def main(p):\n    print(fmt(p))\n",
            ["fake.py:9 in main"],
            id="method-does-not-stand-in-for-a-function",
        ),
        pytest.param(
            "class A:\n    def fmt(self):\n        return 'ok'\n\n"
            "def main(p):\n    print(fmt(p))\n",
            ["fake.py:6 in main"],
            id="method-alone-is-not-a-module-function",
        ),
        pytest.param(
            "from sys import stdout\n\ndef main(raw):\n    print(raw, file=stdout)\n",
            ["fake.py:4 in main"],
            id="stdout-imported-from-sys",
        ),
        pytest.param(
            "NOTE = 'x'\n\ndef body():\n    sections = [NOTE]\n"
            '    return "\\n".join(sections)\n\n'
            "def main():\n    print(body())\n    print(NOTE)\n",
            [],
            id="own-sections-and-unchanged-constant",
        ),
        pytest.param(
            "def body(raw):\n    if raw:\n        value = 'a'\n    else:\n"
            "        value = comment_sanitize.cell(raw)\n    return value\n\n"
            "def main(raw):\n    print(body(raw))\n",
            [],
            id="return-safe-on-every-branch",
        ),
        pytest.param(
            "def body(sections, flag):\n    if flag:\n        sections = []\n"
            '    return "\\n".join(sections)\n\n'
            "def main(raw):\n    print(body([raw], raw))\n",
            ["fake.py:7 in main"],
            id="sections-created-on-one-path-only",
        ),
        pytest.param(
            "def body(sections, flag):\n    if flag:\n        sections = []\n"
            "    else:\n        sections = ['fixed']\n"
            '    return "\\n".join(sections)\n\n'
            "def main(raw):\n    print(body([raw], raw))\n",
            [],
            id="sections-created-on-every-path",
        ),
        pytest.param(
            SAFE_BODY + "def main(body, raw):\n    print(body(raw))\n",
            ["fake.py:5 in main"],
            id="parameter-shadows-a-safe-function",
        ),
        pytest.param(
            "def body():\n    return 'ok'\n\n"
            "def main(raw):\n    body = str\n    print(body(raw))\n",
            ["fake.py:6 in main"],
            id="local-binding-shadows-a-safe-function",
        ),
        pytest.param(
            "def body():\n    return 'ok'\n\nbody = str\n\n"
            "def main(raw):\n    print(body(raw))\n",
            ["fake.py:7 in main"],
            id="module-binding-shadows-a-safe-function",
        ),
        pytest.param(
            "def main(comment_sanitize, raw):\n    print(comment_sanitize.text(raw))\n",
            ["fake.py:2 in main"],
            id="parameter-shadows-the-sanitiser",
        ),
        pytest.param(
            "def body():\n    return 'ok'\n\ndef main(raw):\n    print(body())\n",
            [],
            id="unshadowed-safe-function",
        ),
    ],
)
def test_python_guard_infers_safe_returns_from_tracked_values(
    source: str,
    offending: list[str],
) -> None:
    """A safe return comes from tracked values on every path (#1692 review)."""
    assert_that(python_offences(source, "fake.py")).is_equal_to(offending)


@pytest.mark.parametrize(
    ("source", "bad"),
    [
        pytest.param(
            "import sys as s\n\ndef main(raw):\n    s.stdout.write(raw)\n",
            True,
            id="sys-alias-stdout",
        ),
        pytest.param(
            "import sys as s\n\ndef main(raw):\n    print(raw, file=s.stderr)\n",
            False,
            id="sys-alias-stderr",
        ),
        pytest.param(
            "def main(raw):\n    p = print\n    p(raw)\n",
            True,
            id="print-alias",
        ),
        pytest.param(
            "from builtins import print as p\n\ndef main(raw):\n    p(raw)\n",
            True,
            id="print-imported-alias",
        ),
        pytest.param(
            'import sys\n\ndef main(raw):\n    getattr(sys.stdout, "write")(raw)\n',
            True,
            id="getattr-stdout-write",
        ),
        pytest.param(
            'import sys\n\ndef main(raw):\n    getattr(sys.stderr, "write")(raw)\n',
            False,
            id="getattr-stderr-write",
        ),
        pytest.param(
            PATH_IMPORT + "def main(raw):\n    Path('c.md').write_text(raw)\n",
            True,
            id="path-write-text",
        ),
        pytest.param(
            "def main(raw):\n    open('c.md', 'w').write(raw)\n",
            True,
            id="open-write",
        ),
        pytest.param(
            "def main(raw):\n    with open('c.md', 'w') as f:\n        f.write(raw)\n",
            True,
            id="with-open-write",
        ),
        pytest.param(
            "def main(raw):\n    f = open('c.md', 'w')\n    print(raw, file=f)\n",
            True,
            id="print-to-an-opened-file",
        ),
        pytest.param(
            "from pathlib import Path\n\ndef main(raw):\n"
            "    Path('c.md').write_text(comment_sanitize.text(raw))\n",
            False,
            id="path-write-text-of-sanitised",
        ),
        pytest.param(
            "def main(raw):\n    with open('c.md', 'w') as f:\n"
            "        f.write(comment_sanitize.text(raw))\n",
            False,
            id="with-open-write-of-sanitised",
        ),
    ],
)
def test_python_guard_follows_every_way_out(source: str, bad: bool) -> None:
    """Aliases of sys, stdout and print, getattr and file writes are output."""
    assert_that(bool(python_offences(source, "fake.py"))).is_equal_to(bad)


def test_python_guard_does_not_trust_an_argument_shadowing_a_constant() -> None:
    """A parameter named like a module constant holds the caller's value."""
    body = "    sections.append(NOTE)\n"
    for signature in ("def build(NOTE, sections):", "def build(sections, *, NOTE):"):
        source = f"NOTE = 'constant'\n\n{signature}\n{body}"
        assert_that(python_offences(source, "fake.py")).is_not_empty()
