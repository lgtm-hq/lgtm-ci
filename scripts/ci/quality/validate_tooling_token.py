#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check how reusable workflows handle the optional tooling token (#1451).

Usage: validate_tooling_token.py --workflows-dir DIR --actions-dir DIR
           [--allowlist FILE]

A private mirror of this repository needs a credential for the tooling
checkout, so a converted reusable takes the optional secret
``LGTM_CI_TOOLING_TOKEN`` and hands it to that checkout and to nothing else.
Each violation is printed as ``file:line: [rule] message``:

- ``token``: a checkout with ``path: .lgtm-ci-tooling`` must carry
  ``token: ${{ secrets.LGTM_CI_TOOLING_TOKEN || github.token }}`` and
  ``persist-credentials: false``.
- ``composite-call``: a ``checkout-and-harden`` call must pass
  ``tooling-token: ${{ secrets.LGTM_CI_TOOLING_TOKEN }}``.
- ``declaration``: a file that does either must declare the secret under
  ``on.workflow_call.secrets`` with ``required: false``.
- ``forward``: a nested ``uses: ./.github/workflows/...`` call whose target
  declares the secret must forward it explicitly (no ``secrets: inherit``).
- ``leak``: the secret name may appear nowhere else in the file.
- ``composite``: in ``checkout-and-harden/action.yml`` only the tooling
  checkout's ``token:`` may read ``inputs.tooling-token``.
- ``allowlist``: the allowlist names reusables that are not converted yet. An
  entry that is already converted, or that names no file, is an error, so the
  list can only shrink.

Allowlisted files are exempt from every rule except ``leak``. The workflows
are read line by line because the scripts under ``scripts/ci`` use the
standard library only.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

SECRET = "LGTM_CI_TOOLING_TOKEN"  # nosec B105 - a secret's name, not its value
INPUT = "tooling-token"
TOOLING_PATH = ".lgtm-ci-tooling"
COMPOSITE = "checkout-and-harden"
TOKEN_EXPR = "${{ secrets." + SECRET + " || github.token }}"
FORWARD_EXPR = "${{ secrets." + SECRET + " }}"
COMPOSITE_TOKEN_EXPR = "${{ inputs." + INPUT + " || github.token }}"
NESTED_PREFIX = "./.github/workflows/"

KEY_LINE = re.compile(
    r"^(?P<indent> *)(?P<dash>- +)?(?P<key>['\"]?[A-Za-z_][\w.-]*['\"]?):"
    r"(?:[ \t]+(?P<value>.*))?$",
)
BLOCK_SCALAR = re.compile(r"^[|>][+-]?\d*[+-]?\s*(#.*)?$")
INPUT_READ = re.compile(
    r"inputs\s*(?:\.\s*" + INPUT + r"(?![\w-])|\[\s*['\"]" + INPUT + r"['\"]\s*\])",
)
WHOLE_CONTEXT = re.compile(r"tojson\(\s*(?P<context>secrets|inputs)\s*\)", re.I)


@dataclass(frozen=True)
class Line:
    """One ``key: value`` line of a YAML file.

    Attributes:
        number: 1-based line number in the file.
        col: Column of the key (after a leading ``- `` when there is one).
        dash: Whether the line opens a sequence item.
        key: The mapping key, unquoted.
        value: The text after the colon, stripped, or an empty string.
    """

    number: int
    col: int
    dash: bool
    key: str
    value: str


@dataclass(frozen=True, order=True)
class Finding:
    """One violation.

    Attributes:
        file: File name as printed to the reader.
        line: 1-based line number.
        rule: Rule slug from the module docstring.
        message: What is wrong and what is expected.
    """

    file: str
    line: int
    rule: str
    message: str

    def render(self) -> str:
        """Return the violation as ``file:line: [rule] message``."""
        return f"{self.file}:{self.line}: [{self.rule}] {self.message}"


@dataclass(frozen=True)
class Report:
    """What one reusable workflow yields.

    Attributes:
        conversion: Violations of the rules an allowlisted file is exempt from.
        leaks: Violations of the ``leak`` rule, which always applies.
        uses_tooling: Whether the file has anything the token applies to.
    """

    conversion: list[Finding]
    leaks: list[Finding]
    uses_tooling: bool


def unquote(value: str) -> str:
    """Strip one pair of matching quotes from a scalar.

    Args:
        value: Raw scalar text.

    Returns:
        str: The scalar without surrounding quotes or whitespace.
    """
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def parse(text: str) -> list[Line]:
    """Return the ``key: value`` lines of a YAML document.

    Comments, blank lines and the content of block scalars (``run: |``) are
    left out, so a script that prints ``uses:`` is not read as a step.

    Args:
        text: The file content.

    Returns:
        list[Line]: Key lines in file order.
    """
    lines: list[Line] = []
    scalar_col: int | None = None
    for number, raw in enumerate(text.splitlines(), start=1):
        stripped = raw.strip()
        if not stripped:
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if scalar_col is not None:
            if indent > scalar_col:
                continue
            scalar_col = None
        if stripped.startswith("#"):
            continue
        match = KEY_LINE.match(raw)
        if not match:
            continue
        col = indent + len(match.group("dash") or "")
        value = (match.group("value") or "").strip()
        if BLOCK_SCALAR.match(value):
            scalar_col = col
        lines.append(
            Line(
                number=number,
                col=col,
                dash=bool(match.group("dash")),
                key=unquote(match.group("key")),
                value=value,
            ),
        )
    return lines


def children(lines: list[Line], index: int) -> dict[str, int]:
    """Return the direct child keys of the mapping at ``index``.

    Args:
        lines: Parsed key lines.
        index: Position of the parent key.

    Returns:
        dict[str, int]: Child key to its position; the first one wins.
    """
    found: dict[str, int] = {}
    parent = lines[index].col
    child_col: int | None = None
    for position in range(index + 1, len(lines)):
        line = lines[position]
        if line.col <= parent:
            break
        if child_col is None:
            child_col = line.col
        if line.col == child_col:
            found.setdefault(line.key, position)
    return found


def siblings(lines: list[Line], index: int) -> dict[str, int]:
    """Return the keys of the mapping that holds the line at ``index``.

    For a step this is the step; for a job-level ``uses:`` it is the job.

    Args:
        lines: Parsed key lines.
        index: Position of any key of the mapping.

    Returns:
        dict[str, int]: Sibling key to its position; the first one wins.
    """
    col = lines[index].col

    def opens_item(position: int) -> bool:
        return lines[position].dash and lines[position].col == col

    start = index
    while not opens_item(start) and start > 0 and lines[start - 1].col >= col:
        start -= 1
    end = index + 1
    while end < len(lines) and lines[end].col >= col and not opens_item(end):
        end += 1
    found: dict[str, int] = {}
    for position in range(start, end):
        if lines[position].col == col:
            found.setdefault(lines[position].key, position)
    return found


def child_of(lines: list[Line], keys: dict[str, int], name: str) -> dict[str, int]:
    """Return the children of ``keys[name]``, or nothing when it is absent.

    Args:
        lines: Parsed key lines.
        keys: A mapping's keys, as returned by :func:`siblings`.
        name: The key to descend into.

    Returns:
        dict[str, int]: Child key to its position.
    """
    return children(lines, keys[name]) if name in keys else {}


def is_tooling_checkout(lines: list[Line], uses: str, inputs: dict[str, int]) -> bool:
    """Tell whether a step checks out the tooling.

    Args:
        lines: Parsed key lines.
        uses: The step's ``uses:`` target.
        inputs: The step's ``with:`` keys.

    Returns:
        bool: True for ``actions/checkout`` with ``path: .lgtm-ci-tooling``.
    """
    if not uses.startswith("actions/checkout@") or "path" not in inputs:
        return False
    path = unquote(lines[inputs["path"]].value).removeprefix("./").rstrip("/")
    return path == TOOLING_PATH


def declaration(lines: list[Line]) -> tuple[int | None, bool]:
    """Find the secret under ``on.workflow_call.secrets``.

    Args:
        lines: Parsed key lines of a workflow.

    Returns:
        tuple[int | None, bool]: Position of the declaration (None when the
        secret is not declared) and whether it says ``required: false``.
    """
    for index, line in enumerate(lines):
        if line.key != "workflow_call":
            continue
        secrets = child_of(lines, children(lines, index), "secrets")
        if SECRET not in secrets:
            return None, False
        fields = children(lines, secrets[SECRET])
        required = lines[fields["required"]].value if "required" in fields else ""
        optional = unquote(required) == "false"
        return secrets[SECRET], optional
    return None, False


def declares(path: Path) -> bool | None:
    """Tell whether a workflow file declares the secret.

    Args:
        path: The workflow file.

    Returns:
        bool | None: None when the file does not exist.
    """
    if not path.is_file():
        return None
    return declaration(parse(path.read_text()))[0] is not None


class WorkflowCheck:
    """Collects the violations of one reusable workflow.

    Args:
        path: The reusable workflow file, read and parsed on construction.
    """

    def __init__(self, path: Path) -> None:
        self.path = path
        self.text = path.read_text()
        self.lines = parse(self.text)
        self.findings: list[Finding] = []
        self.allowed: set[int] = set()
        self.first_use: int | None = None

    def fail(self, line: int, rule: str, message: str) -> None:
        """Record a violation.

        Args:
            line: 1-based line number.
            rule: Rule slug.
            message: What is wrong and what is expected.
        """
        self.findings.append(
            Finding(file=self.path.name, line=line, rule=rule, message=message),
        )

    def expect(
        self,
        *,
        keys: dict[str, int],
        name: str,
        expected: str,
        anchor: Line,
        rule: str,
    ) -> None:
        """Require ``name: expected`` among ``keys``.

        Args:
            keys: The keys of a ``with:`` or ``secrets:`` mapping.
            name: The key that must be present.
            expected: The exact value it must have.
            anchor: The line to report when the key is missing.
            rule: Rule slug for the violation.
        """
        if name not in keys:
            self.fail(anchor.number, rule, f"missing `{name}: {expected}`")
            return
        line = self.lines[keys[name]]
        if unquote(line.value) != expected:
            self.fail(
                line.number,
                rule,
                f"`{name}` must be exactly `{expected}`, found `{line.value}`",
            )

    def allow(self, keys: dict[str, int], name: str) -> None:
        """Let the secret name appear on the line of ``keys[name]``.

        Args:
            keys: The keys of a mapping.
            name: The key whose line may name the secret.
        """
        if name in keys:
            self.allowed.add(self.lines[keys[name]].number)

    def check_checkout(self, line: Line, inputs: dict[str, int]) -> None:
        """Apply the ``token`` rule to one tooling checkout.

        Args:
            line: The step's ``uses:`` line.
            inputs: The step's ``with:`` keys.
        """
        self.allow(inputs, "token")
        for name, expected in (("token", TOKEN_EXPR), ("persist-credentials", "false")):
            self.expect(
                keys=inputs,
                name=name,
                expected=expected,
                anchor=line,
                rule="token",
            )

    def check_composite_call(self, line: Line, inputs: dict[str, int]) -> None:
        """Apply the ``composite-call`` rule to one ``checkout-and-harden`` step.

        Args:
            line: The step's ``uses:`` line.
            inputs: The step's ``with:`` keys.
        """
        self.allow(inputs, INPUT)
        self.expect(
            keys=inputs,
            name=INPUT,
            expected=FORWARD_EXPR,
            anchor=line,
            rule="composite-call",
        )

    def check_nested(self, line: Line, target: str, keys: dict[str, int]) -> bool:
        """Apply the ``forward`` rule to one nested reusable call.

        Args:
            line: The job's ``uses:`` line.
            target: File name of the called workflow.
            keys: The job's keys.

        Returns:
            bool: Whether the call takes, or should take, the secret.
        """
        declared = declares(self.path.parent / target)
        forwarded = child_of(self.lines, keys, "secrets")
        self.allow(forwarded, SECRET)
        if SECRET in forwarded and declared is False:
            self.fail(
                self.lines[forwarded[SECRET]].number,
                "forward",
                f"forwards {SECRET} to {target}, which does not declare it",
            )
            return True
        if not declared:
            return SECRET in forwarded
        inherit = "secrets" in keys and self.lines[keys["secrets"]].value
        if inherit and unquote(inherit) == "inherit":
            self.fail(
                self.lines[keys["secrets"]].number,
                "forward",
                f"`secrets: inherit` is not accepted; forward {SECRET} to {target}",
            )
            return True
        self.expect(
            keys=forwarded,
            name=SECRET,
            expected=FORWARD_EXPR,
            anchor=line,
            rule="forward",
        )
        return True

    def check_declaration(self) -> None:
        """Apply the ``declaration`` rule once every use is known."""
        index, optional = declaration(self.lines)
        if index is not None:
            line = self.lines[index]
            self.allowed.add(line.number)
            if not optional:
                self.fail(
                    line.number,
                    "declaration",
                    f"secret {SECRET} must be declared with `required: false`",
                )
        elif self.first_use is not None:
            self.fail(
                self.first_use,
                "declaration",
                f"uses the tooling token but does not declare secret {SECRET} "
                "under on.workflow_call.secrets with `required: false`",
            )

    def leaks(self) -> list[Finding]:
        """Apply the ``leak`` rule to every line that is not a comment.

        Returns:
            list[Finding]: One violation per line that names the secret
            outside the places the other rules allow.
        """
        found: list[Finding] = []
        declared = declaration(self.lines)[0] is not None
        for number, raw in enumerate(self.text.splitlines(), start=1):
            if raw.lstrip().startswith("#"):
                continue
            whole = WHOLE_CONTEXT.search(raw)
            if SECRET in raw and number not in self.allowed:
                message = (
                    f"{SECRET} may only be declared, passed to the tooling "
                    f"checkout's `token`, to {COMPOSITE}'s `{INPUT}` and to a "
                    "nested reusable's `secrets`"
                )
            elif declared and whole and whole.group("context").lower() == "secrets":
                message = "toJSON(secrets) would expose the tooling token"
            else:
                continue
            found.append(
                Finding(file=self.path.name, line=number, rule="leak", message=message),
            )
        return found

    def run(self) -> Report:
        """Check the whole workflow.

        Returns:
            Report: The violations, split by whether the allowlist exempts
            them, and whether the file uses the tooling at all.
        """
        for index, line in enumerate(self.lines):
            if line.key != "uses" or not line.value:
                continue
            uses = unquote(line.value.split(" #")[0])
            keys = siblings(self.lines, index)
            inputs = child_of(self.lines, keys, "with")
            used = True
            if is_tooling_checkout(self.lines, uses, inputs):
                self.check_checkout(line, inputs)
            elif uses.endswith(f"/.github/actions/{COMPOSITE}"):
                self.check_composite_call(line, inputs)
            elif uses.startswith(NESTED_PREFIX):
                target = uses.removeprefix(NESTED_PREFIX)
                used = self.check_nested(line, target, keys)
            else:
                used = False
            if used and self.first_use is None:
                self.first_use = line.number
        self.check_declaration()
        return Report(
            conversion=self.findings,
            leaks=self.leaks(),
            uses_tooling=self.first_use is not None,
        )


def check_composite(action: Path) -> list[Finding]:
    """Apply the ``composite`` rule to ``checkout-and-harden/action.yml``.

    Args:
        action: The composite's ``action.yml``.

    Returns:
        list[Finding]: The violations found.
    """
    name = f"{COMPOSITE}/{action.name}"
    if not action.is_file():
        return [Finding(file=name, line=1, rule="composite", message="file not found")]
    text = action.read_text()
    lines = parse(text)
    findings: list[Finding] = []

    def fail(line: int, message: str) -> None:
        finding = Finding(file=name, line=line, rule="composite", message=message)
        findings.append(finding)

    allowed: set[int] = set()
    checkouts = 0
    for index, line in enumerate(lines):
        if (
            line.key == "inputs"
            and line.col == 0
            and INPUT
            not in children(
                lines,
                index,
            )
        ):
            fail(line.number, f"input `{INPUT}` is not declared")
        if line.key != "uses" or not line.value:
            continue
        inputs = child_of(lines, siblings(lines, index), "with")
        if not is_tooling_checkout(lines, unquote(line.value.split(" #")[0]), inputs):
            continue
        checkouts += 1
        for key, expected in (
            ("token", COMPOSITE_TOKEN_EXPR),
            ("persist-credentials", "false"),
        ):
            if key not in inputs:
                fail(line.number, f"tooling checkout is missing `{key}: {expected}`")
                continue
            found = lines[inputs[key]]
            if key == "token":
                allowed.add(found.number)
            if unquote(found.value) != expected:
                fail(
                    found.number,
                    f"`{key}` must be exactly `{expected}`, found `{found.value}`",
                )
    if not checkouts:
        fail(1, f"no checkout with `path: {TOOLING_PATH}` found")
    for number, raw in enumerate(text.splitlines(), start=1):
        if raw.lstrip().startswith("#") or number in allowed:
            continue
        whole = WHOLE_CONTEXT.search(raw)
        context = whole.group("context").lower() if whole else ""
        if INPUT_READ.search(raw) or context == "inputs":
            fail(
                number,
                f"only the tooling checkout's `token:` may read inputs.{INPUT}",
            )
    return findings


def read_allowlist(path: Path | None) -> tuple[dict[str, int], list[Finding]]:
    """Read the allowlist of reusables that are not converted yet.

    Args:
        path: The allowlist file, or None when there is none.

    Returns:
        tuple[dict[str, int], list[Finding]]: Entry to its line number, and
        the violations of the file's own format (order, duplicates).
    """
    entries: dict[str, int] = {}
    findings: list[Finding] = []
    if path is None:
        return entries, findings
    previous = ""
    for number, raw in enumerate(path.read_text().splitlines(), start=1):
        entry = raw.strip()
        if not entry or entry.startswith("#"):
            continue
        if entry in entries:
            message = f"duplicate entry {entry}"
        elif entry < previous:
            message = f"entries must be sorted; {entry} follows {previous}"
        else:
            message = ""
        if message:
            findings.append(
                Finding(file=path.name, line=number, rule="allowlist", message=message),
            )
        entries.setdefault(entry, number)
        previous = entry
    return entries, findings


def validate(
    *,
    workflows_dir: Path,
    actions_dir: Path,
    allowlist: Path | None,
) -> tuple[list[Finding], int, int]:
    """Check every reusable workflow and the composite.

    Args:
        workflows_dir: Directory holding the ``reusable-*.yml`` files.
        actions_dir: Directory holding the composite actions.
        allowlist: File naming the reusables not converted yet, or None.

    Returns:
        tuple[list[Finding], int, int]: The violations, the number of
        converted reusables and the number of allowlisted ones.
    """
    entries, findings = read_allowlist(allowlist)
    listed = allowlist.name if allowlist else ""
    findings += check_composite(actions_dir / COMPOSITE / "action.yml")
    converted = 0
    seen: set[str] = set()
    for workflow in sorted(workflows_dir.glob("reusable-*.yml")):
        report = WorkflowCheck(workflow).run()
        findings += report.leaks
        seen.add(workflow.name)
        if workflow.name not in entries:
            findings += report.conversion
            converted += report.uses_tooling
        elif not report.conversion:
            state = "is already converted" if report.uses_tooling else "has no tooling"
            findings.append(
                Finding(
                    file=listed,
                    line=entries[workflow.name],
                    rule="allowlist",
                    message=f"{workflow.name} {state}; remove the entry",
                ),
            )
    findings += [
        Finding(
            file=listed,
            line=number,
            rule="allowlist",
            message=f"{entry} does not exist in {workflows_dir.name}; remove the entry",
        )
        for entry, number in entries.items()
        if entry not in seen
    ]
    return sorted(findings), converted, len(entries)


def main(argv: list[str] | None = None) -> int:
    """Run the check from the command line.

    Args:
        argv: Arguments after the program name; ``sys.argv`` when None.

    Returns:
        int: 0 when the contract holds, 1 on a violation, 2 on a bad path.
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--workflows-dir", type=Path, required=True)
    parser.add_argument("--actions-dir", type=Path, required=True)
    parser.add_argument("--allowlist", type=Path, default=None)
    args = parser.parse_args(argv)
    for label, directory in (
        ("workflows", args.workflows_dir),
        ("actions", args.actions_dir),
    ):
        if not directory.is_dir():
            print(f"ERROR: {label} directory not found: {directory}", file=sys.stderr)
            return 2
    if args.allowlist is not None and not args.allowlist.is_file():
        print(f"ERROR: allowlist not found: {args.allowlist}", file=sys.stderr)
        return 2
    findings, converted, allowlisted = validate(
        workflows_dir=args.workflows_dir,
        actions_dir=args.actions_dir,
        allowlist=args.allowlist,
    )
    if findings:
        print("ERROR: tooling token contract violations:", file=sys.stderr)
        for finding in findings:
            print(f"  - {finding.render()}", file=sys.stderr)
        return 1
    print(
        f"OK: tooling token contract satisfied ({converted} converted, "
        f"{allowlisted} allowlisted)",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
