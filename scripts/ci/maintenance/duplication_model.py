# SPDX-License-Identifier: MIT
"""Conservative, offline duplication matching and public-safe report rendering.

Similarity generates candidates; equality of the normalized control structure
is the inclusion gate. This deliberately prefers missed copies to issues about
jobs that merely share checkout/setup steps. No scanned source is executed.
"""

from __future__ import annotations

import hashlib
import io
import json
import posixpath
import re
import tokenize
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

WORKFLOW = re.compile(r"^\.github/workflows/[^/]+\.ya?ml$")
ACTION = re.compile(r"^\.github/actions/[^/]+/action\.ya?ml$")
SCRIPT = re.compile(
    r"^(?:scripts|\.github/scripts)/"
    r"(?:.+\.(?:sh|bash|zsh|ksh|fish|py|js|mjs|cjs|ts|rb|pl|ps1)|(?:.*/)?[^/.]+)$"
)
SCRIPT_CALL = re.compile(
    r"(?:\.?/?[\w.${}-]+/)*(?:scripts|\.github/scripts)/[\w./-]+"
    r"|(?:[\w.${}/-]+/)?[\w.-]+\.(?:sh|bash|py|js|mjs|cjs|ts|rb|pl|ps1)\b"
)
EXPRESSION = re.compile(r"\$\{\{.*?\}\}", re.S)
SHELL_EXPRESSION = re.compile(r"\$\{[^{}]*\}|\$\(\(.*?\)\)", re.S)
MEMBERS_BEGIN = "<!-- lgtm-ci:dup-members:begin -->"
MEMBERS_END = "<!-- lgtm-ci:dup-members:end -->"
FINGERPRINT_VERSION = 1
SAFE_INPUTS = {
    "actions/setup-python": {"python-version"},
    "actions/setup-node": {"node-version"},
    "astral-sh/setup-uv": {"version", "python-version"},
}
LEXEME = re.compile(
    r"""("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|(?<!\S)\#[^\n]*|"""
    r"""//[^\n]*|/\*.*?\*/|[^\S\n]+|\n|[^\s'"]+)""",
    re.S,
)


@dataclass(frozen=True)
class Unit:
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
            [FINGERPRINT_VERSION, self.kind, self.shape], separators=(",", ":")
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
        WORKFLOW.fullmatch(path) or ACTION.fullmatch(path) or SCRIPT.fullmatch(path)
    )


def normalize(source: str, repository: str) -> str:
    """Remove comments/spacing and mask repository, image, path and version literals.

    Keep command names, flags, operators, conditions and string contents unless
    they are recognizable parameters. In particular, quoted shell programs are
    not collapsed to a single placeholder.
    """
    source = "".join(
        match.group()
        for match in LEXEME.finditer(source)
        if not match.group().startswith(("#", "/*", "//"))
    )
    # A direct value is a parameter. Embedded selectors/conditions are logic;
    # masking the whole expression would hide different command branches.
    source = EXPRESSION.sub(
        lambda match: (
            "<input>"
            if re.fullmatch(r"\$\{\{\s*[\w.-]+\s*\}\}", match.group())
            else match.group()
        ),
        source,
    )
    # Slash operators inside shell expansions and GitHub expressions are logic.
    expressions: list[str] = []

    def protect(match: re.Match[str]) -> str:
        expressions.append(match.group())
        return f"LGTMEXPRESSION{len(expressions) - 1}TOKEN"

    source = EXPRESSION.sub(protect, source)
    source = SHELL_EXPRESSION.sub(protect, source)
    source = source.replace(repository, "<repository>")
    source = re.sub(r"([\w.-]+/[\w./-]+)@[a-fA-F0-9]{40}\b", r"\1", source)
    source = re.sub(r"\b(?:ghcr\.io|docker\.io)/[\w./:@-]+", "<image>", source)
    source = re.sub(r"(?<![\w])(?:\./|\.\./|/)[\w./${}-]+", "<path>", source)
    source = re.sub(r"\b[\w.-]+/[\w./-]+(?:\.[\w-]+)?\b", "<path>", source)
    source = re.sub(r"\b\d+(?:\.\d+)+(?:[\w.+-]*)\b", "<version>", source)
    tokens = []
    for match in LEXEME.finditer(source):
        token = match.group()
        if token == "\n":
            if tokens and tokens[-1] != "<newline>":
                tokens.append("<newline>")
            continue
        if token.isspace() or token.startswith(("#", "/*", "//")):
            continue
        tokens.append(token)
    if tokens and tokens[-1] == "<newline>":
        tokens.pop()
    result = " ".join(tokens)
    for index, expression in enumerate(expressions):
        result = result.replace(f"LGTMEXPRESSION{index}TOKEN", expression)
    return result


def command_shape(
    source: str,
    repository: str,
    files: dict[str, str],
    visited: frozenset[str] = frozenset(),
) -> str:
    """Compare called script bodies, never collapse executable paths to inputs.

    Two jobs that both run ``bash scripts/check.sh`` may do entirely different
    work. Resolve exact repository-relative paths without executing scripts;
    bare names have no known working directory, so retain their identity.
    """

    def replace(match: re.Match[str]) -> str:
        name = match.group()
        path = posixpath.normpath(
            name.removeprefix("${GITHUB_WORKSPACE}/").removeprefix("$GITHUB_WORKSPACE/")
        )
        if path in files and path not in visited:
            body = script_shape(path, files[path], repository, files, visited | {path})
            digest = hashlib.sha256(str(body).encode()).hexdigest()
            return f"<script:{digest}>"
        digest = hashlib.sha256(name.encode()).hexdigest()
        return f"<unresolved-script:{digest}>"

    return normalize(SCRIPT_CALL.sub(replace, source), repository)


def script_shape(
    path: str,
    source: str,
    repository: str,
    files: dict[str, str],
    visited: frozenset[str] = frozenset(),
) -> tuple[str, ...]:
    """Retain Python indentation and shell command boundaries as control flow."""
    if path.endswith(".py"):
        ignored = {tokenize.COMMENT, tokenize.NL, tokenize.ENCODING, tokenize.ENDMARKER}
        try:
            return tuple(
                f"{token.type}:"
                + command_shape(token.string, repository, files, visited | {path})
                for token in tokenize.generate_tokens(io.StringIO(source).readline)
                if token.type not in ignored
            )
        except (SyntaxError, tokenize.TokenError):
            # IndentationError/SyntaxError tracebacks include the source line.
            # Even failed scans must not expose private code in public logs.
            raise ValueError(f"invalid Python source: {path}") from None
    return tuple(command_shape(source, repository, files, visited | {path}).split())


def operation_shape(value: Any, repository: str, files: dict[str, str]) -> Any:
    """Keep execution metadata and unknown inputs; mask only known parameters."""
    if isinstance(value, list):
        return [operation_shape(item, repository, files) for item in value]
    if not isinstance(value, dict):
        return normalize(str(value), repository)
    result = {}
    for key, item in value.items():
        if key in {"name", "using"}:
            continue
        if key in {"with", "env"}:
            if not isinstance(item, dict):
                raise ValueError("invalid action input or environment mapping")
            action = str(value.get("uses", "")).split("@", 1)[0].lower()
            result[key] = {
                str(name): (
                    "<parameter>"
                    if key == "with" and name in SAFE_INPUTS.get(action, set())
                    else parameter
                )
                for name, parameter in item.items()
            }
        elif key == "uses":
            # Retain action identity and subpath, discard mutable or SHA refs.
            result[key] = str(item).split("@", 1)[0].lower()
        elif key == "run":
            result[key] = command_shape(str(item), repository, files)
        elif key in {
            "if",
            "strategy",
            "continue-on-error",
            "needs",
            "permissions",
            "runs-on",
            "timeout-minutes",
            "defaults",
        }:
            # Conditional expressions are logic, not ordinary input values.
            result[key] = item
        else:
            result[key] = operation_shape(item, repository, files)
    if "run" in value:
        result.setdefault("shell", "bash")
    return result


def units(
    repository: str,
    private: bool,
    files: dict[str, str],
    reference: str = "",
    skipped: Counter[str] | None = None,
) -> list[Unit]:
    """Split selected YAML into jobs/actions and tokenize scripts."""
    found = []
    for path, source in sorted(files.items()):
        if not selected(path):
            continue
        try:
            found.extend(
                file_units(repository, private, path, source, files, reference)
            )
        except (ValueError, TypeError, yaml.YAMLError):
            if skipped is None:
                raise
            skipped["invalid source"] += 1
    return found


def file_units(
    repository: str,
    private: bool,
    path: str,
    source: str,
    files: dict[str, str],
    reference: str,
) -> list[Unit]:
    """Parse one file; validation failures never include source or repo names."""
    found = []
    if SCRIPT.fullmatch(path):
        if not Path(path).suffix and not source.startswith("#!"):
            return found
        shape = script_shape(path, source, repository, files)
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
        return found
    blocks = (
        data.get("jobs", {}) if WORKFLOW.fullmatch(path) else {"": data.get("runs", {})}
    )
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
        shape_data = operation_shape(block, repository, files)
        if WORKFLOW.fullmatch(path):
            inherited = {
                key: data[key]
                for key in ("env", "permissions", "defaults")
                if key in data
            }
            if inherited:
                shape_data["workflow-context"] = operation_shape(
                    inherited, repository, files
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
        or type(data.get("schema-version")) is not int
        or data["schema-version"] != 1
        or not isinstance(rows, list)
    ):
        raise ValueError(
            "local-exceptions.yml requires schema-version: 1 and exceptions (#1236)"
        )
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
                "invalid local exception: expected repo, path, optional job, "
                "reason, link"
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


def clusters(
    consumers: list[Unit],
    references: list[Unit],
    threshold: float,
) -> list[tuple[list[Unit], list[Unit], float]]:
    """Group parameter-only copies; catalog matches also qualify one consumer.

    Exact normalized structures prevent transitive similarity chains joining
    unrelated implementations. Already-adopted calls are omitted by ``units``.
    """
    groups: dict[str, list[Unit]] = {}
    catalog: dict[str, list[Unit]] = {}
    for unit in consumers:
        groups.setdefault(unit.fingerprint, []).append(unit)
    for unit in references:
        catalog.setdefault(unit.fingerprint, []).append(unit)
    result = []
    for fingerprint, members in sorted(groups.items()):
        matches = catalog.get(fingerprint, [])
        score = min(similarity(members[0], other) for other in [*members, *matches])
        if score >= threshold and (
            len({m.repository for m in members}) >= 2 or matches
        ):
            result.append((members, matches, score))
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
            if left.shape == right.shape or pair in seen:
                continue
            seen.add(pair)
            score = similarity(left, right)
            if score >= threshold:
                result.append((left, right, score))
    return sorted(result, key=lambda match: (-match[2], match[0].path, match[1].path))[
        :20
    ]


def render(
    cluster: tuple[list[Unit], list[Unit], float], threshold: float
) -> tuple[str, str]:
    """Render issue text using private repositories' names and paths only."""
    members, references, score = cluster
    public = next((unit for unit in members if not unit.private), None)
    thing = next(
        (ref.reference for ref in references if ref.reference and not ref.private), ""
    ) or (public.job or Path(public.path).stem if public else "shared CI logic")
    repo_count = len({member.repository for member in members})
    title = f"refactor(adoption): move {thing} into lgtm-ci ({repo_count} repos)"
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
        members, key=lambda unit: (unit.repository, unit.path, unit.job)
    ):
        suffix = f" (job `{unit.job}`)" if unit.job and not unit.private else ""
        lines.append(f"- `{unit.repository}`: `{unit.path}`{suffix}")
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
            + ", ".join(f"`{key}`" for key in public.parameters)
            + ".",
        ]
    if any(not ref.private for ref in references):
        lines += ["", "Existing catalog implementation(s):", ""]
        lines += [
            f"- `{entry}`"
            for entry in sorted(
                {ref.reference for ref in references if not ref.private}
            )
        ]
    if public:
        # Fence longer than any source backtick run prevents Markdown escape.
        fence = "`" * max(
            3,
            1
            + max(
                (len(m.group()) for m in re.finditer(r"`+", public.source)), default=0
            ),
        )
        lines += [
            "",
            f"Public example from `{public.repository}`:",
            "",
            fence,
            public.source[:4000].replace("<!-- lgtm-ci:", "&lt;!-- lgtm-ci:"),
            fence,
        ]
    return title, "\n".join(lines) + "\n"
