#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate documented caller ``permissions:`` against reusable workflow unions.

GitHub validates a reusable workflow's ``permissions:`` request statically,
before any job ``if:`` runs: the caller job must grant at least the union of
every scope declared across the called workflow's jobs. A documented snippet
that grants less is a ``startup_failure`` for whoever copies it (#731, #735).

For every ``uses: lgtm-hq/lgtm-ci/.github/workflows/<file>.yml`` call in
``examples/**``, ``docs/**`` and ``README.md`` this script:

1. computes the called workflow's declared union (workflow-level block plus
   every job-level block, nested ``./.github/workflows`` calls included,
   ``write`` outranking ``read``);
2. extracts the ``permissions:`` block governing the call (the enclosing
   job's block, else the workflow-level block of a complete snippet);
3. fails unless the governing block is a superset of the union.

Composite actions with their own token needs are derived too: a job whose
steps use ``lgtm-hq/lgtm-ci/.github/actions/detect-changes`` must grant
``contents: read`` and ``pull-requests: read`` (#669).

Snippet classes (docs/README.md "Caller snippets and permissions"):

* A **complete** snippet has a top-level ``jobs:`` key. Every call in it must
  carry the block; a missing block always fails.
* A **fragment** has no top-level ``jobs:``. It may omit the block only when
  the fence is visibly marked ``permissions omitted for brevity`` (in the
  prose line directly above it, or a comment inside it). An unmarked
  blockless fragment fails: silent omissions are how the drift survived.

Standard library only, so the check runs in any minimal container.

Usage:
    validate-caller-permissions.py [--repo-root DIR] [PATH ...]
    validate-caller-permissions.py --union reusable-test-python.yml
"""

# pylint: disable=invalid-name  # CLI script; hyphenated filename is the contract

from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Iterator
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_SCAN_PATHS = ("docs", "examples", "README.md")
WORKFLOWS_SUBDIR = Path(".github") / "workflows"

LEVEL_RANK = {"none": 0, "read": 1, "write": 2}
ALL_SCOPES = (
    "actions",
    "attestations",
    "checks",
    "contents",
    "deployments",
    "discussions",
    "id-token",
    "issues",
    "models",
    "packages",
    "pages",
    "pull-requests",
    "repository-projects",
    "security-events",
    "statuses",
)

# Composite actions whose steps authenticate with GITHUB_TOKEN and therefore
# need scopes on the job that runs them. detect-changes wraps
# dorny/paths-filter, which reads the PR files API on pull_request events
# (#669).
ACTION_REQUIREMENTS: dict[str, dict[str, str]] = {
    "detect-changes": {"contents": "read", "pull-requests": "read"},
}

FRAGMENT_MARKER = re.compile(r"permissions omitted for brevity", re.IGNORECASE)
WORKFLOW_PREFIX = r"^uses:\s*[\"']?(?:\./|lgtm-hq/lgtm-ci/)\.github/workflows/"
WORKFLOW_USES = re.compile(WORKFLOW_PREFIX + r"(?P<name>[\w.-]+\.ya?ml)")
# `$/` is GitHub's self-repository form for nested composite references
# (#1089), alongside the tooling checkout path and the external form.
ACTION_USES = re.compile(
    r"^(?:-\s*)?uses:\s*[\"']?(?:\./\.lgtm-ci-tooling/|lgtm-hq/lgtm-ci/|\$/)"
    r"\.github/actions/(?P<name>[\w-]+)",
)
KEY_LINE = re.compile(r"^(?P<key>[\w.-]+):(?P<value>.*)$")
SCOPE_LINE = re.compile(
    r"^(?P<scope>[a-z-]+):\s*[\"']?(?P<level>read|write|none)[\"']?$",
)
FENCE = re.compile(r"^(?P<indent> *)(?P<fence>`{3,}|~{3,})(?P<info>.*)$")
CLOSING_FENCE = re.compile(r"^ *(?P<fence>`{3,}|~{3,}) *$")
TRAILING_COMMENT = re.compile(r"\s+#.*$")

Permissions = dict[str, str]


@dataclass(frozen=True)
class Line:
    """One significant YAML line.

    Attributes:
        number: 1-based line number in the containing file.
        indent: Count of leading spaces.
        text: Content without indentation or trailing comment.
    """

    number: int
    indent: int
    text: str


@dataclass(frozen=True)
class Snippet:
    """A YAML source to scan: a whole file or one fenced block.

    Attributes:
        path: Repo-relative path of the containing file.
        lines: Significant lines, numbered against the file.
        complete: Whether the source has a top-level ``jobs:`` key.
        marked: Whether the fence carries the brevity marker.
    """

    path: str
    lines: list[Line]
    complete: bool
    marked: bool


@dataclass(frozen=True)
class CallSite:
    """One reusable-workflow or action call to check.

    Attributes:
        snippet: Source the call was found in.
        line: The ``uses:`` line.
        target: Name of the called workflow or action.
        required: Scopes the target declares.
        granted: Scopes the caller grants, or None when no block governs.
    """

    snippet: Snippet
    line: Line
    target: str
    required: Permissions
    granted: Permissions | None


@dataclass
class Report:
    """Accumulated validation output.

    Attributes:
        violations: Fatal findings, one line each.
        notices: Non-fatal findings (surplus grants), one line each.
        checked: Number of call sites that were checked.
    """

    violations: list[str] = field(default_factory=list)
    notices: list[str] = field(default_factory=list)
    checked: int = 0


def parse_lines(
    text: str,
    first_line_number: int = 1,
) -> list[Line]:
    """Split YAML text into significant lines.

    Blank lines, comment-only lines and document markers are dropped;
    trailing ``# comments`` are stripped.

    Args:
        text: YAML source.
        first_line_number: File line number of the first line of ``text``.

    Returns:
        Significant lines in order.
    """
    lines: list[Line] = []
    for offset, raw in enumerate(text.splitlines()):
        stripped = raw.strip()
        if not stripped or stripped.startswith("#") or stripped == "---":
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        content = TRAILING_COMMENT.sub("", raw.strip())
        lines.append(
            Line(number=first_line_number + offset, indent=indent, text=content),
        )
    return lines


def merge_permissions(
    target: Permissions,
    source: Permissions,
) -> None:
    """Fold ``source`` into ``target``, keeping the stronger level per scope.

    Args:
        target: Union being built; mutated in place.
        source: Scopes to fold in.
    """
    for scope, level in source.items():
        if LEVEL_RANK[level] > LEVEL_RANK.get(target.get(scope, "none"), 0):
            target[scope] = level


def parse_inline_permissions(
    value: str,
) -> Permissions:
    """Parse the value of a single-line ``permissions:`` entry.

    Args:
        value: Text after ``permissions:``, for example ``{}``, ``read-all``
            or ``{ contents: read }``.

    Returns:
        Scope-to-level mapping.

    Raises:
        ValueError: When the value is not a recognised shorthand or flow map.
    """
    text = value.strip()
    if text in ("read-all", "write-all"):
        level = text.split("-", maxsplit=1)[0]
        return dict.fromkeys(ALL_SCOPES, level)
    if text.startswith("{") and text.endswith("}"):
        scopes: Permissions = {}
        for pair in text[1:-1].split(","):
            if not pair.strip():
                continue
            match = SCOPE_LINE.match(pair.strip())
            if match is None:
                raise ValueError(f"unparseable permissions entry: {pair.strip()!r}")
            scopes[match.group("scope")] = match.group("level")
        return scopes
    raise ValueError(f"unparseable permissions value: {text!r}")


def block_permissions(
    lines: list[Line],
    index: int,
) -> Permissions:
    """Parse the ``permissions`` entry starting at ``lines[index]``.

    Args:
        lines: Significant lines of the source.
        index: Index of the ``permissions:`` line.

    Returns:
        Scope-to-level mapping declared by the block.

    Raises:
        ValueError: When a nested entry is not ``scope: level``.
    """
    head = lines[index]
    value = head.text[len("permissions:") :]
    if value.strip():
        return parse_inline_permissions(value=value)
    scopes: Permissions = {}
    for line in lines[index + 1 :]:
        if line.indent <= head.indent:
            break
        match = SCOPE_LINE.match(line.text)
        if match is None:
            raise ValueError(
                f"line {line.number}: unparseable permissions entry {line.text!r}",
            )
        scopes[match.group("scope")] = match.group("level")
    return scopes


def is_permissions_line(
    line: Line,
) -> bool:
    """Return whether a line opens a ``permissions`` entry.

    Args:
        line: Line to test.

    Returns:
        True for ``permissions:`` in block or inline form.
    """
    return line.text == "permissions:" or line.text.startswith("permissions: ")


def is_top_level(
    line: Line,
    key: str,
) -> bool:
    """Return whether a line is the given top-level mapping key.

    Args:
        line: Line to test.
        key: Key name without the trailing colon.

    Returns:
        True when the line is ``key:`` at indent zero.
    """
    return line.indent == 0 and line.text == f"{key}:"


def key_name(
    line: Line,
) -> str | None:
    """Return the mapping key a line declares, if any.

    Args:
        line: Line to inspect.

    Returns:
        The key, or None for list items and scalars.
    """
    match = KEY_LINE.match(line.text)
    return None if match is None else match.group("key")


def extent_after(
    lines: list[Line],
    start: int,
    parent_indent: int,
) -> int:
    """Return the exclusive end index of the block nested under ``start``.

    Args:
        lines: Significant lines.
        start: Index of the parent key line.
        parent_indent: Indent of the parent key line.

    Returns:
        Index of the first later line at or above ``parent_indent``.
    """
    end = start + 1
    while end < len(lines) and lines[end].indent > parent_indent:
        end += 1
    return end


def job_extent(
    lines: list[Line],
    index: int,
    body_indent: int,
) -> tuple[int, int]:
    """Return the ``[start, end)`` index range of the job containing a line.

    Args:
        lines: Significant lines.
        index: Index of a line at the job body's indent.
        body_indent: Indent of the job body.

    Returns:
        Start index of the first body line and exclusive end index.
    """
    if body_indent == 0:
        return 0, len(lines)
    start = index
    while start > 0 and lines[start - 1].indent >= body_indent:
        start -= 1
    end = index
    while end < len(lines) and lines[end].indent >= body_indent:
        end += 1
    return start, end


def workflow_level_permissions(
    lines: list[Line],
) -> Permissions | None:
    """Return the top-level ``permissions`` block of a workflow, if any.

    Args:
        lines: Significant lines.

    Returns:
        Scope mapping, or None when no top-level block exists.
    """
    for index, line in enumerate(lines):
        if line.indent == 0 and is_permissions_line(line):
            return block_permissions(lines=lines, index=index)
    return None


def iter_jobs(
    lines: list[Line],
) -> Iterator[tuple[str, int, int, int]]:
    """Yield ``(job id, start, end, body indent)`` for each top-level job.

    Args:
        lines: Significant lines of a workflow file.

    Yields:
        Job id, start index of its body, exclusive end index, body indent.
    """
    jobs_index = next(
        (i for i, line in enumerate(lines) if is_top_level(line=line, key="jobs")),
        None,
    )
    if jobs_index is None:
        return
    end_of_jobs = extent_after(lines=lines, start=jobs_index, parent_indent=0)
    index = jobs_index + 1
    while index < end_of_jobs:
        line = lines[index]
        job_id = key_name(line)
        if job_id is None:
            index += 1
            continue
        job_indent = line.indent
        end = extent_after(lines=lines, start=index, parent_indent=job_indent)
        body_indent = min((lines[i].indent for i in range(index + 1, end)), default=0)
        yield job_id, index + 1, end, body_indent
        index = end


def job_requirements(
    lines: list[Line],
    body: list[int],
    workflows_dir: Path,
    seen: frozenset[str],
) -> Permissions:
    """Return the scopes one job of a reusable workflow forces on its caller.

    A job that declares its own block is the boundary GitHub validates a
    nested call against: the nested workflow's union must fit inside this
    block or the reusable itself fails at startup, so the caller only ever
    has to cover the declared block. A job without a block that calls a
    nested workflow forwards that workflow's union instead.

    Args:
        lines: Significant lines of the workflow file.
        body: Indices of the job's body lines at the body indent.
        workflows_dir: Directory holding the workflow files.
        seen: Names already on the nested-call stack (cycle guard).

    Returns:
        Scope mapping the job requires from the caller.
    """
    declared = next((i for i in body if is_permissions_line(lines[i])), None)
    if declared is not None:
        return block_permissions(lines=lines, index=declared)
    matches = (WORKFLOW_USES.match(lines[i].text) for i in body)
    nested = next((match for match in matches if match is not None), None)
    if nested is None or nested.group("name") in seen:
        return {}
    nested_union = workflow_union(
        name=nested.group("name"),
        workflows_dir=workflows_dir,
        seen=seen,
    )
    return nested_union or {}


def workflow_union(
    name: str,
    workflows_dir: Path,
    seen: frozenset[str] = frozenset(),
) -> Permissions | None:
    """Compute the caller-facing permission union of a reusable workflow.

    Args:
        name: Workflow file name, for example ``reusable-test-python.yml``.
        workflows_dir: Directory holding the workflow files.
        seen: Names already on the nested-call stack (cycle guard).

    Returns:
        Scope mapping, or None when the workflow file does not exist.

    Raises:
        ValueError: When a permissions block in the workflow is unparseable;
            the message names the workflow.
    """
    path = workflows_dir / name
    if not path.is_file():
        return None
    lines = parse_lines(text=path.read_text(encoding="utf-8"))
    union: Permissions = {}
    try:
        top = workflow_level_permissions(lines=lines)
        if top is not None:
            merge_permissions(target=union, source=top)
        for _job_id, start, end, body_indent in iter_jobs(lines=lines):
            body = [i for i in range(start, end) if lines[i].indent == body_indent]
            merge_permissions(
                target=union,
                source=job_requirements(
                    lines=lines,
                    body=body,
                    workflows_dir=workflows_dir,
                    seen=seen | {name},
                ),
            )
    except ValueError as exc:
        raise ValueError(f"{WORKFLOWS_SUBDIR / name}: {exc}") from exc
    return union


def governing_permissions(
    snippet: Snippet,
    index: int,
    body_indent: int,
) -> Permissions | None:
    """Return the block that governs the job containing ``lines[index]``.

    Args:
        snippet: Source being scanned.
        index: Index of a job-body line (``uses:`` or ``steps:``).
        body_indent: Indent of the job body.

    Returns:
        The enclosing job's block, else the workflow-level block when the
        snippet is complete, else None.
    """
    start, end = job_extent(lines=snippet.lines, index=index, body_indent=body_indent)
    for i in range(start, end):
        line = snippet.lines[i]
        if line.indent == body_indent and is_permissions_line(line):
            return block_permissions(lines=snippet.lines, index=i)
    if snippet.complete or body_indent == 0:
        return workflow_level_permissions(lines=snippet.lines)
    return None


def format_scopes(
    scopes: Permissions,
) -> str:
    """Render a scope mapping as a stable one-line list.

    Args:
        scopes: Scope-to-level mapping.

    Returns:
        ``scope: level`` pairs, comma separated, sorted by scope.
    """
    rendered = ", ".join(f"{scope}: {level}" for scope, level in sorted(scopes.items()))
    return rendered or "(none)"


def check_site(
    site: CallSite,
    report: Report,
) -> None:
    """Compare one call site's grant against its requirement.

    Args:
        site: The call to check.
        report: Report to append to.
    """
    snippet, target = site.snippet, site.target
    required, granted = site.required, site.granted
    where = f"{snippet.path}:{site.line.number}"
    report.checked += 1
    if granted is None:
        if snippet.marked and not snippet.complete:
            return
        kind = "complete snippet" if snippet.complete else "unmarked fragment"
        report.violations.append(
            f"{where}: {kind} calls {target} with no permissions block "
            f"(required: {format_scopes(required)})",
        )
        return
    missing = {
        scope: level
        for scope, level in required.items()
        if LEVEL_RANK[granted.get(scope, "none")] < LEVEL_RANK[level]
    }
    if missing:
        report.violations.append(
            f"{where}: {target} needs {format_scopes(missing)} "
            f"(documented: {format_scopes(granted)}; "
            f"required: {format_scopes(required)})",
        )
    surplus = {
        scope: level
        for scope, level in granted.items()
        if LEVEL_RANK[level] > LEVEL_RANK[required.get(scope, "none")]
    }
    if surplus:
        report.notices.append(
            f"{where}: {target} grants more than it declares: {format_scopes(surplus)}",
        )


def scan_snippet(
    snippet: Snippet,
    workflows_dir: Path,
    report: Report,
) -> None:
    """Validate every reusable-workflow and action call site in a snippet.

    Args:
        snippet: Source to scan.
        workflows_dir: Directory holding the reusable workflow files.
        report: Report to append to.
    """
    lines = snippet.lines
    for index, line in enumerate(lines):
        workflow = WORKFLOW_USES.match(line.text)
        if workflow is not None:
            name = workflow.group("name")
            required = workflow_union(name=name, workflows_dir=workflows_dir)
            if required is None:
                report.checked += 1
                report.violations.append(
                    f"{snippet.path}:{line.number}: calls {name}, "
                    f"which does not exist under {WORKFLOWS_SUBDIR}",
                )
                continue
            granted = governing_permissions(
                snippet=snippet,
                index=index,
                body_indent=line.indent,
            )
            check_site(
                site=CallSite(
                    snippet=snippet,
                    line=line,
                    target=name,
                    required=required,
                    granted=granted,
                ),
                report=report,
            )
            continue
        action = ACTION_USES.match(line.text)
        if action is None or action.group("name") not in ACTION_REQUIREMENTS:
            continue
        steps_index = next(
            (
                i
                for i in range(index - 1, -1, -1)
                if lines[i].indent <= line.indent and lines[i].text == "steps:"
            ),
            None,
        )
        if steps_index is None:
            continue
        granted = governing_permissions(
            snippet=snippet,
            index=steps_index,
            body_indent=snippet.lines[steps_index].indent,
        )
        check_site(
            site=CallSite(
                snippet=snippet,
                line=line,
                target=f"actions/{action.group('name')}",
                required=ACTION_REQUIREMENTS[action.group("name")],
                granted=granted,
            ),
            report=report,
        )


def is_complete(
    lines: list[Line],
) -> bool:
    """Return whether a YAML source declares a top-level ``jobs:`` key.

    Args:
        lines: Significant lines.

    Returns:
        True when the source is a complete workflow.
    """
    return any(is_top_level(line=line, key="jobs") for line in lines)


def preceded_by_marker(
    raw_lines: list[str],
    fence_index: int,
) -> bool:
    """Return whether the prose directly above a fence carries the marker.

    Up to four non-blank lines above the fence are inspected; markdownlint
    directive comments are skipped so they do not hide the marker, and the
    scan stops at the previous fence so a marker never leaks onto the next
    block.

    Args:
        raw_lines: All lines of the Markdown file.
        fence_index: Index of the opening fence line.

    Returns:
        True when the marker precedes the fence.
    """
    inspected = 0
    for raw in reversed(raw_lines[:fence_index]):
        if not raw.strip() or raw.lstrip().startswith("<!--"):
            continue
        if CLOSING_FENCE.match(raw) or FENCE.match(raw):
            break
        if FRAGMENT_MARKER.search(raw):
            return True
        inspected += 1
        if inspected >= 4:
            break
    return False


def closes_fence(
    raw: str,
    fence: str,
) -> bool:
    """Return whether a line closes a fence opened with ``fence``.

    Args:
        raw: Candidate line.
        fence: The opening fence string (backticks or tildes).

    Returns:
        True for a fence of the same character at least as long as the opener.
    """
    match = CLOSING_FENCE.match(raw)
    if match is None:
        return False
    closing = match.group("fence")
    return closing[0] == fence[0] and len(closing) >= len(fence)


def dedent_fence_line(
    raw: str,
    indent: int,
) -> str:
    """Strip the opening fence's Markdown indentation from a body line.

    Args:
        raw: Body line as written in the Markdown file.
        indent: Indentation of the opening fence.

    Returns:
        The line with up to ``indent`` leading spaces removed.
    """
    leading = len(raw) - len(raw.lstrip(" "))
    return raw[min(indent, leading) :]


def markdown_snippets(
    path: str,
    text: str,
) -> Iterator[Snippet]:
    """Yield every fenced YAML block of a Markdown file.

    Args:
        path: Repo-relative path of the file.
        text: File contents.

    Yields:
        One snippet per ``yaml``/``yml`` fence (backtick or tilde, any info
        string, indentation of the opening fence removed from the body).
    """
    raw_lines = text.splitlines()
    index = 0
    while index < len(raw_lines):
        opening = FENCE.match(raw_lines[index])
        if opening is None:
            index += 1
            continue
        fence = opening.group("fence")
        indent = len(opening.group("indent"))
        info = opening.group("info").split()
        lang = info[0] if info else ""
        end = index + 1
        while end < len(raw_lines) and not closes_fence(raw_lines[end], fence):
            end += 1
        if lang in ("yaml", "yml"):
            fenced = raw_lines[index + 1 : end]
            body = "\n".join(dedent_fence_line(raw, indent) for raw in fenced)
            lines = parse_lines(text=body, first_line_number=index + 2)
            marked = preceded_by_marker(raw_lines=raw_lines, fence_index=index) or any(
                FRAGMENT_MARKER.search(raw) for raw in raw_lines[index + 1 : end]
            )
            yield Snippet(
                path=path,
                lines=lines,
                complete=is_complete(lines),
                marked=marked,
            )
        index = end + 1


def iter_files(
    repo_root: Path,
    scan_paths: list[str],
) -> Iterator[Path]:
    """Yield the files to scan.

    Args:
        repo_root: Repository root.
        scan_paths: Repo-relative files or directories.

    Yields:
        Markdown and YAML files, sorted.
    """
    for rel in scan_paths:
        path = repo_root / rel
        if path.is_file():
            yield path
        elif path.is_dir():
            yield from sorted(
                candidate
                for candidate in path.rglob("*")
                if candidate.is_file() and candidate.suffix in (".md", ".yml", ".yaml")
            )


def scan_file(
    path: Path,
    repo_root: Path,
    workflows_dir: Path,
    report: Report,
) -> None:
    """Scan one file.

    Args:
        path: File to scan.
        repo_root: Repository root (for relative display paths).
        workflows_dir: Directory holding the reusable workflow files.
        report: Report to append to.
    """
    rel = path.relative_to(repo_root).as_posix()
    text = path.read_text(encoding="utf-8")
    if path.suffix == ".md":
        snippets = list(markdown_snippets(path=rel, text=text))
    else:
        lines = parse_lines(text=text)
        snippets = [
            Snippet(path=rel, lines=lines, complete=is_complete(lines), marked=False),
        ]
    for snippet in snippets:
        try:
            scan_snippet(snippet=snippet, workflows_dir=workflows_dir, report=report)
        except ValueError as exc:
            report.violations.append(f"{rel}: unparseable permissions block ({exc})")


def parse_args(
    argv: list[str],
) -> argparse.Namespace:
    """Parse CLI arguments.

    Args:
        argv: Argument vector without the program name.

    Returns:
        Parsed arguments.
    """
    parser = argparse.ArgumentParser(
        description="Validate documented caller permissions against workflow unions.",
    )
    parser.add_argument(
        "paths",
        nargs="*",
        help="Files or directories to scan (default: docs examples README.md)",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=REPO_ROOT,
        help="Repository root holding .github/workflows (default: this checkout)",
    )
    parser.add_argument(
        "--union",
        metavar="WORKFLOW",
        help="Print the caller permission union of one reusable workflow and exit",
    )
    return parser.parse_args(argv)


def main(
    argv: list[str],
) -> int:
    """Run the validator.

    Args:
        argv: Argument vector without the program name.

    Returns:
        Process exit code: 0 when every call site is satisfied.
    """
    args = parse_args(argv=argv)
    repo_root: Path = args.repo_root.resolve()
    workflows_dir = repo_root / WORKFLOWS_SUBDIR
    if not workflows_dir.is_dir():
        print(f"ERROR: workflows directory not found: {workflows_dir}", file=sys.stderr)
        return 1
    if args.union:
        try:
            union = workflow_union(name=args.union, workflows_dir=workflows_dir)
        except ValueError as exc:
            print(f"ERROR: unparseable permissions block ({exc})", file=sys.stderr)
            return 1
        if union is None:
            print(f"ERROR: no such workflow: {args.union}", file=sys.stderr)
            return 1
        for scope, level in sorted(union.items()):
            print(f"{scope}: {level}")
        return 0
    report = Report()
    scan_paths = list(args.paths) if args.paths else list(DEFAULT_SCAN_PATHS)
    for path in iter_files(repo_root=repo_root, scan_paths=scan_paths):
        scan_file(
            path=path,
            repo_root=repo_root,
            workflows_dir=workflows_dir,
            report=report,
        )
    for notice in report.notices:
        print(f"NOTICE: {notice}")
    if report.violations:
        for violation in report.violations:
            print(violation, file=sys.stderr)
        print(
            f"ERROR: {len(report.violations)} caller permission violation(s) "
            f"across {report.checked} call site(s)",
            file=sys.stderr,
        )
        return 1
    summary = f"OK: {report.checked} documented caller call site(s)"
    print(f"{summary} satisfy their declared unions")
    return 0


if __name__ == "__main__":
    sys.exit(main(argv=sys.argv[1:]))
