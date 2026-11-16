# SPDX-License-Identifier: MIT
"""Never hold a caller-chosen Python to 3.11 (#1591).

A job that installs the Python version the caller chose (the matrix of
``reusable-test-python.yml``, the dist build, the PyPI upload) runs the
caller's project on that interpreter. ``run_python``, ``require_python``
and ``pin_python_from_path`` (``scripts/ci/lib/python.sh``) refuse anything
older than 3.11, so no lgtm-ci script reached after such an install may call
them: a caller testing on 3.10 would be stopped by lgtm-ci, not by their own
code. A job that also needs lgtm-ci Python must use a separate interpreter.

Everything is derived from the files:

* An *install step* is a step that uses the ``setup-python`` composite
  action (any ref), ``actions/setup-python``, or runs
  ``scripts/ci/actions/setup-python.sh`` with ``STEP: python-install``. A
  step that uses a local composite action containing an install step is one
  too.
* A unit is a workflow job or a composite action. From its first install
  step on, every ``scripts/ci`` path named in a step (``run``, ``env``,
  ``with``) is reached, and so is every script of a local composite action
  the step uses.
* A reached shell script reaches the scripts it names (``source``,
  ``bash``, a direct call), resolved against its own directory first.

The only hand-written list is ``ANCHORS``: the scripts the issue names,
which the derivation must find, so a change that breaks the walk fails here
instead of passing with nothing checked.

What this does not see: a script path that only arrives at run time (an
input such as ``audit-script`` whose default lives in ``inputs``, a path
built from pieces), a script started from Python (``subprocess``), a called
reusable workflow (a separate job, with its own install if any), and a call
through some other wrapper name.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Iterator
from pathlib import Path
from typing import Any

import pytest
import yaml
from assertpy import assert_that

REPO = Path(__file__).resolve().parents[2]

#: Scripts the rule names; the derivation must reach each of them.
ANCHORS = (
    "scripts/ci/actions/run-pytest.sh",
    "scripts/ci/actions/python-dist.sh",
)
#: The unit the rule names; it must be found as installing caller Python.
ANCHOR_UNIT = "workflows/reusable-test-python.yml:test"

GUARDED = re.compile(r"\b(run_python|require_python|pin_python_from_path)\b")
SHELL_VAR = re.compile(r"\$\{[^}]*\}|\$\w+")
SCRIPT_REF = re.compile(r"(?<![\w.-])((?:[\w.-]+/)*[\w.-]+\.(?:sh|py))\b")
CI_REF = re.compile(r"(?:^|/)(ci/[\w./-]+?\.(?:sh|py))\b")
LOCAL_ACTION = re.compile(r"(?:^|/)\.github/actions/([\w.-]+)$")
SETUP_ACTION = re.compile(r"(?:^|/)\.github/actions/setup-python$")


def load(path: Path) -> dict[Any, Any]:
    """Parse one workflow or action file.

    Args:
        path: The YAML file to read.

    Returns:
        The parsed document, or an empty mapping for a non-mapping file.
    """
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    return document if isinstance(document, dict) else {}


def strings(value: Any) -> Iterator[str]:
    """Yield every string inside a YAML value, keys excluded.

    Args:
        value: A parsed YAML node.

    Yields:
        Each string leaf.
    """
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


class Tree:
    """The workflows, composite actions and scripts under one checkout.

    Args:
        root: The repository root.
    """

    def __init__(self, root: Path) -> None:
        self.root = root
        self.scripts = root / "scripts"
        self.actions: dict[str, list[dict[str, Any]]] = {}
        for path in sorted((root / ".github" / "actions").glob("*/action.y*ml")):
            runs = load(path).get("runs") or {}
            self.actions[path.parent.name] = list(runs.get("steps") or [])
        self.units: dict[str, list[dict[str, Any]]] = {}
        for path in sorted((root / ".github" / "workflows").glob("*.y*ml")):
            for job_id, job in (load(path).get("jobs") or {}).items():
                if isinstance(job, dict):
                    steps = list(job.get("steps") or [])
                    self.units[f"workflows/{path.name}:{job_id}"] = steps
        for name, steps in self.actions.items():
            self.units[f"actions/{name}"] = steps

    def local_action(self, step: dict[str, Any]) -> str | None:
        """Name the local composite action a step uses, if any.

        Args:
            step: One step mapping.

        Returns:
            The action directory name, or None.
        """
        uses = str(step.get("uses") or "").split("@", 1)[0]
        match = LOCAL_ACTION.search(uses)
        if match and match.group(1) in self.actions:
            return match.group(1)
        return None

    def installs(
        self,
        step: dict[str, Any],
        seen: frozenset[str] = frozenset(),
    ) -> bool:
        """Tell whether a step installs the caller's Python.

        Args:
            step: One step mapping.
            seen: Composite actions already on the path (cycle guard).

        Returns:
            True for an install step, directly or through a composite action.
        """
        uses = str(step.get("uses") or "").split("@", 1)[0]
        if uses == "actions/setup-python" or SETUP_ACTION.search(uses):
            return True
        env = step.get("env") or {}
        run = str(step.get("run") or "")
        if "ci/actions/setup-python.sh" in run and env.get("STEP") == "python-install":
            return True
        action = self.local_action(step)
        if action is None or action in seen:
            return False
        return any(self.installs(s, seen | {action}) for s in self.actions[action])

    def step_scripts(self, step: dict[str, Any], seen: set[str]) -> set[Path]:
        """Collect the scripts a step names, composite actions included.

        Args:
            step: One step mapping.
            seen: Composite actions already walked.

        Returns:
            The script files the step reaches directly.
        """
        found: set[Path] = set()
        for text in strings(step):
            for ref in CI_REF.findall(text):
                path = self.scripts / ref
                if path.is_file():
                    found.add(path)
        action = self.local_action(step)
        if action is not None and action not in seen:
            seen.add(action)
            for inner in self.actions[action]:
                found |= self.step_scripts(inner, seen)
        return found

    def resolve(self, origin: Path, ref: str) -> set[Path]:
        """Resolve a script path written inside a shell script.

        Args:
            origin: The script that names ``ref``.
            ref: The relative tail of the path, e.g. ``../lib/python.sh``.

        Returns:
            The files ``ref`` can mean: the one relative to ``origin``'s
            directory when it exists, else every script under ``scripts/``
            whose path ends with ``ref`` (with ``../`` dropped).
        """
        direct = (origin.parent / ref).resolve()
        if direct.is_file():
            return {direct}
        tail = "/" + "/".join(p for p in ref.split("/") if p not in ("", ".", ".."))
        return {
            path.resolve()
            for path in self.scripts.rglob(tail.rsplit("/", 1)[-1])
            if path.is_file() and str(path).endswith(tail)
        }

    def closure(self, start: Iterable[Path]) -> set[Path]:
        """Follow shell scripts to every script they name.

        Args:
            start: The scripts reached from workflow and action steps.

        Returns:
            Every script reached, ``start`` included.
        """
        reached: set[Path] = set()
        todo = [path.resolve() for path in start]
        while todo:
            path = todo.pop()
            if path in reached:
                continue
            reached.add(path)
            if path.suffix != ".sh":
                continue
            for line in code_lines(path):
                # "$LIB_DIR/x.sh" names "x.sh" under some directory, not a
                # directory called LIB_DIR: drop each expansion first.
                bare = SHELL_VAR.sub(" ", line)
                for ref in SCRIPT_REF.findall(bare):
                    todo.extend(self.resolve(path, ref) - reached)
        return reached

    def caller_python_scripts(self) -> dict[str, set[Path]]:
        """Map each unit that installs caller Python to the scripts it reaches.

        Returns:
            ``{unit: scripts}`` for the units with an install step, counting
            the steps from the first install step on.
        """
        result: dict[str, set[Path]] = {}
        for unit, steps in self.units.items():
            installs = [isinstance(s, dict) and self.installs(s) for s in steps]
            first = installs.index(True) if True in installs else None
            if first is None:
                continue
            seen: set[str] = set()
            direct: set[Path] = set()
            for step in steps[first:]:
                if isinstance(step, dict):
                    direct |= self.step_scripts(step, seen)
            result[unit] = self.closure(direct)
        return result


def code_lines(path: Path) -> Iterator[str]:
    """Yield the lines of a shell script with comments removed.

    Args:
        path: The script.

    Yields:
        Each line up to its first ``#`` that starts a comment.
    """
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        yield re.split(r"\s#", line, maxsplit=1)[0]


def violations(tree: Tree) -> list[str]:
    """List the guarded calls reachable after a caller-Python install.

    Args:
        tree: The indexed checkout.

    Returns:
        ``unit: script: line`` entries, sorted; empty when the rule holds.
    """
    library = (tree.scripts / "ci" / "lib" / "python.sh").resolve()
    found: set[str] = set()
    for unit, scripts in tree.caller_python_scripts().items():
        for path in scripts:
            rel = path.relative_to(tree.root.resolve())
            if path == library:
                found.add(f"{unit}: {rel}: sources the run_python library")
                continue
            if path.suffix != ".sh":
                continue
            for line in code_lines(path):
                if GUARDED.search(line):
                    found.add(f"{unit}: {rel}: {line.strip()}")
    return sorted(found)


@pytest.fixture(name="tree", scope="module")
def fixture_tree() -> Tree:
    """Index this checkout once for the module.

    Returns:
        The indexed repository.
    """
    return Tree(REPO)


def test_no_python_311_gate_after_a_caller_python_install(tree: Tree) -> None:
    """No script reached after the caller's Python is installed gates on 3.11."""
    assert_that(violations(tree)).is_empty()


def test_the_walk_finds_the_jobs_and_scripts_the_rule_names(tree: Tree) -> None:
    """The derivation reaches the anchors, so the check above is not vacuous."""
    units = tree.caller_python_scripts()
    assert_that(units).contains_key(ANCHOR_UNIT)
    root = REPO.resolve()
    reached: set[str] = set()
    for scripts in units.values():
        reached |= {str(path.relative_to(root)) for path in scripts}
    for anchor in ANCHORS:
        assert_that(reached).contains(anchor)


def write(path: Path, text: str) -> None:
    """Write ``text`` to ``path``, creating its directories.

    Args:
        path: The file to write.
        text: Its content.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def fake_tree(root: Path, body: str) -> Tree:
    """Build a checkout whose test job installs caller Python, then runs a script.

    The job runs ``scripts/ci/actions/run.sh``, which sources
    ``../lib/helper.sh``; ``body`` is the helper's content.

    Args:
        root: An empty directory.
        body: The content of ``scripts/ci/lib/helper.sh``.

    Returns:
        The indexed fake checkout.
    """
    write(
        root / ".github/workflows/w.yml",
        "jobs:\n"
        "  early:\n"
        "    steps:\n"
        "      - run: bash scripts/ci/actions/early.sh\n"
        "  test:\n"
        "    steps:\n"
        "      - run: bash scripts/ci/actions/early.sh\n"
        "      - uses: ./.lgtm-ci-tooling/.github/actions/setup-python@main\n"
        "      - uses: ./.github/actions/runner\n",
    )
    write(
        root / ".github/actions/runner/action.yml",
        "runs:\n"
        "  using: composite\n"
        "  steps:\n"
        '    - run: bash "$GITHUB_ACTION_PATH/../../../scripts/ci/actions/run.sh"\n',
    )
    write(root / ".github/actions/setup-python/action.yml", "runs:\n  steps: []\n")
    write(
        root / "scripts/ci/actions/run.sh",
        'source "$(dirname "$0")/../lib/helper.sh"\n',
    )
    write(root / "scripts/ci/actions/early.sh", "run_python early.py\n")
    write(root / "scripts/ci/lib/helper.sh", body)
    return Tree(root)


def test_a_guarded_call_in_a_sourced_library_is_found(tmp_path: Path) -> None:
    """A call two hops away, through a composite action and a source, fails."""
    found = violations(fake_tree(tmp_path, 'run_python "$X/check.py"\n'))
    assert_that(found).is_length(1)
    assert_that(found[0]).starts_with("workflows/w.yml:test: ")
    assert_that(found[0]).contains("scripts/ci/lib/helper.sh")


def test_steps_before_the_install_and_other_jobs_are_not_held(tmp_path: Path) -> None:
    """``early.sh`` runs before the install, or in a job without one."""
    assert_that(violations(fake_tree(tmp_path, "echo ok\n"))).is_empty()


def test_a_comment_naming_the_helper_is_not_a_call(tmp_path: Path) -> None:
    """Only code lines count."""
    body = "# run_python is not used here\necho ok  # nor require_python\n"
    assert_that(violations(fake_tree(tmp_path, body))).is_empty()


def test_sourcing_the_library_itself_is_a_violation(tmp_path: Path) -> None:
    """Reaching ``lib/python.sh`` is reported even before a call."""
    tree = fake_tree(tmp_path, 'source "$(dirname "$0")/python.sh"\n')
    write(tmp_path / "scripts/ci/lib/python.sh", "run_python() { :; }\n")
    entry = "scripts/ci/lib/python.sh: sources the run_python library"
    assert_that(violations(tree)).contains(f"workflows/w.yml:test: {entry}")
