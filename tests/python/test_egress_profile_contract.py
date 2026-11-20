# SPDX-License-Identifier: MIT
"""The egress profiles rendered from this repository's own tree (#1597).

``render-egress-profile.py`` writes a copy of the workflow tree under a
profile chosen when the copy is generated. This module renders every profile
in memory and pins:

- ``block``: the repository itself is the block profile, byte for byte, over
  a file surface this test lists on its own; nothing in the repository runs
  the generator or the notice, so no run-time switch exists;
- ``audit`` and ``none``: every job that runs harden-runner in the source has
  the notice step (but the listed exceptions), no step references a removed
  step, the publish steps keep their conditions, every other step is
  unchanged, input descriptions claim no enforcement, and the result passes
  actionlint through lintro;
- ``none``: no harden-runner or runner-policy step remains, and nothing in a
  workflow, example or action contacts or names the StepSecurity API.
"""

from __future__ import annotations

import copy
import os
import re
import shutil
import subprocess
from collections.abc import Callable, Iterator
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
import yaml
from assertpy import assert_that
from harden_runner_publishers import (
    NAME,
    PRE_PUBLISH,
    PRE_PUBLISH_PREFIX,
    RECHECK_NAME,
    VERIFY_ID,
)

SCRIPT_PATH = "scripts/ci/bootstrap/render-egress-profile.py"
GENERATOR_FILES = (
    SCRIPT_PATH,
    "scripts/ci/bootstrap/egress_profile_rewrite.py",
    "scripts/ci/bootstrap/egress-profile-notice.sh",
)
ROOT = Path(__file__).resolve().parents[2]
HARDEN = "step-security/harden-runner@"
NOTICE_NAME = "Report egress not enforced"
NOTICE_BLOCK = "egress-profile-notice"
# Data, never run: the module-length check's list names every long module
# under scripts/ci by path, the generator's two modules among them (#1626).
LENGTH_EXCEPTIONS = "scripts/ci/quality/module-length-exceptions.txt"
# Files that name the notice block as data, so the validators accept it in a
# generated copy (#1688). Each reads the source body; none runs it.
NAMES_THE_NOTICE = {
    "scripts/ci/bootstrap/sync_inline_blocks.py": "PROFILE_BLOCKS: its id and source",
    "scripts/ci/quality/tooling_app_ambient.py": "PRE_MINT_BLOCKS: its env: keys",
}
MARKER = ".lgtm-ci-egress-profile.json"
STEP_REF = re.compile(r"\bsteps\.([A-Za-z0-9_-]+)")
EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.S)
# The surface a copy holds, listed here rather than read from the generator.
EXPECTED_SURFACE = (
    "scripts",
    "schemas",
    "examples",
    ".github/workflows",
    ".github/actions",
    ".github/actionlint.yaml",
)
CACHES = {"__pycache__", ".pytest_cache", ".ruff_cache", ".mypy_cache"}
# Jobs that run harden-runner but cannot carry a run step, so get no notice.
NO_NOTICE = {
    (".github/workflows/reusable-scorecards.yml", "scorecards"): (
        "ossf/scorecard-action with publish_results accepts only uses: steps"
        " in its job; under none its harden-runner step is removed"
    ),
}
# Steps each profile removes besides harden-runner, verify and recheck.
REMOVED = {
    "audit": {"Summarize blocked egress"},
    "none": {
        "Summarize blocked egress",
        "Fail on unknown egress-preset",
        "Wait for hardener Docker readiness",
        "Refuse block egress on runners that cannot enforce it",
    },
}
# Agent checks the verify and recheck bodies run; none may survive.
ENFORCEMENT_CHECKS = (
    "agent.service",
    "agent.status",
    '"egress_policy":"block"',
    "DNS=127.0.0.1",
    "lgtm-ci-inline:begin verify-harden-runner-agent",
    "lgtm-ci-inline:begin recheck-harden-runner-agent",
    "STEP: summarize-blocked-egress",
)
EGRESS_INPUT = re.compile(
    r"^(?:[a-z]+-)?(?:egress-policy|egress-preset|allowed-endpoints)(?:-[a-z]+)?$",
)
STALE_CLAIM = re.compile(
    r"block only|audit rejected|enforced at job|enforced \(#913\)"
    r"|so it is enforced(?! only in a block-profile copy)",
    re.I,
)
INPUT_REF = "${{ inputs.egress-policy }}"
PRIVATE_REF = "${{ github.event.repository.private }}"
PROFILES = ("audit", "none")

Tree = dict[str, Any]
REWRITTEN = (".github/workflows/", "examples/")
YAML = (".yml", ".yaml")


@pytest.fixture(name="render", scope="module")
def fixture_render(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the renderer without running it."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="trees", scope="module")
def fixture_trees(render: ModuleType) -> dict[str, dict[str, bytes]]:
    """Every profile rendered in memory."""
    return {str(p): dict(render.render_tree(p)) for p in render.Profile}


@pytest.fixture(name="block", scope="module")
def fixture_block(trees: dict[str, dict[str, bytes]]) -> dict[str, bytes]:
    """The block profile."""
    return trees["block"]


def _workflows(tree: dict[str, bytes]) -> dict[str, Tree]:
    """Parse every rewritten workflow or example of a rendered tree."""
    return {
        path: yaml.safe_load(data)
        for path, data in tree.items()
        if path.startswith(REWRITTEN) and path.endswith(YAML)
    }


def _job_map(documents: dict[str, Tree]) -> dict[tuple[str, str], dict[str, Any]]:
    return {
        (path, str(job_id)): job
        for path, document in documents.items()
        for job_id, job in ((document or {}).get("jobs") or {}).items()
    }


def _jobs(documents: dict[str, Tree]) -> Iterator[tuple[str, str, list[Any]]]:
    for (path, job_id), job in _job_map(documents).items():
        yield path, job_id, job.get("steps") or []


def _has(steps: list[Any], name: str) -> bool:
    """Return whether a job has a step with this name."""
    return any(step.get("name") == name for step in steps)


def _is_harden(step: Any) -> bool:
    return str(step.get("uses", "")).startswith(HARDEN)


def _steps(job: dict[str, Any]) -> list[Any]:
    return list(job.get("steps") or [])


def _any_harden(job: dict[str, Any]) -> bool:
    return any(_is_harden(step) for step in _steps(job))


def _strings(value: Any) -> Iterator[str]:
    """Yield every string nested in a YAML value."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from _strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from _strings(item)


def _inputs(document: Tree) -> Iterator[tuple[str, dict[str, Any]]]:
    """Yield every workflow_call and workflow_dispatch input declaration."""
    mapping: dict[Any, Any] = document or {}
    triggers = mapping.get(True) or mapping.get("on") or {}
    if not isinstance(triggers, dict):
        return
    for trigger in ("workflow_call", "workflow_dispatch"):
        for name, spec in ((triggers.get(trigger) or {}).get("inputs") or {}).items():
            if isinstance(spec, dict):
                yield str(name), spec


# --- block: the repository is the block profile ------------------------------


def _expected_surface() -> list[str]:
    """Every file of the copy's surface, walked here without the generator."""
    found: list[str] = []
    for entry in EXPECTED_SURFACE:
        top = ROOT / entry
        if top.is_file():
            found.append(entry)
            continue
        for directory, dirs, files in os.walk(top):
            dirs[:] = [d for d in dirs if d not in CACHES]
            for name in files:
                if not name.endswith(".pyc"):
                    found.append((Path(directory) / name).relative_to(ROOT).as_posix())
    return sorted(found)


def test_repository_tree_equals_the_block_profile(block: dict[str, bytes]) -> None:
    """Every surface file is in the copy, byte for byte, plus the marker."""
    files = {path: data for path, data in block.items() if path != MARKER}
    assert_that(sorted(files)).is_equal_to(_expected_surface())
    differing = [p for p, data in files.items() if (ROOT / p).read_bytes() != data]
    assert_that(differing).is_empty()
    if shutil.which("git") is None or not (ROOT / ".git").exists():
        pytest.skip("git is required to compare with the tracked files")
    tracked = subprocess.run(  # noqa: S603, S607
        ["git", "-C", str(ROOT), "ls-files", "--", *EXPECTED_SURFACE],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    assert_that(sorted(set(tracked) - set(files))).is_empty()


def test_every_profile_records_itself(trees: dict[str, dict[str, bytes]]) -> None:
    """The marker names the profile and the generator, with no timestamp."""
    for profile, tree in trees.items():
        marker = yaml.safe_load(tree[MARKER])
        assert_that(marker).contains_entry({"profile": profile})
        assert_that(marker["generator"]).ends_with("render-egress-profile.py")
        assert_that(set(marker)).is_equal_to({"generator", "profile", "source-commit"})
        for path, data in _workflows(tree).items():
            first = tree[path].split(b"\n", 1)[0].decode()
            if profile == "block":
                assert_that(first).does_not_contain("egress profile")
            else:
                wanted = f"egress profile {profile}"
                assert_that(first, description=path).contains(wanted)
            assert_that(data).is_not_none()


def _repository_files() -> Iterator[Path]:
    """Yield every file and symlink of the source tree outside VCS and caches."""
    skipped = {".git", ".venv", "node_modules", *CACHES}
    for directory, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in skipped]
        base = Path(directory)
        yield from (base / name for name in files)
        yield from (base / d for d in dirs if (base / d).is_symlink())


def _without_entry_paths(text: str) -> str:
    """Drop the path field of each ``path reason`` entry; keep reasons and comments."""
    kept = []
    for line in text.splitlines():
        # The list parser splits on any whitespace, so drop the path the same way.
        fields = line.split(maxsplit=1)
        is_entry = line.startswith("scripts/") and len(fields) > 1
        kept.append(fields[1] if is_entry else line)
    return "\n".join(kept)


def test_nothing_in_the_repository_runs_the_generator_or_the_notice() -> None:
    """No run-time switch: the profile exists only when a copy is generated.

    No workflow, composite action, example, schema or script names the
    generator, its rewrite module or the notice script (by content), no link
    anywhere points at them, and no workflow carries the notice block id.
    The files in ``NAMES_THE_NOTICE`` may name the notice, and only the
    notice: they hold it as data for the validators of a copy.
    """
    names = re.compile(
        r"render-egress-profile|egress_profile_rewrite|egress-profile-notice"
        r"|egress-audit-notice",
    )
    targets = {(ROOT / path).resolve() for path in GENERATOR_FILES}
    mentions: list[str] = []
    links: list[str] = []
    for path in _repository_files():
        relative = path.relative_to(ROOT).as_posix()
        if path.is_symlink():
            if path.resolve() in targets:
                links.append(relative)
            continue
        if relative in (*GENERATOR_FILES, *NAMES_THE_NOTICE) or not relative.startswith(
            (".github/", "examples/", "schemas/", "scripts/"),
        ):
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if relative == LENGTH_EXCEPTIONS:
            text = _without_entry_paths(text)
        if names.search(text):
            mentions.append(relative)
    assert_that(mentions).is_empty()
    assert_that(links).is_empty()
    others = re.compile(
        r"render-egress-profile|egress_profile_rewrite|egress-audit-notice",
    )
    for relative in NAMES_THE_NOTICE:
        text = (ROOT / relative).read_text(encoding="utf-8")
        assert_that(others.search(text), description=relative).is_none()
        assert_that(text, description=relative).contains(f'"{NOTICE_BLOCK}"')


def test_block_policies_cannot_be_switched_at_run_time(
    render: ModuleType,
    block: dict[str, bytes],
) -> None:
    """Every harden step asks for block or the input the verify step rejects."""
    policies = {
        str(step["with"]["egress-policy"])
        for _path, _job, steps in _jobs(_workflows(block))
        for step in steps
        if _is_harden(step)
    }
    assert_that(policies).is_subset_of({"block", INPUT_REF})
    bodies = render.REWRITE.inline_bodies()
    verify_body = "\n".join(bodies["verify-harden-runner-agent"])
    assert_that(verify_body).contains('if [[ "${EGRESS_POLICY:-}" != block ]]; then')
    for path in GENERATOR_FILES[:2]:
        source = (ROOT / path).read_text(encoding="utf-8")
        for runtime_input in ("environ", "getenv", "vars.", "secrets."):
            assert_that(source).does_not_contain(runtime_input)


# --- audit and none: the generated copies ------------------------------------


@pytest.mark.parametrize("profile", PROFILES)
def test_every_hardened_job_gets_the_notice(
    trees: dict[str, dict[str, bytes]],
    profile: str,
) -> None:
    """Start from harden-runner: each job that ran it has the notice, or is listed.

    The notice takes the verify step's place, id and if:. The listed jobs are
    exactly the hardened jobs that cannot carry it.
    """
    source = _job_map(_workflows(trees["block"]))
    generated = _job_map(_workflows(trees[profile]))
    hardened = {key for key, job in source.items() if _any_harden(job)}
    assert_that(len(hardened)).is_greater_than(100)
    problems: list[str] = []
    without: set[tuple[str, str]] = set()
    for key in sorted(hardened):
        before = source[key]["steps"]
        after = generated[key]["steps"]
        if not _has(after, NOTICE_NAME):
            without.add(key)
            continue
        if not _has(before, NAME):
            problems.append(f"{key}: notice without a verify step in the source")
            continue
        old = next(s for s in before if s.get("name") == NAME)
        new = next(s for s in after if s.get("name") == NOTICE_NAME)
        if new.get("id") != VERIFY_ID or new.get("if") != old.get("if"):
            problems.append(f"{key}: notice id or if: differs from the verify step")
    assert_that(problems).is_empty()
    assert_that(without).is_equal_to(set(NO_NOTICE))
    noticed = {k for k, job in generated.items() if _has(_steps(job), NOTICE_NAME)}
    assert_that(noticed).is_subset_of(hardened)


@pytest.mark.parametrize("profile", PROFILES)
def test_notice_steps_carry_the_generated_body(
    render: ModuleType,
    trees: dict[str, dict[str, bytes]],
    profile: str,
) -> None:
    """Every notice runs exactly the notice body, with the profile and #1552 env."""
    body = "\n".join(render.REWRITE.inline_bodies()[NOTICE_BLOCK])
    begin = f"# lgtm-ci-inline:begin {NOTICE_BLOCK}"
    end = f"# lgtm-ci-inline:end {NOTICE_BLOCK}"
    expected = f"{begin}\n{body}\n{end}\n"
    notices = [
        (path, job, step)
        for path, job, steps in _jobs(_workflows(trees[profile]))
        for step in steps
        if step.get("name") == NOTICE_NAME
    ]
    assert_that(notices).is_not_empty()
    assert_that([n[:2] for n in notices if n[2].get("run") != expected]).is_empty()
    policies = {"audit", INPUT_REF} if profile == "audit" else {"none"}
    bad_env = [
        (path, job, step.get("env"))
        for path, job, step in notices
        if (step.get("env") or {}).get("EGRESS_PROFILE") != profile
        or step["env"].get("REPOSITORY_PRIVATE") != PRIVATE_REF
        or step["env"].get("EGRESS_POLICY") not in policies
        or set(step["env"]) != {"EGRESS_PROFILE", "EGRESS_POLICY", "REPOSITORY_PRIVATE"}
    ]
    assert_that(bad_env).is_empty()
    assert_that(body).contains('"${REPOSITORY_PRIVATE:-}" == false')


@pytest.mark.parametrize("profile", PROFILES)
def test_no_block_request_and_no_agent_check(
    trees: dict[str, dict[str, bytes]],
    profile: str,
) -> None:
    """No egress-policy block, no verify, recheck or removed step, no agent check."""
    problems: list[str] = []
    for path, data in trees[profile].items():
        if not path.startswith(REWRITTEN) or not path.endswith(YAML):
            continue
        text = data.decode("utf-8")
        if re.search(
            r"^[ \t-]*['\"]?(egress-policy|EGRESS_POLICY)['\"]?\s*:\s*['\"]?block",
            text,
            re.M,
        ):
            problems.append(f"{path}: egress-policy block")
        found = [check for check in ENFORCEMENT_CHECKS if check in text]
        problems.extend(f"{path}: {check}" for check in found)
    removed = {NAME, *REMOVED[profile]}
    for path, job, steps in _jobs(_workflows(trees[profile])):
        for step in steps:
            name = str(step.get("name", ""))
            if name in removed or name.startswith(RECHECK_NAME):
                problems.append(f"{path} {job}: {name}")
            uses = str(step.get("uses", ""))
            policy = uses.endswith("/validate-runner-policy")
            if profile == "none" and (uses.startswith("step-security/") or policy):
                problems.append(f"{path} {job}: {uses}")
    assert_that(problems).is_empty()


@pytest.mark.parametrize("profile", PROFILES)
def test_inputs_default_to_the_profile_and_claim_no_enforcement(
    trees: dict[str, dict[str, bytes]],
    profile: str,
) -> None:
    """egress-policy defaults to the profile; no egress input says it is enforced."""
    defaults: list[Any] = []
    problems: list[str] = []
    for path, document in _workflows(trees[profile]).items():
        for name, spec in _inputs(document):
            description = str(spec.get("description", ""))
            if STALE_CLAIM.search(description):
                problems.append(f"{path} {name}: {description!r}")
            if not EGRESS_INPUT.match(name):
                continue
            if name == "egress-policy":
                defaults.append(spec.get("default"))
            if profile == "none" and not description.startswith("Ignored in this copy"):
                problems.append(f"{path} {name}: not marked ignored")
    assert_that(len(defaults)).is_greater_than(50)
    assert_that(set(defaults)).is_equal_to({profile})
    assert_that(problems).is_empty()


def _refs(value: Any, *, bare: bool) -> set[str]:
    """Return the step ids a value references (inside ``${{ }}`` unless bare)."""
    found: set[str] = set()
    for text in _strings(value):
        for expression in [text] if bare else EXPRESSION.findall(text):
            found.update(STEP_REF.findall(expression))
    return found


@pytest.mark.parametrize("profile", PROFILES)
def test_step_references_resolve(
    trees: dict[str, dict[str, bytes]],
    profile: str,
) -> None:
    """Every ``steps.<id>`` in a step (run:, env:, with:, if: ...) is an earlier step.

    Job ``outputs:`` may reference any step of the job.
    """
    problems: list[str] = []
    for (path, job_id), job in _job_map(_workflows(trees[profile])).items():
        steps = job.get("steps") or []
        ids = {str(step["id"]) for step in steps if step.get("id")}
        for ref in _refs(job.get("outputs") or {}, bare=False) - ids:
            problems.append(f"{path} {job_id} outputs: steps.{ref}")
        seen: set[str] = set()
        for step in steps:
            refs = _refs({k: v for k, v in step.items() if k != "if"}, bare=False)
            refs |= _refs(step.get("if", ""), bare=True)
            name = step.get("name")
            problems.extend(f"{path} {job_id} {name!r}: steps.{r}" for r in refs - seen)
            if step.get("id"):
                seen.add(str(step["id"]))
    assert_that(problems).is_empty()


@pytest.mark.parametrize("profile", PROFILES)
def test_publish_steps_keep_their_conditions(
    trees: dict[str, dict[str, bytes]],
    profile: str,
) -> None:
    """Each listed publish step is unchanged and follows what preceded its recheck."""
    source = _by_file_name(trees["block"])
    generated = _by_file_name(trees[profile])
    problems: list[str] = []
    for workflow, job, name in PRE_PUBLISH:
        before = source[(workflow, job)]
        after = generated[(workflow, job)]
        old = [s.get("name") for s in before].index(name)
        new = [s.get("name") for s in after].index(name)
        if before[old] != after[new]:
            problems.append(f"{workflow} {job} {name!r}: step changed")
        if before[old - 1].get("name") != f"{PRE_PUBLISH_PREFIX}{name}":
            problems.append(f"{workflow} {job} {name!r}: no recheck in the source")
            continue
        earlier = [s for s in before[: old - 1] if not _is_recheck(s)]
        kept = [s.get("name") for s in earlier if not _gone(s, profile)]
        wanted = kept[-1] if kept else None
        wanted = NOTICE_NAME if wanted == NAME else wanted
        if (after[new - 1].get("name") if new else None) != wanted:
            problems.append(f"{workflow} {job} {name!r}: preceded by {after[new - 1]}")
    assert_that(problems).is_empty()


def _by_file_name(tree: dict[str, bytes]) -> dict[tuple[str, str], list[Any]]:
    """Return each job's steps keyed by (workflow file name, job id)."""
    return {(p.rsplit("/", 1)[-1], j): s for p, j, s in _jobs(_workflows(tree))}


def _gone(step: Any, profile: str) -> bool:
    """Return whether a profile removes a source step (verify and recheck aside)."""
    if str(step.get("name", "")) in REMOVED[profile]:
        return True
    uses = str(step.get("uses", ""))
    policy = uses.endswith("/validate-runner-policy")
    return profile == "none" and (_is_harden(step) or policy)


def _is_recheck(step: Any) -> bool:
    return str(step.get("name", "")).startswith(RECHECK_NAME)


def _expected(value: Any, profile: str) -> Any:
    """Apply a profile's value changes to a parsed source node."""
    if isinstance(value, list):
        return [_expected(item, profile) for item in value]
    if not isinstance(value, dict):
        return value
    out = {key: _expected(item, profile) for key, item in value.items()}
    for key in ("egress-policy", "EGRESS_POLICY"):
        if out.get(key) == "block" or (profile == "none" and out.get(key) == INPUT_REF):
            out[key] = profile
    if str(out.get("uses", "")).endswith("/validate-runner-policy") and (
        (out.get("with") or {}).get("tier") in ("strict", "hardened")
    ):
        out["with"]["tier"] = "permissive"
    return out


def _normalise(document: Tree, profile: str | None) -> Tree:
    """Drop input descriptions; turn verify and notice steps into one token."""
    document = copy.deepcopy(document) or {}
    for _name, spec in _inputs(document):
        spec.pop("description", None)
        if _name == "egress-policy" and profile and spec.get("default") == "block":
            spec["default"] = profile
    for job in (document.get("jobs") or {}).values():
        steps = job.get("steps")
        if steps is None:
            continue
        kept = []
        for step in steps:
            name = str(step.get("name", ""))
            if profile and (name.startswith(RECHECK_NAME) or _gone(step, profile)):
                continue
            kept.append("NOTICE" if name in (NAME, NOTICE_NAME) else step)
        job["steps"] = kept
    return document


def _actual(document: Tree) -> Tree:
    """Normalise a generated document."""
    return _normalise(document, None)


@pytest.mark.parametrize("profile", PROFILES)
def test_nothing_else_changes(trees: dict[str, dict[str, bytes]], profile: str) -> None:
    """Apart from the documented rewrites, every workflow parses to the source."""
    source = _workflows(trees["block"])
    generated = _workflows(trees[profile])
    assert_that(sorted(generated)).is_equal_to(sorted(source))
    differing = [
        path
        for path, document in source.items()
        if _normalise(_expected(document, profile), profile) != _actual(generated[path])
    ]
    assert_that(differing).is_empty()


def test_none_names_and_contacts_no_stepsecurity_api(
    trees: dict[str, dict[str, bytes]],
) -> None:
    """No step-security action and no StepSecurity host in a none copy.

    The generator's own disclosure text (for the audit profile) is the only
    file allowed to name the host; nothing runs it in a job.
    """
    found = [
        path
        for path, data in trees["none"].items()
        if path not in GENERATOR_FILES
        and re.search(rb"stepsecurity\.io|uses:\s*['\"]?step-security/", data, re.I)
    ]
    assert_that(found).is_empty()


@pytest.mark.parametrize("profile", PROFILES)
def test_tree_passes_actionlint(
    render: ModuleType,
    tmp_path: Path,
    profile: str,
) -> None:
    """The generated workflows and examples pass actionlint through lintro.

    actionlint reads ``.github/actionlint.yaml`` from the git project it runs
    in, so the copy is made a repository first. Skipped where actionlint is
    not installed (lintro reports it missing rather than linting).
    """
    if any(shutil.which(tool) is None for tool in ("actionlint", "git", "uv")):
        pytest.skip("actionlint, git and uv are required to lint the generated copy")
    out = tmp_path.resolve() / "copy"
    assert_that(render.main(["--profile", profile, "--out", str(out)])).is_equal_to(0)
    subprocess.run(["git", "init", "-q", str(out)], check=True)  # noqa: S603, S607
    result = subprocess.run(  # noqa: S603
        [
            shutil.which("uv") or "uv",
            "run",
            "--project",
            str(ROOT),
            "lintro",
            "chk",
            "--tools",
            "actionlint",
            ".github/workflows",
            "examples",
        ],
        cwd=out,
        capture_output=True,
        text=True,
        check=False,
    )
    lines = result.stdout.splitlines()
    summary = [line for line in lines if line.startswith("Issues:")]
    assert_that(summary, description=result.stdout[-4000:]).is_equal_to(
        ["Issues: 0 errors, 0 warnings, 0 info"],
    )
    assert_that(result.returncode).is_equal_to(0)
