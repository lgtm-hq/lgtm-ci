# SPDX-License-Identifier: MIT
"""Conservative, offline duplication matching and public-safe report rendering.

Similarity generates candidates; equality of the normalized control structure
is the inclusion gate. This deliberately prefers missed copies to issues about
jobs that merely share checkout/setup steps. No scanned source is executed.
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

WORKFLOW = re.compile(r"^\.github/workflows/[^/]+\.ya?ml$")
ACTION = re.compile(r"^\.github/actions/[^/]+/action\.ya?ml$")
SCRIPT = re.compile(
    r"^(?:scripts|\.github/scripts)/"
    r"(?:.+\.(?:sh|bash|zsh|ksh|fish|py|js|mjs|cjs|ts|rb|pl|ps1)|(?:.*/)?[^/.]+)$"
)
MEMBERS_BEGIN = "<!-- lgtm-ci:dup-members:begin -->"
MEMBERS_END = "<!-- lgtm-ci:dup-members:end -->"
FINGERPRINT_VERSION = 2


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
    data = yaml.safe_load(source)
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
        shape_data = syntax.operation_shape(
            block,
            repository,
            files,
            defaults=syntax.run_defaults(data) if is_workflow else {},
            environment=data.get("env", {}) if is_workflow else {},
            context="execution" if is_workflow else "action",
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
) -> list[tuple[list[Unit], list[Unit], float]]:
    """Group parameter-only copies; catalog matches also qualify one consumer.

    Exact normalized structures prevent transitive similarity chains joining
    unrelated implementations. Already-adopted calls are omitted by ``units``.
    """
    groups: dict[str, list[Unit]] = {}
    for unit in consumers:
        groups.setdefault(unit.fingerprint, []).append(unit)
    result: list[tuple[list[Unit], list[Unit], float]] = []
    for _, members in sorted(groups.items()):
        matches = [ref for ref in references if catalog_match(members[0], ref)]
        if len({m.repository for m in members}) >= 2 or matches:
            result.append((members, matches, 1.0))
    return result


def near_matches(
    consumers: list[Unit], references: list[Unit], threshold: float
) -> list[tuple[Unit, Unit, float]]:
    """Suggest public near misses for manual inspection, never automatic issues."""
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
            score = similarity(left, right)
            if score >= threshold:
                result.append((left, right, score))
    return sorted(
        result,
        key=lambda match: (-match[2], match[0].path, match[1].path),
    )[:20]


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
