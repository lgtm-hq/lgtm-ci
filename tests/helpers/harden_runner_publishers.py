# SPDX-License-Identifier: MIT
"""Find the publishing steps of harden-runner-verified jobs (#1551).

``tests/python/test_harden_runner_verify_contract.py`` requires each step
listed in :data:`PRE_PUBLISH` to be immediately preceded by the pre-publish
recheck. This module holds that list, :data:`ALLOWED_UNGUARDED` (flagged steps
that run unguarded on purpose, with the reason), and the detector that flags
every step of a verified job that publishes: through a publishing action, a
publish primitive in its ``run:`` or env, a repo script it calls (followed
transitively), a local composite action, or a script path held in an input
the detector cannot resolve. Every flagged step must be in one of the lists.
"""

from __future__ import annotations

import functools
import glob
import itertools
import os
import re
from collections.abc import Collection, Iterator, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
EXAMPLES = ROOT / "examples"
ACTIONS = ROOT / ".github" / "actions"
SCRIPTS_CI = ROOT / "scripts" / "ci"
NAME = "Verify harden-runner agent"
VERIFY_ID = "verify-harden-runner"
RECHECK_NAME = "Recheck harden-runner agent"
PRE_PUBLISH_PREFIX = f"{RECHECK_NAME} before "

Step = dict[str, Any]
# (workflow file, job id, step name)
StepKey = tuple[str, str, str]

# Steps with an irreversible external side effect (#1551): a package publish,
# an image or manifest push, a release or release asset, a tag or branch push
# (or a signed commit made through the API), a PR created or merged, a
# registry package-version delete, a publishing workflow dispatch, a Pages
# deploy, a signature or attestation written to a public transparency log, or
# a commit and dispatch in another repository. Each must be immediately
# preceded by the pre-publish recheck. The guard runs once, before the step
# starts: a step that writes several things (an npm package set, a multi-tag
# push, a release plus its assets) is not rechecked between them. Writes
# judged reversible or internal are in ALLOWED_UNGUARDED.
PRE_PUBLISH: tuple[StepKey, ...] = (
    ("reusable-build-python-dist.yml", "build", "Attest build provenance"),
    ("reusable-build-rust-binaries.yml", "build", "Attest build provenance"),
    ("reusable-deploy-pages.yml", "deploy", "Deploy to GitHub Pages"),
    ("reusable-deploy-site-with-reports.yml", "deploy", "Deploy to GitHub Pages"),
    ("reusable-docker-build.yml", "build", "Build and push"),
    ("reusable-docker-build.yml", "build", "Push image after health check"),
    ("reusable-docker-build.yml", "build", "Generate artifact attestation"),
    ("reusable-docker-build.yml", "build", "Generate SBOM attestation"),
    ("reusable-docker-build.yml", "build", "Sign image"),
    (
        "reusable-docker-multiplatform-publish.yml",
        "build-per-platform",
        "Build and push (${{ matrix.platform }})",
    ),
    (
        "reusable-docker-multiplatform-publish.yml",
        "merge",
        "Create multi-arch manifest",
    ),
    (
        "reusable-docker-multiplatform-publish.yml",
        "merge",
        "Generate artifact attestation",
    ),
    ("reusable-docker-multiplatform-publish.yml", "merge", "Sign image"),
    ("reusable-ghcr-cleanup.yml", "cleanup", "Clean untagged GHCR images"),
    ("reusable-ghcr-cleanup.yml", "cleanup", "Prune aged tagged GHCR images"),
    ("reusable-github-release.yml", "release", "Create GitHub Release"),
    (
        "reusable-prune-build-staging-tags.yml",
        "prune-staging",
        "Prune build-* staging tags",
    ),
    ("reusable-publish-gem.yml", "publish", "Publish to RubyGems"),
    ("reusable-publish-npm-set.yml", "publish", "Publish package set"),
    ("reusable-publish-rust-release.yml", "github-release", "Create GitHub Release"),
    ("reusable-publish-test-results-pages.yml", "publish", "Publish to GitHub Pages"),
    ("reusable-release-auto-tag.yml", "auto-tag", "Create release tag"),
    ("reusable-release-auto-tag.yml", "auto-tag", "Create GitHub release"),
    ("reusable-release-auto-tag.yml", "auto-tag", "Update floating tag"),
    (
        "reusable-release-multi-ecosystem.yml",
        "version-pr",
        "Create or update version PR",
    ),
    ("reusable-release-multi-ecosystem.yml", "version-pr", "Enable auto-merge"),
    (
        "reusable-release-recover-resume.yml",
        "resume-homebrew",
        "Re-dispatch the tap update workflow",
    ),
    ("reusable-release-recover-resume.yml", "resume-npm", "Publish package set"),
    (
        "reusable-release-recover-resume.yml",
        "resume-github-release",
        "Create the release and upload only missing assets",
    ),
    ("reusable-release-version-pr.yml", "version-pr", "Create or update version PR"),
    ("reusable-release-version-pr.yml", "version-pr", "Enable auto-merge"),
    (
        "reusable-sbom-release-upload.yml",
        "upload-release-assets",
        "Upload SBOM to GitHub Release",
    ),
    ("reusable-sbom.yml", "sbom", "Create attestation"),
    ("reusable-sbom.yml", "release-assets", "Sign SBOM files"),
    ("reusable-test-node-publish.yml", "publish", "Publish to GitHub Pages"),
    ("reusable-test-python-publish.yml", "publish", "Publish to GitHub Pages"),
    (
        "reusable-vuln-suppression-check.yml",
        "vuln-suppression-check",
        "Check suppression staleness",
    ),
    # A tree, commit and branch in the fixture repository, then workflow
    # dispatches there (external-canary.sh).
    ("external-consumer-canary.yml", "canary", "Run external consumer canary"),
    ("publish-python-release.yml", "pypi-upload", "Upload to PyPI"),
)

# Steps the detector flags that run unguarded on purpose, with the reason: each
# write is reversible, stays inside the run or the PR, or is a notification.
_PR_COMMENT = "PR comment create, update or delete only (post-pr-comment.sh)"
_AI_REVIEW = "AI review comments on the PR only (run-ai-review.sh)"
_DUPLICATION = (
    "duplication_scan.py: GraphQL reads, an App token mint, and its own "
    "tracking issues and comments"
)
ALLOWED_UNGUARDED: dict[StepKey, str] = {
    (
        "duplication-scan.yml",
        "prerequisites",
        "Check source App and allowlist readiness",
    ): _DUPLICATION,
    ("duplication-scan.yml", "duplication-scan", "Scan and report"): _DUPLICATION,
    (
        "reusable-deploy-site-with-reports.yml",
        "build",
        "Prepare and upload artifact",
    ): "deletes this run's own stale Pages artifact before the upload",
    (
        "all-checks-gate-rerun.yml",
        "refresh",
        "Refresh failed gates for the completed head",
    ): "re-runs failed gate jobs of this repository; publishes nothing",
    (
        "external-consumer-canary.yml",
        "canary",
        "Cancel unfinished fixture runs and clean up ref",
    ): (
        "cleanup: cancels fixture runs and deletes the canary's own temporary "
        "branch; must run after a failure, so it is not skipped by a recheck"
    ),
    **{
        ("reusable-ai-review.yml", "ai-review", name): _AI_REVIEW
        for name in (
            "Preflight guards",
            "Check review size before installations",
            "Initialize review invocation",
            "Prepare Codex execution",
            "Install pinned lintro without review credentials",
            "Locate prior review-state",
            "Run AI review",
            "Run OAuth AI review",
            "Report oversized review without provider credentials",
            "Remove isolated review credentials",
        )
    },
    (
        "reusable-main-failure-notifier.yml",
        "notify",
        "Notify main workflow failure",
    ): "files an issue; 'gh pr merge --disable-auto' is advice in its text",
    **{
        (workflow, job, name): _PR_COMMENT
        for workflow, job, names in (
            (
                "reusable-publish-artifact-preview.yml",
                "publish-artifact-preview",
                ("Publish artifact preview comment",),
            ),
            (
                "reusable-publish-artifact-report.yml",
                "publish-artifact-report",
                ("Publish report comment",),
            ),
            (
                "reusable-publish-file-breakdown.yml",
                "publish-file-breakdown",
                ("Detect PR number", "Publish file breakdown"),
            ),
            (
                "reusable-publish-quality-summary.yml",
                "publish-quality-summary",
                (
                    "Detect PR number",
                    "Load quality summary body",
                    "Publish quality summary",
                ),
            ),
            (
                "reusable-publish-test-summary.yml",
                "publish-test-summary",
                (
                    "Detect PR number",
                    "Load test summary body",
                    "Publish test summary from file",
                    "Publish test summary from coverage table",
                ),
            ),
            (
                "reusable-publish-security-audit-comment.yml",
                "publish-security-audit-comment",
                ("Publish security audit comment",),
            ),
            (
                "reusable-semantic-pr-title.yml",
                "semantic-title",
                (
                    "Post semantic PR title failure comment",
                    "Clear semantic PR title failure comment",
                ),
            ),
        )
        for name in names
    },
}

# Publishing actions: a step that uses one is a publisher (see findings).
PUBLISHER_USES = (
    "actions/attest",
    "anchore/sbom-action@",
    "actions/deploy-pages@",
    "docker/build-push-action@",
    "peter-evans/create-pull-request@",
    "pypa/gh-action-pypi-publish@",
    "./.lgtm-ci-tooling/.github/actions/attest-build",
    "./.lgtm-ci-tooling/.github/actions/publish-gem",
    "./.lgtm-ci-tooling/.github/actions/publish-test-results",
)
# A publishing action with a mode input, and the input's default: not a
# publisher when the input is off (build-push-action with push: false).
USES_MODE_SWITCHES: dict[str, tuple[str, str]] = {
    # Uploads the SBOM to the release on release events unless false.
    "anchore/sbom-action@": ("upload-release-assets", "true"),
    "docker/build-push-action@": ("push", "false"),
}


def _tool(name: str) -> str:
    """Match a command word: ``name`` or a ``"$NAME..."`` variable holding it."""
    return rf"(?:\b{name}|\"?\$\{{?{name.upper()}\w*\}}?\"?)"


_GH = _tool("gh")
# A remote [user@]host:path operand, not a local path or URL.
_REMOTE = r"[\"']?(?:[\w.-]+@)?[\w.-]+:(?!//)"
_LAUNCHER = r"(?:\bnpx|\bbunx|\bpnpm\s+dlx)\s+(?:-\S+\s+)*"
# Publish primitives searched in a step's run:, its env values (step, job and
# workflow level), and the repo scripts it calls, transitively.
PUBLISH_PRIMITIVES: dict[str, re.Pattern[str]] = {
    name: re.compile(pattern, re.MULTILINE)
    for name, pattern in {
        "docker push": rf"{_tool('docker')}\s+push\b",
        "--push": r"(?:^|[\s\"'(])--push(?![\w-])",
        "buildx registry output": (
            r"(?:--output|-o)[=\s]+[\"']?type=(?:registry|image\S*push=true)"
        ),
        "imagetools create": r"imagetools[\"']?\s+[\"']?create\b",
        "skopeo copy/delete": rf"{_tool('skopeo')}\s+(?:copy|delete|sync)\b",
        "oras push": rf"{_tool('oras')}\s+push\b",
        "helm push": rf"{_tool('helm')}\s+push\b",
        "aws s3 write": r"\baws\s+s3\s+(?:cp|sync|mv|rm)\b",
        "gsutil write": r"\bgsutil\s+(?:-\S+\s+)*(?:cp|rsync|mv|rm)\b",
        "az blob upload": r"\baz\s+storage\s+blob\s+(?:upload|delete|sync)",
        "rsync/scp remote": rf"\b(?:rsync|scp)\b[^\n#]*\s{_REMOTE}",
        "release tool": (
            rf"{_LAUNCHER}(?:semantic-release|release-it|"
            r"(?:@changesets/cli|changeset)\s+publish)\b"
        ),
        "gh release write": rf"{_GH}\s+release\s+(?:create|upload|edit|delete)\b",
        "gh pr create/merge": rf"{_GH}\s+pr\s+(?:create|merge)\b",
        "gh repo create/delete": rf"{_GH}\s+repo\s+(?:create|delete)\b",
        "git push": rf"{_tool('git')}\s+push\b",
        "npm publish": rf"{_tool('npm')}\s+publish\b",
        "cargo publish": rf"{_tool('cargo')}\s+publish\b",
        "gem push": rf"{_tool('gem')}\s+push\b",
        "twine upload": rf"{_tool('twine')}\s+upload\b",
        "python publish": r"\b(?:uv|poetry|hatch)\s+publish\b",
        "cosign sign/attest": rf"{_tool('cosign')}\s+(?:sign|attest)",
        # gh api, curl or a wrapper; also Python's ["--method", "POST"].
        "write API call": (
            r"(?:-X|--method|--request)[\"']?[\s=,]+[\"']?(?:POST|PUT|PATCH|DELETE)\b"
        ),
        "gh workflow run": rf"{_GH}\s+workflow\s+run\b",
        "create-signed-commit": r"create-signed-commit\.sh",
    }.items()
}
# Comments and messages: a primitive named in a log line is not a call.
NOISE_LINE = re.compile(r"^\s*(?:#|echo\b|printf\b|log_\w+\b|die\b|:\s)")
SCRIPT_REF = re.compile(r"[\w$.{}/-]+\.(?:sh|py)\b")
# A value usable as one path segment when expanding ``${STEP}.sh``.
SEGMENT = re.compile(r"[\w.-]+")
_ACTION_PREFIX = r"^(?:\./(?:\.lgtm-ci-tooling/)?|lgtm-hq/lgtm-ci/)"
LOCAL_ACTION = re.compile(_ACTION_PREFIX + r"\.github/actions/([\w-]+)(?:@.*)?$")
# Scripts with a publishing mode switch: each publishes only when the step's
# env sets this variable to true (both default to false). An expression
# counts as true: the caller may pass true.
MODE_SWITCHES: dict[str, str] = {
    # build-docker.sh STEP=build adds --push only with PUSH=true.
    "actions/docker/build.sh": "PUSH",
    "release/update-changelog.sh": "PUSH",
}

# --- Implicit write API calls ------------------------------------------------
# `gh api` with a field or a request body POSTs unless the method is GET, and
# so does curl with a body or form. A GraphQL query (not a mutation) is a read.
# A call with an explicit method is judged by it ("write API call" above).
GH_API = re.compile(rf"{_GH}\s+api\b")
# Python argument lists: gh("api", ...) or ["gh", "api", ...].
PY_GH_API = re.compile(r"[\"']api[\"']\s*,[^\])]*", re.DOTALL)
GH_BODY = re.compile(
    r"(?:^|[\s\"'])(?:-f|-F|--field|--raw-field|--input)(?=[\s=\"']|$)",
)
METHOD = re.compile(r"(?:-X|--method|--request)[\"']?[\s=,]+[\"']?[A-Z]+\b")
CURL = re.compile(rf"{_tool('curl')}\s")
_CURL_BODY_FLAG = r"-d|--data(?:-\w+)?|-F|--form(?:-string)?|-T|--upload-file"
CURL_BODY = re.compile(rf"(?:^|\s)(?:{_CURL_BODY_FLAG})(?=[\s=]|$)")
CURL_GET = re.compile(r"(?:^|\s)(?:-G|--get)(?=\s|$)")
GRAPHQL_QUERY = re.compile(
    r"(?:-f|-F|--field|--raw-field)[\s=]+[\"']?query=(\S+)",
)

# --- Unknown executables -----------------------------------------------------
# A run: that executes a variable (or an input) the detector cannot resolve:
# the path comes from an input with no default, so the step must be listed.
_EXEC_PREFIX = (
    r"(?:^\s*|[;&|({]\s*|(?:^|[\s;&|(])(?:bash|sh|zsh|source|exec|python3?|"
    r"node|ruby|perl|pwsh|env)\s+(?:-\S+\s+)*|^\s*\.\s+)[\"']?[^\s\"';|&]*"
)


def _text(value: Any) -> str:
    return str(value).lower() if isinstance(value, bool) else str(value)


def load(path: Path) -> dict[str, Any]:
    """Parse one YAML file; an empty file is an empty mapping."""
    return yaml.safe_load(_read(path)) or {}


@functools.cache
def _read(path: Path) -> str:
    """Read a file once per session: scripts are shared by many steps."""
    return path.read_text(encoding="utf-8")


def _code(text: str) -> str:
    return "\n".join(line for line in text.splitlines() if not NOISE_LINE.match(line))


def _commands(code: str) -> Iterator[str]:
    """Split shell text into simple commands, outside quotes.

    Continuation lines are joined; ``;``, ``|``, ``&&``, ``||`` and newlines
    end a command.
    """
    current: list[str] = []
    quote = ""
    for char in re.sub(r"\\\n", " ", code):
        if quote:
            quote = "" if char == quote else quote
        elif char in "'\"":
            quote = char
        elif char in ";|&\n":
            yield "".join(current)
            current = []
            continue
        current.append(char)
    yield "".join(current)


def _assigned(text: str, name: str) -> str:
    """Return the start of what ``text`` assigns to ``name``, quotes stripped."""
    heredoc = r"(?:\$\(\s*cat\s+<<-?\s*['\"]?\w+['\"]?\s*)?"
    match = re.search(rf"\b{name}={heredoc}(.{{0,80}})", text, re.DOTALL)
    return match.group(1).lstrip("'\"\n ") if match else ""


def _is_graphql_read(command: str, text: str) -> bool:
    """Whether a ``gh api graphql`` call sends a query, not a mutation.

    Args:
        command: The ``gh api`` command.
        text: The whole file, to resolve ``query="$VAR"``.

    Returns:
        True only when the query text is visible and starts with ``query`` or
        ``{``; a request body from a file or an unresolved variable is not.
    """
    if not re.search(r"\bapi\s+[\"']?graphql\b", command) or "--input" in command:
        return False
    match = GRAPHQL_QUERY.search(command)
    if match is None:
        return False
    value = match.group(1).strip("'\"")
    variable = re.fullmatch(r"\$\{?(\w+)\}?", value)
    if variable:
        value = _assigned(text, variable.group(1))
    value = value.lstrip()
    return value.startswith(("query", "{")) and "mutation" not in value


def _implicit_writes(code: str) -> set[str]:
    """Return the implicit POSTs in shell or Python text (``gh api``, curl)."""
    found: set[str] = set()
    for command in _commands(code):
        if METHOD.search(command):
            continue
        gh_body = GH_API.search(command) and GH_BODY.search(command)
        if gh_body and not _is_graphql_read(command, code):
            found.add("implicit write API call (gh api with a body)")
        curl_body = CURL.search(command) and CURL_BODY.search(command)
        if curl_body and not CURL_GET.search(command):
            found.add("implicit write API call (curl with a body)")
    for match in PY_GH_API.finditer(code):
        call = " ".join(re.findall(r"[\"']([^\"']*)[\"']", match.group(0)))
        if GH_BODY.search(call) and not METHOD.search(call):
            found.add("implicit write API call (gh api with a body)")
    return found


@functools.cache
def _primitives(text: str) -> frozenset[str]:
    code = _code(text)
    items = PUBLISH_PRIMITIVES.items()
    found = {name for name, pattern in items if pattern.search(code)}
    return frozenset(found | _implicit_writes(code))


@dataclass(frozen=True)
class Scope:
    """What a step's expressions resolve against.

    Attributes:
        inputs: The workflow's (or composite action's) input specs.
        env: Workflow- and job-level env; the step's own env overrides it.
        bound: Whether each input's default is its value: true inside a
            composite action, where it is the caller's with: value. A
            workflow_call default is not: the caller may override it.
    """

    inputs: Mapping[str, Any]
    env: Mapping[str, Any]
    bound: bool = False


def _candidates(value: Any, inputs: Mapping[str, Any]) -> set[str]:
    """Return the literal values an env value can take, as far as we can tell.

    Args:
        value: The env value.
        inputs: Input specs; a referenced input contributes its default.

    Returns:
        The literal itself, or an expression's quoted strings and input defaults.
    """
    if value is None:
        return set()
    text = _text(value)
    if "${{" not in text:
        return {text}
    found = set(re.findall(r"'([^']*)'", text))
    for name in re.findall(r"\binputs\.([\w-]+)", text):
        default = (inputs.get(name) or {}).get("default")
        if default not in (None, ""):
            found.add(_text(default))
    return found


def _may_be_true(value: Any, scope: Scope) -> bool:
    """An unset or literal-false switch is off; an expression may be true."""
    text = _text(value).strip() if value is not None else ""
    bound = re.fullmatch(r"\$\{\{\s*inputs\.([\w-]+)\s*\}\}", text)
    if scope.bound and bound:
        value = (scope.inputs.get(bound.group(1)) or {}).get("default")
    if value is None:
        return False
    text = _text(value).strip()
    return "${{" in text or text == "true"


def _expand(token: str, env: Mapping[str, Any], inputs: Mapping[str, Any]) -> set[str]:
    """Substitute ``$VAR`` in a script path with each value the env gives it."""
    names = re.findall(r"\$\{?(\w+)\}?", token)
    pieces = re.split(r"\$\{?\w+\}?", token)
    choices = [
        sorted(filter(SEGMENT.fullmatch, _candidates(env.get(name), inputs))) or ["*"]
        for name in names
    ]
    paths = set()
    for combination in itertools.product(*choices):
        path = pieces[0]
        for choice, piece in zip(combination, pieces[1:], strict=True):
            path += choice + piece
        paths.add(path)
    return paths


@functools.cache
def _glob(pattern: str) -> frozenset[Path]:
    root = SCRIPTS_CI.resolve()
    hits = (Path(hit).resolve() for hit in glob.glob(pattern))
    return frozenset(p for p in hits if p.is_file() and root in p.parents)


def script_refs(
    text: str,
    base: Path | None,
    env: Mapping[str, Any],
    inputs: Mapping[str, Any],
) -> set[Path]:
    """Return the repo scripts under ``scripts/ci`` that ``text`` runs or sources.

    Args:
        text: A run: body, env value or script.
        base: The calling script's directory, for ``$SCRIPT_DIR/..`` paths.
        env: Env values, for a path built from a variable (``${STEP}.sh``).
        inputs: Input specs, for env values that name an input.

    Returns:
        The resolved scripts. A variable with no known value matches every
        script in that place, so a dispatcher is never skipped.
    """
    root = SCRIPTS_CI.resolve()
    found: set[Path] = set()
    for match in SCRIPT_REF.finditer(_code(text)):
        token = match.group(0)
        if "scripts/ci/" in token:
            bases, token = [root], token.split("scripts/ci/", 1)[1]
        else:
            token = re.sub(r"^\$\{?\w+\}?/", "", token).removeprefix("ci/")
            bases = [b for b in (base, root) if b is not None]
        for pattern in _expand(token, env, inputs):
            for directory in bases:
                found |= _glob(os.path.normpath(directory / pattern))
    return found


def _script_findings(
    paths: Collection[Path],
    env: Mapping[str, Any],
    scope: Scope,
) -> set[str]:
    """Return the publish primitives of the scripts and everything they call.

    Called and sourced repo scripts are followed transitively; each script is
    read once per step (``visited``) and once per session (:func:`_read`).
    """
    root = SCRIPTS_CI.resolve()
    found: set[str] = set()
    visited: set[Path] = set()
    pending = list(paths)
    while pending:
        path = pending.pop()
        if path in visited:
            continue
        visited.add(path)
        relative = path.relative_to(root).as_posix()
        switch = MODE_SWITCHES.get(relative)
        if switch is not None and not _may_be_true(env.get(switch), scope):
            continue
        text = _read(path)
        found |= {f"scripts/ci/{relative}: {name}" for name in _primitives(text)}
        pending.extend(script_refs(text, path.parent, env, scope.inputs) - visited)
    return found


def _unknown_executables(run: str, env: Mapping[str, Any], scope: Scope) -> set[str]:
    """Return the variables and inputs ``run`` executes that have no value.

    A variable whose env value reads an input with no default (or a composite
    action input the caller did not set) could name any script or command, so
    the detector cannot tell whether the step publishes.
    """
    found: set[str] = set()
    code = _code(run)
    for name, value in env.items():
        text = _text(value)
        if "inputs." not in text or _candidates(value, scope.inputs):
            continue
        pattern = rf"{_EXEC_PREFIX}\$\{{?{re.escape(str(name))}\b"
        if re.search(pattern, code, re.MULTILINE):
            found.add(f"run: unknown executable ${name} ({text.strip()})")
    inline = re.compile(rf"{_EXEC_PREFIX}\$\{{\{{\s*inputs\.([\w-]+)", re.MULTILINE)
    for match in inline.finditer(code):
        if not _candidates(f"${{{{ inputs.{match.group(1)} }}}}", scope.inputs):
            found.add(f"run: unknown executable inputs.{match.group(1)}")
    return found


def _uses_publishes(step: Step, scope: Scope) -> bool:
    uses = str(step.get("uses", ""))
    if not uses.startswith(PUBLISHER_USES):
        return False
    with_ = step.get("with") or {}
    return not any(
        uses.startswith(prefix) and not _may_be_true(with_.get(key, default), scope)
        for prefix, (key, default) in USES_MODE_SWITCHES.items()
    )


def _action_findings(name: str, with_: Mapping[str, Any]) -> set[str]:
    """Return the findings of a local composite action's steps (one level)."""
    path = ACTIONS / name / "action.yml"
    if not path.is_file():
        return set()
    document = load(path)
    specs = document.get("inputs") or {}
    # The caller's with: value replaces the input's default.
    inputs = {
        key: {"default": with_[key]} if key in with_ else (spec or {})
        for key, spec in specs.items()
    }
    scope = Scope(inputs=inputs, env={}, bound=True)
    return {
        f"{name}: {finding}"
        for step in (document.get("runs") or {}).get("steps") or []
        for finding in findings(step, scope, follow_actions=False)
    }


def findings(step: Step, scope: Scope, *, follow_actions: bool = True) -> set[str]:
    """Return why ``step`` publishes: empty when it does not.

    Args:
        step: The step.
        scope: The workflow inputs and the env the step inherits.
        follow_actions: Whether to look inside a local composite action.

    Returns:
        One entry per publishing action or primitive found in the step's
        ``uses:``, ``run:``, env values (its own and, for a ``run:`` step that
        reads them or calls a repo script, the job's and workflow's), and the
        repo scripts they call; plus each
        executable the step runs from an input with no default.
    """
    found: set[str] = set()
    uses = str(step.get("uses", ""))
    if _uses_publishes(step, scope):
        found.add(f"uses: {uses}")
    own_env = step.get("env") or {}
    env = {**scope.env, **own_env}
    run = str(step.get("run", ""))
    texts = [run]
    refs = script_refs(run, None, env, scope.inputs)
    for key, value in env.items():
        # Job and workflow env reach a run: step's shell: scan a value the run
        # reads, and every value when it calls a repo script (which may).
        reads = re.search(rf"\$\{{?{re.escape(str(key))}\b", _code(run))
        if key in own_env or ("run" in step and (reads or refs)):
            texts.extend({_text(value), *_candidates(value, scope.inputs)})
    for text in texts:
        found |= {f"run: {name}" for name in _primitives(text)}
        refs |= script_refs(text, None, env, scope.inputs)
    found |= _script_findings(refs, env, scope)
    found |= _unknown_executables(run, env, scope)
    action = LOCAL_ACTION.match(uses)
    if follow_actions and action:
        found |= _action_findings(action.group(1), step.get("with") or {})
    return found


def publish_steps(
    document: Mapping[Any, Any],
    workflow: str,
) -> dict[StepKey, set[str]]:
    """Return every publishing step of the workflow's verified jobs.

    Every step of every job with the verify step is scanned, however the job
    gets its credentials (job or workflow permissions, write-all, a secret).

    Args:
        document: The parsed workflow.
        workflow: Its file name.

    Returns:
        ``(workflow, job, step name)`` mapped to the findings.
    """
    triggers = document.get("on") or document.get(True) or {}
    inputs: dict[str, Any] = {}
    if isinstance(triggers, dict):
        for trigger in ("workflow_call", "workflow_dispatch"):
            inputs |= (triggers.get(trigger) or {}).get("inputs") or {}
    flagged: dict[StepKey, set[str]] = {}
    for job_id, job in (document.get("jobs") or {}).items():
        steps = job.get("steps") or []
        if not any(step.get("name") == NAME for step in steps):
            continue
        inherited = {**(document.get("env") or {}), **(job.get("env") or {})}
        scope = Scope(inputs, inherited)
        for step in steps:
            if found := findings(step, scope):
                flagged[(workflow, str(job_id), str(step.get("name")))] = found
    return flagged


def unguarded_publishers(
    document: Mapping[Any, Any],
    workflow: str,
    guarded: Collection[StepKey] = PRE_PUBLISH,
    allowed: Collection[StepKey] = tuple(ALLOWED_UNGUARDED),
) -> list[str]:
    """Return the publishing steps in neither ``guarded`` nor ``allowed``."""
    return [
        f"{key[0]} {key[1]} {key[2]!r}: {sorted(found)}"
        for key, found in publish_steps(document, workflow).items()
        if key not in guarded and key not in allowed
    ]


def workflow_paths() -> list[Path]:
    """Return the workflows and caller-owned examples, in a stable order."""
    return [*sorted(WORKFLOWS.glob("*.y*ml")), *sorted(EXAMPLES.glob("*.y*ml"))]


@functools.cache
def all_publish_steps() -> dict[StepKey, frozenset[str]]:
    """Return the publishing steps of every workflow and example."""
    flagged: dict[StepKey, frozenset[str]] = {}
    for path in workflow_paths():
        for key, found in publish_steps(load(path), path.name).items():
            flagged[key] = frozenset(found)
    return flagged
