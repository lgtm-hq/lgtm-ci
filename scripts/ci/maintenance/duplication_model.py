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
import re
import tokenize
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
SCRIPT_CALL = re.compile(r"(?:[\w.${}/-]+/)?[\w.-]+\.(?:sh|bash|py|js|mjs|cjs|ts|rb|pl|ps1)\b")
EXPRESSION = re.compile(r"\$\{\{.*?\}\}", re.S)
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
        payload = json.dumps([self.kind, self.shape], separators=(",", ":"))
        return hashlib.sha256(payload.encode()).hexdigest()[:24]

    @property
    def features(self) -> set[tuple[str, ...]]:
        """Ordered shingles retain adjacency; exact shapes guard the full order."""
        size = min(3, len(self.shape))
        return {self.shape[i : i + size] for i in range(len(self.shape) - size + 1)}


def selected(path: str) -> bool:
    """Select workflow/action definitions and supported script paths."""
    return bool(WORKFLOW.fullmatch(path) or ACTION.fullmatch(path) or SCRIPT.fullmatch(path))


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
            "<input>" if re.fullmatch(r"\$\{\{\s*[\w.-]+\s*\}\}", match.group()) else match.group()
        ),
        source,
    )
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
    return " ".join(tokens)


def command_shape(source: str, repository: str, files: dict[str, str]) -> str:
    """Compare called script bodies, never collapse executable paths to inputs.

    Two jobs that both run ``bash scripts/check.sh`` may do entirely different
    work. Resolve unambiguous local script names without executing the scripts;
    keep an unresolved script's name as part of its identity.
    """

    def replace(match: re.Match[str]) -> str:
        name = match.group()
        candidates = [
            (path, text) for path, text in files.items() if Path(path).name == Path(name).name
        ]
        if len(candidates) == 1:
            path, text = candidates[0]
            body = (
                script_shape(path, text, repository, {})
                if path.endswith(".py")
                else normalize(text, repository)
            )
            digest = hashlib.sha256(str(body).encode()).hexdigest()
            return f"<script:{digest}>"
        digest = hashlib.sha256(name.encode()).hexdigest()
        return f"<unresolved-script:{digest}>"

    return normalize(SCRIPT_CALL.sub(replace, source), repository)


def script_shape(path: str, source: str, repository: str, files: dict[str, str]) -> tuple[str, ...]:
    """Retain Python indentation and shell command boundaries as control flow."""
    if path.endswith(".py"):
        ignored = {tokenize.COMMENT, tokenize.NL, tokenize.ENCODING, tokenize.ENDMARKER}
        try:
            return tuple(
                f"{token.type}:{normalize(token.string, repository)}"
                for token in tokenize.generate_tokens(io.StringIO(source).readline)
                if token.type not in ignored
            )
        except (SyntaxError, tokenize.TokenError):
            # IndentationError/SyntaxError tracebacks include the source line.
            # Even failed scans must not expose private code in public logs.
            raise ValueError(f"invalid Python source: {repository}: {path}") from None
    return tuple(command_shape(source, repository, files).split())


def operation_shape(value: Any, repository: str, files: dict[str, str]) -> Any:
    """Keep YAML control flow and operation order; expose inputs as parameters."""
    if isinstance(value, list):
        return [operation_shape(item, repository, files) for item in value]
    if not isinstance(value, dict):
        return normalize(str(value), repository)
    result = {}
    for key, item in value.items():
        if key in {"name", "id", "needs", "runs-on", "timeout-minutes", "permissions", "using"}:
            continue
        if key in {"with", "env"}:
            result[key] = sorted(str(name) for name in (item or {}))
        elif key == "uses":
            # Retain action identity and subpath, discard mutable or SHA refs.
            result[key] = str(item).split("@", 1)[0].lower()
        elif key == "run":
            result[key] = command_shape(str(item), repository, files)
        elif key in {"if", "strategy", "continue-on-error"}:
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
) -> list[Unit]:
    """Split selected YAML into jobs/actions and tokenize scripts."""
    found = []
    for path, source in sorted(files.items()):
        if not selected(path):
            continue
        if SCRIPT.fullmatch(path):
            shape = script_shape(path, source, repository, files)
            if shape:
                found.append(
                    Unit(
                        repository, path, "", private, "script", shape, source, reference=reference
                    )
                )
            continue
        data = yaml.safe_load(source)
        if not isinstance(data, dict):
            continue
        blocks = data.get("jobs", {}) if WORKFLOW.fullmatch(path) else {"": data.get("runs", {})}
        for job, block in (blocks or {}).items():
            if not isinstance(block, dict):
                continue
            # A reusable call is already adoption; it is not a copied job.
            if "uses" in block or not block.get("steps"):
                continue
            targets = [
                str(step.get("uses", "")).split("@", 1)[0].lower()
                for step in block["steps"]
                if isinstance(step, dict)
            ]
            infrastructure = {"actions/checkout", "step-security/harden-runner"}
            if targets and all(
                target in infrastructure or target.startswith("lgtm-hq/lgtm-ci/")
                for target in targets
            ):
                # Calls to shared actions plus required hardening/checkout are
                # already adoption, even when their input values differ.
                continue
            shape_data = operation_shape(block, repository, files)
            # One token per ordered operation plus job-level control metadata.
            steps = shape_data.pop("steps")
            shape = tuple(json.dumps(item, sort_keys=True) for item in [shape_data, *steps])
            parameters = sorted(
                {
                    str(key)
                    for step in block["steps"]
                    for key in (step.get("with") or {})
                    if isinstance(step, dict)
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
    if not isinstance(rows, list):
        raise ValueError("local-exceptions.yml must contain an exceptions list (#1236)")
    for row in rows:
        if (
            not isinstance(row, dict)
            or any(
                not isinstance(row.get(key), str) or not row[key].strip()
                for key in ("repo", "path", "reason", "link")
            )
            or ("job" in row and not isinstance(row["job"], str))
        ):
            raise ValueError(
                "invalid local exception: expected repo, path, optional job, reason, link"
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
        if score >= threshold and (len({m.repository for m in members}) >= 2 or matches):
            result.append((members, matches, score))
    return result


def render(cluster: tuple[list[Unit], list[Unit], float], threshold: float) -> tuple[str, str]:
    """Render issue text using private repositories' names and paths only."""
    members, references, score = cluster
    public = next((unit for unit in members if not unit.private), None)
    thing = Path((public or members[0]).path).stem
    repo_count = len({member.repository for member in members})
    title = f"refactor(adoption): move {thing} into lgtm-ci ({repo_count} repos)"
    lines = [
        f"<!-- lgtm-ci:dup-scan:{members[0].fingerprint} -->",
        "",
        "Parameter-only duplication candidate; review before adoption.",
        "",
        f"Jaccard similarity: {score:.3f}; configured threshold: {threshold:.3f}.",
        "",
        "Members:",
        "",
    ]
    for unit in members:
        suffix = f" (job `{unit.job}`)" if unit.job and not unit.private else ""
        lines.append(f"- `{unit.repository}`: `{unit.path}`{suffix}")
    lines += [
        "",
        "Proposed shape: one reusable job, composite action or script with inputs for",
        "repository/image names, paths, versions and the differing action parameters.",
    ]
    if public and public.parameters:
        lines += [
            "",
            "Action input names: " + ", ".join(f"`{key}`" for key in public.parameters) + ".",
        ]
    if references:
        lines += ["", "Existing catalog implementation(s):", ""]
        lines += [f"- `{entry}`" for entry in sorted({ref.reference for ref in references})]
    if public:
        # Fence longer than any source backtick run prevents Markdown escape.
        fence = "`" * max(
            3, 1 + max((len(m.group()) for m in re.finditer(r"`+", public.source)), default=0)
        )
        lines += [
            "",
            f"Public example from `{public.repository}`:",
            "",
            fence,
            public.source[:4000],
            fence,
        ]
    return title, "\n".join(lines) + "\n"
