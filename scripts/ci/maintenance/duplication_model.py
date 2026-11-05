# SPDX-License-Identifier: MIT
"""Conservative, offline duplication matching and public-safe report rendering.

Automatic issues require equality of the normalized control structure. Lossy
catalog subsequences and similarity remain separate manual-review categories.
No scanned source is executed.
"""

from __future__ import annotations

import hashlib
import json
import re
from collections import Counter
from dataclasses import dataclass
from html import escape
from pathlib import Path
from typing import Any

import duplication_sources as syntax
import yaml
from duplication_core import operations

WORKFLOW = re.compile(r"^\.github/workflows/[^/]+\.ya?ml$")
ACTION = re.compile(r"^\.github/actions/[^/]+/action\.ya?ml$")
SCRIPT = re.compile(
    r"^(?:scripts|\.github/scripts)/"
    r"(?:.+\.(?:sh|bash|zsh|ksh|fish|py|js|mjs|cjs|ts|rb|pl|ps1)|(?:.*/)?[^/.]+)$"
)
MEMBERS_BEGIN = "<!-- lgtm-ci:dup-members:begin -->"
MEMBERS_END = "<!-- lgtm-ci:dup-members:end -->"
FINGERPRINT_VERSION = 2
MIN_CORE_STEPS = 1
# Scripts need this many operative commands before a match can qualify for an
# issue. Tuned on the 2026-11-05 org snapshot (docs/duplication-scan-tuning-1237.md):
# generic failure wrappers such as `echo ::error::...; exit 1` score 0.
MIN_SCRIPT_STATEMENTS = 3
NEAR_MISS_COUNT = 10
# Size reported for scripts with uninspected regions; above any valid minimum.
MIN_SCRIPT_STATEMENTS_UNBOUNDED = 1_000
# Commands that only report, exit or configure the shell are not operations.
_SHELL_BOILERPLATE = {"set", "echo", "printf", "exit", "return", "true", ":", "shift"}
# Words that only delimit structure; the commands inside them are counted.
_SHELL_STRUCTURE = {
    "then",
    "else",
    "fi",
    "do",
    "done",
    "esac",
    "{",
    "}",
    "(",
    ")",
    ";;",
    "in",
}
# Condition heads: the test is control flow, the body carries the operations.
_SHELL_CONDITIONS = {"if", "elif", "while", "until", "case", "for", "[", "[[", "test"}
# Python shape tokens are `<type>:<text>`; only shell lexemes carry a trailing `;`.
PYTHON_TOKEN = re.compile(r"\d+:")
# A bare case-arm pattern: no expansion, assignment or command substitution.
CASE_PATTERN = re.compile(r"\(?[^\s()$=`'\"]+\)")
_SHELL_SEPARATORS = {";", ";;", ";&", ";;&", "&&", "||", "|", "&", "|&"}
_PYTHON_BOILERPLATE = {
    "1:import",
    "1:from",
    "1:pass",
    "1:return",
    "1:print",
    "1:raise",
    "1:def",
    "1:class",
    "1:async",
    "1:global",
    "1:nonlocal",
}
_PYTHON_STRUCTURE = {
    "1:if",
    "1:elif",
    "1:else",
    "1:try",
    "1:except",
    "1:finally",
    "1:with",
    "1:for",
    "1:while",
    "1:match",
    "1:case",
}
_PYTHON_EXITS = (("1:sys", "55:.", "1:exit"), ("1:exit",), ("1:quit",))


# The record keeps provenance and public rendering separate from matching data.
@dataclass(frozen=True)
class Unit:  # pylint: disable=too-many-instance-attributes
    """One job, composite action or script; private source stays in memory."""

    repository: str
    path: str
    job: str
    private: bool
    kind: str
    shape: tuple[str, ...]
    source: str
    parameters: tuple[str, ...] = ()
    reference: str = ""
    core: tuple[str, ...] = ()
    main: str = ""
    main_index: int | None = None

    @property
    def fingerprint(self) -> str:
        """Identity depends on logic, never the current member list."""
        payload = json.dumps(
            [FINGERPRINT_VERSION, self.kind, self.shape],
            separators=(",", ":"),
        )
        return hashlib.sha256(payload.encode()).hexdigest()[:24]

    @property
    def features(self) -> set[tuple[str, ...]]:
        """Ordered shingles retain adjacency; exact shapes guard the full order."""
        size = min(3, len(self.shape))
        return {self.shape[i : i + size] for i in range(len(self.shape) - size + 1)}


def selected(path: str) -> bool:
    """Select workflow/action definitions and supported script paths."""
    return bool(
        WORKFLOW.fullmatch(path) or ACTION.fullmatch(path) or SCRIPT.fullmatch(path),
    )


def units(
    repository: str,
    private: bool,
    files: dict[str, str],
    reference: str = "",
    skipped: Counter[str] | None = None,
) -> list[Unit]:
    """Split selected YAML into jobs/actions and tokenize scripts."""
    found: list[Unit] = []
    for path, source in sorted(files.items()):
        if not selected(path):
            continue
        try:
            found.extend(
                file_units(
                    repository,
                    private,
                    path,
                    source,
                    files,
                    reference,
                ),
            )
        except (ValueError, TypeError, yaml.YAMLError):
            if skipped is None:
                raise
            skipped["invalid source"] += 1
    return found


# Parsing retains provenance, validation and inherited execution context.
# pylint: disable-next=too-many-arguments,too-many-positional-arguments,too-many-locals
def file_units(
    repository: str,
    private: bool,
    path: str,
    source: str,
    files: dict[str, str],
    reference: str,
) -> list[Unit]:
    """Parse one file; validation failures never include source or repo names."""
    found: list[Unit] = []
    if SCRIPT.fullmatch(path):
        if not Path(path).suffix and not source.startswith("#!"):
            return found
        shape = syntax.script_shape(path, source, repository, files)
        if shape:
            found.append(
                Unit(
                    repository,
                    path,
                    "",
                    private,
                    "script",
                    shape,
                    source,
                    reference=reference,
                )
            )
        return found
    data = syntax.source_yaml(source)
    if not isinstance(data, dict):
        raise ValueError("invalid workflow/action document mapping")
    is_workflow = bool(WORKFLOW.fullmatch(path))
    blocks = data.get("jobs", {}) if is_workflow else {"": data.get("runs", {})}
    if not isinstance(blocks, dict):
        raise ValueError("invalid workflow job mapping")
    for job, block in (blocks or {}).items():
        if not isinstance(block, dict):
            raise ValueError("invalid workflow job")
        # A reusable call is already adoption; it is not a copied job.
        if "uses" in block or not block.get("steps"):
            continue
        if not isinstance(block["steps"], list) or any(
            not isinstance(step, dict) for step in block["steps"]
        ):
            raise ValueError("invalid workflow steps")
        targets = [
            str(step.get("uses", "")).split("@", 1)[0].lower()
            for step in block["steps"]
            if isinstance(step, dict)
        ]
        infrastructure = {"actions/checkout", "step-security/harden-runner"}
        if (
            len(targets) == len(block["steps"])
            and targets
            and any(target.startswith("lgtm-hq/lgtm-ci/") for target in targets)
            and all(
                target in infrastructure or target.startswith("lgtm-hq/lgtm-ci/")
                for target in targets
            )
        ):
            # Calls to shared actions plus required hardening/checkout are
            # already adoption, even when their input values differ.
            continue
        action_inputs = {} if is_workflow else data.get("inputs", {})
        shape_data = syntax.operation_shape(
            block,
            repository,
            files,
            defaults=syntax.run_defaults(data) if is_workflow else {},
            environment=data.get("env", {}) if is_workflow else {},
            context="execution" if is_workflow else "action",
            opaque_context=syntax.runner_context_reference(action_inputs),
        )
        if is_workflow:
            context_keys = ("env", "permissions", "defaults")
            inherited = {key: data[key] for key in context_keys if key in data}
            if inherited:
                shape_data["workflow-context"] = syntax.operation_shape(
                    inherited,
                    repository,
                    files,
                )
        # One token per ordered operation plus job-level control metadata.
        steps = shape_data.pop("steps")
        shape = tuple(json.dumps(item, sort_keys=True) for item in [shape_data, *steps])
        parameters = sorted(
            {
                str(key)
                for step in block["steps"]
                if isinstance(step, dict)
                for key in (step.get("with") or {})
            }
        )
        snippet = yaml.safe_dump({str(job): block}, sort_keys=False)
        operation_data = operations(data, block) if is_workflow else ((), "", None)
        core, main, main_index = operation_data
        found.append(
            Unit(
                repository,
                path,
                str(job),
                private,
                "steps",
                shape,
                snippet,
                tuple(parameters),
                reference,
                core,
                main,
                main_index,
            )
        )
    return found


def load_exceptions(path: Path) -> list[dict[str, Any]]:
    """Read #1236's exact repo/path/optional-job allowlist, failing closed."""
    if not path.exists():
        raise ValueError(f"required allowlist missing: {path} (prerequisite #1236)")
    data = yaml.safe_load(path.read_text())
    rows = data.get("exceptions") if isinstance(data, dict) else None
    if (
        not isinstance(data, dict)
        or set(data) != {"schema-version", "exceptions"}
        or not isinstance(data.get("schema-version"), int)
        or isinstance(data.get("schema-version"), bool)
        or not isinstance(rows, list)
    ):
        raise ValueError(
            "local-exceptions.yml requires schema-version: 1 and exceptions (#1236)",
        )
    if data["schema-version"] != 1:
        raise ValueError("unsupported local-exceptions schema-version (#1236)")
    patterns = {
        "repo": r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+",
        "path": r"(?!.*(?:^|/)\.{1,2}(?:/|$))[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*",
        "job": r"[A-Za-z_][A-Za-z0-9_-]*",
        "reason": r"[^\r\n]*\S[^\r\n]*",
        "link": r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/"
        r"(?:issues|pull)/[1-9][0-9]*(?:#issuecomment-[0-9]+)?",
    }
    for row in rows:
        if (
            not isinstance(row, dict)
            or set(row) - set(patterns)
            or any(
                not isinstance(row.get(key), str) or not row[key].strip()
                for key in ("repo", "path", "reason", "link")
            )
            or any(
                not isinstance(value, str) or not re.fullmatch(patterns[key], value)
                for key, value in row.items()
            )
        ):
            raise ValueError(
                "invalid local exception: expected repo/path/optional-job/reason/link",
            )
    return rows


def excepted(unit: Unit, rows: list[dict[str, Any]]) -> bool:
    """An omitted job exempts the entire path; an explicit job exempts only it."""
    return any(
        row["repo"].lower() == unit.repository.lower()
        and row["path"] == unit.path
        and ("job" not in row or row["job"] == unit.job)
        for row in rows
    )


def _commands(shape: tuple[str, ...]) -> list[list[str]]:
    """Split a script shape into commands at newlines and command separators.

    Shell lexemes keep a trailing ``;`` (``hi;``), so it is split off here.
    Python NEWLINE (``4:``) and ``;`` (``55:;``) tokens end a statement.
    """
    commands: list[list[str]] = []
    current: list[str] = []

    def flush() -> None:
        if current:
            commands.append(list(current))
            current.clear()

    for token in shape:
        if token.startswith("#!") or token in {"5:", "6:"}:
            continue  # shebang, Python INDENT/DEDENT
        if token in {"<newline>", "4:", "55:;"} or token in _SHELL_SEPARATORS:
            flush()
        elif token.endswith(";") and not PYTHON_TOKEN.match(token):
            # Resolved markers (`<path>;`, `<script:hash>;`) end a command too.
            word = token.rstrip(";")
            if word and word not in _SHELL_STRUCTURE:
                current.append(word)
            flush()
        else:
            current.append(token)
    flush()
    return commands


def _operative(command: list[str], in_case: bool = False) -> bool:
    """Whether a command performs work beyond reporting, exiting or structure."""
    words = [token for token in command if token not in _SHELL_STRUCTURE]
    if in_case and words and CASE_PATTERN.fullmatch(words[0]):
        words = words[1:]  # case-arm pattern such as `a)`, `-h|--help)` or `*)`
    if not words:
        return False
    head = words[0]
    non_operative = (
        head in _SHELL_BOILERPLATE
        or head in _SHELL_CONDITIONS
        or head in _PYTHON_BOILERPLATE
        or head in _PYTHON_STRUCTURE
        # shell function header
        or head.endswith("()")
        or (len(words) > 1 and words[1] == "()")
        or any(tuple(words[: len(call)]) == call for call in _PYTHON_EXITS)
        # bare literal, such as a docstring
        or (len(words) == 1 and head.startswith(("3:", "2:")))
    )
    return not non_operative


def unit_size(unit: Unit) -> int:
    """Count a script's operative commands, ignoring reporting and structure.

    A script containing an opaque (uninspected) region is never undersized:
    its logic is unknown, so the gate must not be what hides it.
    """
    if any(token.startswith("<unresolved-") for token in unit.shape):
        return MIN_SCRIPT_STATEMENTS_UNBOUNDED
    count = 0
    depth = 0
    for command in _commands(unit.shape):
        head = command[0] if command else ""
        if head == "case":
            depth += 1
        count += _operative(command, depth > 0)
        if "esac" in command:
            depth = max(depth - 1, 0)
    return count


def large_enough(unit: Unit, minimum: int = MIN_SCRIPT_STATEMENTS) -> bool:
    """Issue gate for scripts; jobs and actions keep their existing rules."""
    return unit.kind != "script" or unit_size(unit) >= minimum


def similarity(left: Unit, right: Unit) -> float:
    """Jaccard similarity of ordered shingles."""
    union = left.features | right.features
    return len(left.features & right.features) / len(union) if union else 0.0


def catalog_match(consumer: Unit, reference: Unit) -> bool:
    """Composites supply operations, while jobs also carry runner context."""
    if consumer.kind != reference.kind:
        return False
    if consumer.shape == reference.shape:
        return True
    return (
        consumer.kind == "steps"
        and bool(ACTION.fullmatch(reference.path))
        and reference.shape[0] == "{}"
        and consumer.shape[1:] == reference.shape[1:]
    )


def clusters(
    consumers: list[Unit],
    references: list[Unit],
    _threshold: float,
    min_statements: int = 0,
) -> list[tuple[list[Unit], list[Unit], float]]:
    """Group parameter-only copies; catalog matches also qualify one consumer.

    Exact normalized structures prevent transitive similarity chains joining
    unrelated implementations. Already-adopted calls are omitted by ``units``.
    Scripts below ``min_statements`` operative statements never qualify: a
    generic helper belongs to its owning workflow's migration, not its own.
    The CLI applies the tuned ``MIN_SCRIPT_STATEMENTS`` policy; the model
    default of 0 disables the gate for direct callers.
    """
    groups: dict[str, list[Unit]] = {}
    for unit in consumers:
        if large_enough(unit, min_statements):
            groups.setdefault(unit.fingerprint, []).append(unit)
    result: list[tuple[list[Unit], list[Unit], float]] = []
    for _, members in sorted(groups.items()):
        matches = [ref for ref in references if catalog_match(members[0], ref)]
        if len({m.repository for m in members}) >= 2 or matches:
            result.append((members, matches, 1.0))
    return result


def ordered_subsequence(core: tuple[str, ...], reference: tuple[str, ...]) -> bool:
    """Check ordered inclusion while preserving repeated-operation counts."""
    remaining = iter(reference)
    return all(any(item == operation for item in remaining) for operation in core)


def includes_main(core: tuple[str, ...], reference: Unit) -> bool:
    """Require an alignment through the selected occurrence, not just its token."""
    index = reference.main_index
    if (
        not isinstance(index, int)
        or isinstance(index, bool)
        or not 0 <= index < len(reference.core)
        or not reference.main
        or reference.core[index] != reference.main
    ):
        return False
    return any(
        operation == reference.main
        and ordered_subsequence(core[:position], reference.core[:index])
        and ordered_subsequence(core[position + 1 :], reference.core[index + 1 :])
        for position, operation in enumerate(core)
    )


def catalog_subsequences(
    consumers: list[Unit], references: list[Unit], minimum: int = MIN_CORE_STEPS
) -> list[tuple[Unit, Unit, int]]:
    """Manual candidates only: every core operation, in order, including main.

    Single-script jobs never qualify, even when tuning lowers the threshold.
    Exact matches stay in their existing category. No similarity gate applies.
    """
    result = []
    for consumer in consumers:
        if not WORKFLOW.fullmatch(consumer.path) or len(consumer.core) < minimum:
            continue
        if len(consumer.core) == 1 and not consumer.core[0].startswith("action:"):
            continue
        for reference in references:
            if (
                consumer.repository == reference.repository
                or not WORKFLOW.fullmatch(reference.path)
                or catalog_match(consumer, reference)
            ):
                continue
            if includes_main(consumer.core, reference):
                result.append((consumer, reference, len(consumer.core)))
    return result


def render_subsequences(candidates: list[tuple[Unit, Unit, int]]) -> list[str]:
    """Render manual candidates without source, private jobs or issue markers."""
    if not candidates:
        return []
    lines = ["## Catalog subsequence candidates (manual review only; no issues)", ""]
    for consumer, reference, count in candidates:
        job = f" (job `{safe_text(consumer.job)}`)" if not consumer.private else ""
        target = reference.reference if not reference.private else "catalog reusable"
        noun = "step" if count == 1 else "steps"
        lines.append(
            f"- `{safe_text(consumer.repository)}`: "
            f"`{safe_text(consumer.path)}`{job} → `{safe_text(target)}`; "
            f"{count} shared core {noun}, including main."
        )
    return lines + [""]


Pair = tuple[Unit, Unit, float]


def scored_pairs(consumers: list[Unit], references: list[Unit]) -> list[Pair]:
    """Score every public cross-repository pair once, highest first."""
    result = []
    public = [unit for unit in consumers if not unit.private]
    candidates = [*public, *(unit for unit in references if not unit.private)]
    seen = set()
    for left in public:
        for right in candidates:
            if left.repository == right.repository or left.kind != right.kind:
                continue
            pair = tuple(sorted((left.fingerprint, right.fingerprint)))
            if catalog_match(left, right) or pair in seen:
                continue
            seen.add(pair)
            result.append((left, right, similarity(left, right)))
    return sorted(
        result,
        key=lambda match: (-match[2], match[0].path, match[1].path),
    )


def near_matches(
    consumers: list[Unit],
    references: list[Unit],
    threshold: float,
    min_statements: int = 0,
) -> list[Pair]:
    """Suggest public near matches for manual inspection, never automatic issues."""
    pairs = scored_pairs(
        [unit for unit in consumers if large_enough(unit, min_statements)],
        [unit for unit in references if large_enough(unit, min_statements)],
    )
    return [match for match in pairs if match[2] >= threshold][:20]


def near_misses(
    consumers: list[Unit],
    references: list[Unit],
    threshold: float,
    count: int = NEAR_MISS_COUNT,
    min_statements: int = 0,
) -> list[tuple[Unit, Unit, float]]:
    """Top public scores below the threshold, reported as tuning evidence only.

    The script size gate applies here too, as it does to near matches;
    otherwise echo-and-exit wrappers crowd out every meaningful near miss.
    """
    pairs = scored_pairs(
        [unit for unit in consumers if large_enough(unit, min_statements)],
        [unit for unit in references if large_enough(unit, min_statements)],
    )
    return [match for match in pairs if 0 < match[2] < threshold][:count]


def safe_text(value: str) -> str:
    """Keep untrusted identifiers on one inert Markdown line."""
    return escape(re.sub(r"[\x00-\x1f\x7f`]", " ", value), quote=False)


def render(
    cluster: tuple[list[Unit], list[Unit], float],
    _threshold: float,
) -> tuple[str, str]:
    """Render issue text using private repositories' names and paths only."""
    members, references, score = cluster
    public = next((unit for unit in members if not unit.private), None)
    thing = next(
        (ref.reference for ref in references if ref.reference and not ref.private), ""
    ) or (public.job or Path(public.path).stem if public else "shared CI logic")
    repo_count = len({member.repository for member in members})
    proposal = f"adopt {thing} from" if references else f"move {thing} into"
    noun = "repo" if repo_count == 1 else "repos"
    title = safe_text(f"refactor(adoption): {proposal} lgtm-ci ({repo_count} {noun})")
    lines = [
        f"<!-- lgtm-ci:dup-scan:{members[0].fingerprint} -->",
        "",
        "Parameter-only duplication candidate; review before adoption.",
        "",
        f"Normalized structure matches exactly (Jaccard similarity: {score:.3f}).",
        "",
        MEMBERS_BEGIN,
        "Members:",
        "",
    ]
    for unit in sorted(
        members,
        key=lambda unit: (unit.repository, unit.path, unit.job),
    ):
        job_name = safe_text(unit.job) if not unit.private else ""
        suffix = f" (job `{job_name}`)" if job_name else ""
        lines.append(
            f"- `{safe_text(unit.repository)}`: `{safe_text(unit.path)}`{suffix}",
        )
    lines += [
        MEMBERS_END,
        "",
        "Proposed shape: one reusable job, composite action or script with inputs for",
        "repository/image names, paths, versions and the differing action parameters.",
    ]
    if public and public.parameters:
        lines += [
            "",
            "Action input names: "
            + ", ".join(f"`{safe_text(key)}`" for key in public.parameters)
            + ".",
        ]
    if any(not ref.private for ref in references):
        lines += ["", "Existing catalog implementation(s):", ""]
        lines += [
            f"- `{safe_text(entry)}`"
            for entry in sorted(
                {ref.reference for ref in references if not ref.private},
            )
        ]
    if public:
        # Fence longer than any source backtick run prevents Markdown escape.
        fence = "`" * max(
            3,
            1
            + max(
                (len(m.group()) for m in re.finditer(r"`+", public.source)),
                default=0,
            ),
        )
        lines += [
            "",
            f"Public example from `{safe_text(public.repository)}`:",
            "",
            fence,
            public.source[:4000].replace("<!-- lgtm-ci:", "< !-- lgtm-ci:"),
            fence,
        ]
    return title, "\n".join(lines) + "\n"
