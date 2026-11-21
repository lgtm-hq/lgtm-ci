#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Read the line and branch rates of one untrusted Cobertura XML file (#1692).

Runs as ``python3 -I`` from the tooling checkout on any runner ``python3``
(3.10 on ubuntu-22.04): standard library only. ``extract.sh`` calls it for
every Cobertura report, so the comment, the summary, the merge, the threshold
check and the badge read the same two numbers.

Output, one line: ``LINE BRANCH``, each a percentage with two decimals,
``absent`` (the root element has no such attribute) or ``invalid``. The rates
are the ``line-rate`` and ``branch-rate`` attributes of the document root,
which must be a single ``<coverage>`` element; nested elements, comments,
CDATA and other attributes are never read. A present rate must be a decimal
from 0 to 1, written plainly or in scientific notation (coverage.py writes
``%.4g``, so ``1.234e-05`` is a real rate of 0.001234%, which rounds to
0.00); an empty, signed or malformed rate, or one above 1, is invalid. A file
that is not well-formed XML, or not such a document, gives ``invalid
invalid`` and a reason on stderr. The exit status is 0 whenever a line was
printed, 2 on a usage error. With ``--raw`` each readable rate is printed as
written instead of as a percentage (``run-bats-tests.sh`` keeps its own
rounding of kcov's rate; #1692 review).

Safety: the text checks of ``junit_cases.py`` (strict UTF-8, no NUL byte, no
other declared encoding) and its expat setup (parameter entities never read,
every entity declaration, notation, external or skipped entity reference
refused), shared through ``check_prolog`` and ``safe_parser``. The
one difference: kcov v43, the pinned version, writes
``<!DOCTYPE coverage SYSTEM 'http://cobertura.sourceforge.net/xml/coverage-04.dtd'>``
(src/writers/cobertura-writer.cc), and Java Cobertura and gcovr write the
same form. Exactly that inert form is accepted: the name ``coverage``, a
``SYSTEM`` identifier from ``COBERTURA_DTDS``, no public identifier and no
internal subset. It is never resolved or fetched. Any other DOCTYPE is
refused.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

HERE = str(Path(__file__).resolve().parent)
if HERE not in sys.path:  # python3 -I leaves this directory off sys.path
    sys.path.insert(0, HERE)

import junit_cases  # noqa: E402  # pylint: disable=wrong-import-position
from junit_cases import Unreadable, safe_name  # noqa: E402  # pylint: disable=wrong-import-position

#: Coverage reports are larger than JUnit files; the whole file is read once.
MAX_FILE_BYTES = 256 * 1024 * 1024
MAX_DEPTH = 64
#: The DTD system identifiers Cobertura producers write; never fetched.
COBERTURA_DTDS = frozenset(
    {
        "http://cobertura.sourceforge.net/xml/coverage-03.dtd",
        "http://cobertura.sourceforge.net/xml/coverage-04.dtd",
        "https://cobertura.sourceforge.net/xml/coverage-03.dtd",
        "https://cobertura.sourceforge.net/xml/coverage-04.dtd",
        "https://raw.githubusercontent.com/cobertura/web/master/htdocs/xml/coverage-04.dtd",
    },
)
_RATE = re.compile(r"[0-9]{1,6}(?:\.[0-9]{1,20})?(?:[eE][-+]?[0-9]{1,3})?")
#: XML's S production (#1692): Python's ``\s`` also matches a vertical tab
#: or a no-break space, which XML does not allow between declaration tokens.
_XML_SPACE = r"[ \t\r\n]"
_DOCTYPE = re.compile(
    rf"<!DOCTYPE{_XML_SPACE}+coverage{_XML_SPACE}+SYSTEM{_XML_SPACE}+"
    rf"""(["'])([^"'<>\[\]]*)\1{_XML_SPACE}*>""",
)
_ATTRIBUTES = ("line-rate", "branch-rate")
_NOT_COBERTURA_DTD = "the report declares a DOCTYPE that is not the Cobertura DTD"


class _InertDoctype:  # pylint: disable=too-few-public-methods
    """Prolog hook: allow ``<!DOCTYPE coverage SYSTEM '<known DTD>'>``.

    It records where the declaration is, so ``read_rates`` can blank it
    before parsing, and refuses a second one.
    """

    def __init__(self) -> None:
        self.spans: list[tuple[int, int]] = []

    def __call__(self, text: str, pos: int) -> int:
        """Judge the declaration at ``pos``; return the position after it."""
        inert = _DOCTYPE.match(text, pos)
        # One DOCTYPE only: once blanked, expat could no longer see a second.
        if not inert or inert.group(2) not in COBERTURA_DTDS or self.spans:
            raise Unreadable(_NOT_COBERTURA_DTD)
        self.spans.append(inert.span())
        return inert.end()


def _blanked(text: str, spans: list[tuple[int, int]]) -> bytes:
    """Return ``text`` as UTF-8 with each span replaced by spaces.

    Without the DOCTYPE, expat parses a document with no DTD at all, where an
    undeclared entity reference (``&r;``) is a well-formedness error in an
    attribute value as much as in content. With the DOCTYPE's external subset
    in place, expat silently drops such a reference from an attribute value
    (``line-rate="&r;1"`` read as ``1``) without calling any handler (#1692).
    """
    for start, end in spans:
        text = text[:start] + " " * (end - start) + text[end:]
    return text.encode("utf-8")


def _doctype(
    name: str,
    system_id: str | None,
    public_id: str | None,
    subset: int,
) -> None:
    """Expat handler: allow only the inert Cobertura DOCTYPE."""
    inert = name == "coverage" and public_id is None and not subset
    if not inert or system_id not in COBERTURA_DTDS:
        raise Unreadable(_NOT_COBERTURA_DTD)


class _Root:  # pylint: disable=too-few-public-methods
    """Expat start handler that keeps the root element's rates."""

    def __init__(self) -> None:
        self.depth = 0
        self.rates: dict[str, str] | None = None

    def start(self, name: str, attrs: dict[str, str]) -> None:
        """Handle an element start."""
        self.depth += 1
        if self.depth > MAX_DEPTH:
            raise Unreadable(f"elements nested deeper than {MAX_DEPTH}")
        if self.rates is None:
            if name != "coverage":
                raise Unreadable(f"root element <{safe_name(name)}> is not <coverage>")
            self.rates = {key: attrs[key] for key in _ATTRIBUTES if key in attrs}

    def end(self, _name: str) -> None:
        """Handle an element end."""
        self.depth -= 1


def read_rates(path: Path) -> dict[str, str]:
    """Return the root's rate attributes as written; raise Unreadable otherwise."""
    with path.open("rb") as handle:
        raw = handle.read(MAX_FILE_BYTES + 1)
    if len(raw) > MAX_FILE_BYTES:
        raise Unreadable(f"larger than {MAX_FILE_BYTES} bytes")
    text = junit_cases.decode_strict(raw)
    inert = _InertDoctype()
    junit_cases.check_prolog(text, inert)
    root = _Root()
    doctype: Any = _doctype
    parser = junit_cases.safe_parser(root.start, root.end, doctype)
    junit_cases.parse_strict(parser, _blanked(text, inert.spans))
    if root.rates is None:
        raise Unreadable("no <coverage> element")
    return root.rates


def percent(rate: str | None) -> str:
    """Return a rate as a percentage with two decimals, ``absent`` or ``invalid``."""
    if rate is None:
        return "absent"
    if not _RATE.fullmatch(rate):
        return "invalid"
    value = float(rate)
    return f"{value * 100:.2f}" if 0 <= value <= 1 else "invalid"


def as_written(rate: str | None) -> str:
    """Return a rate as written when it is readable, else ``absent``/``invalid``."""
    shown = percent(rate)
    return rate if rate is not None and shown not in {"absent", "invalid"} else shown


def main(argv: list[str]) -> int:
    """Print ``LINE BRANCH`` for the file named in ``argv``."""
    show = percent
    if len(argv) == 3 and argv[1] == "--raw":
        show, argv = as_written, [argv[0], argv[2]]
    if len(argv) != 2:
        print("usage: cobertura_rates.py [--raw] <coverage.xml>", file=sys.stderr)
        return 2
    try:
        rates = read_rates(Path(argv[1]))
    except (Unreadable, OSError) as error:
        reason = "cannot be read"
        if isinstance(error, Unreadable):
            reason = safe_name(str(error))
        print(f"Cobertura report unreadable: {reason}", file=sys.stderr)
        print("invalid invalid")
        return 0
    print(" ".join(show(rates.get(key)) for key in _ATTRIBUTES))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
