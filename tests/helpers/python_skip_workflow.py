#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Local planning/step boundaries; hosted check-name interpolation needs a canary."""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import TypedDict

import yaml
from gha_expr import Parser, Value, evaluate, tokenize

Condition = TypedDict("Condition", {"if": str}, total=False)


Step = TypedDict(
    "Step",
    {"if": str, "name": str, "run": str, "env": dict[str, Value]},
    total=False,
)
Job = TypedDict(
    "Job",
    {
        "if": str,
        "name": str,
        "steps": list[Step],
        "outputs": dict[str, Value],
        "strategy": dict[str, str],
    },
    total=False,
)


class InputSpec(TypedDict, total=False):
    """Workflow input defaults used to initialize the expression context."""

    default: Value


Context = dict[str, Value]
Jobs = dict[str, Job]
Steps = dict[str, dict[str, Step]]


def value(expression: Value, context: Context) -> Value:
    """Resolve a scalar using the repository's Actions expression parser."""
    if not isinstance(expression, str) or not expression.startswith("${{"):
        return expression
    return Parser(tokenize(expression[3:-2]), context).parse()


def enabled(item: Condition, context: Context) -> bool:
    """Evaluate the actual workflow condition with implicit success()."""
    condition = item.get("if", "success()")
    condition = condition.replace(
        "fromJSON(env.LGTM_CI_EGRESS_PRESETS)[inputs.egress-preset || 'pypi']",
        "'known-pypi-preset'",
    )
    return bool(evaluate(condition, context))


def outputs(path: Path) -> dict[str, str]:
    """Read single-line GitHub outputs from a real shell step."""
    return dict(line.split("=", 1) for line in path.read_text().splitlines())


def execute(
    step: Step, context: Context, root: Path, work: Path
) -> tuple[subprocess.CompletedProcess[str], dict[str, str]]:
    """Execute a selected workflow shell step without network or project sync."""
    output = work / "output"
    output.write_text("")
    env = dict(os.environ, GITHUB_OUTPUT=str(output))
    env.update(
        {key: str(value(val, context)) for key, val in step.get("env", {}).items()},
    )
    result = subprocess.run(
        ["bash", "-e", "-o", "pipefail", "-c", step["run"]],
        cwd=root,
        env=env,
        check=False,
        capture_output=True,
        text=True,
    )
    return result, outputs(output)


def verify_matrix(jobs: Jobs, steps: Steps, context: Context, work: Path) -> None:
    """Execute matrix generation and verify dynamic jobs for every version shape."""
    for versions, expected in (
        ("", ["3.12"]),
        ("3.12,3.14", ["3.12", "3.14"]),
        (" , , ", ["3.12"]),
    ):
        context["inputs.python-versions"] = versions
        result, generated = execute(
            steps["prepare"]["Generate Python matrix"],
            context,
            work,
            work,
        )
        assert result.returncode == 0, result.stderr
        matrix = json.loads(generated["matrix"])
        entries = [{"python-version": v} for v in expected]
        assert matrix == {"include": entries}
        matrix_source = jobs["test"]["strategy"]["matrix"]
        assert matrix_source == "${{ fromJson(needs.prepare.outputs.matrix) }}"
        assert enabled(
            jobs["test"],
            context,
        ), "dynamic test job skipped before name interpolation"
        name = value(jobs["test"]["name"], context)
        assert name == "Required Python Tests"
        assert enabled(jobs["aggregate"], context)


def verify_planning(jobs: Jobs, steps: Steps, context: Context, work: Path) -> None:
    """Check opt-in PR skips, full main/queue runs and draft overrides."""
    assert context["inputs.pipeline-skip"] is False
    for skip in (True, False):
        context["inputs.pipeline-skip"] = skip
        for event, ref in (
            ("pull_request", "refs/pull/1/merge"),
            ("push", "refs/heads/main"),
            ("merge_group", "refs/heads/gh-readonly-queue/main/x"),
        ):
            context.update({"github.event_name": event, "github.ref": ref})
            assert enabled(
                jobs["prepare"],
                context,
            ), "prepare skipped before matrix expansion"
            effective = value(
                jobs["prepare"]["outputs"]["pipeline-skip"],
                context,
            )
            assert effective is (skip and event == "pull_request")
            skip_value = str(effective).lower()
            context["needs.prepare.outputs.pipeline-skip"] = skip_value
            run_tests = enabled(steps["test"]["Run pytest"], context)
            assert run_tests is (not effective)
            assert enabled(
                steps["aggregate"]["Aggregate matrix results"],
                context,
            ) is (not effective)
            verify_matrix(jobs, steps, context, work)
            context["github.event.pull_request.draft"] = True
            assert enabled(jobs["test"], context) is (event != "pull_request")
            context["inputs.draft-pr-skip"] = False
            assert enabled(jobs["test"], context)
            context.update(
                {
                    "inputs.draft-pr-skip": True,
                    "github.event.pull_request.draft": False,
                }
            )


def verify_lightweight(jobs: Jobs, steps: Steps, context: Context, work: Path) -> None:
    """Execute only the selected lightweight steps and preserve failure guards."""
    context["needs.prepare.outputs.pipeline-skip"] = "true"
    for job in ("test", "aggregate"):
        candidates = jobs[job]["steps"]
        selected_steps = [s for s in candidates if enabled(s, context)]
        expected_names = {"Harden runner"}
        if job == "test":
            expected_names.add("Pipeline skip")
        assert {step["name"] for step in selected_steps} == expected_names, [
            step["name"] for step in selected_steps
        ]
        for step in selected_steps:
            if "run" in step:
                result, _ = execute(step, context, work, work)
                assert result.returncode == 0, result.stderr
    assert value(jobs["aggregate"]["outputs"]["passed"], context) is True
    # Even always() steps must stay off after a hardening failure on a skip.
    context["job.status"] = "failure"
    for name in (
        "Parse results",
        "Generate summary",
        "Upload matrix test summary",
        "Remove git auth for private dependencies",
    ):
        assert not enabled(steps["test"][name], context), name


def verify_real_failure(steps: Steps, context: Context, work: Path) -> None:
    """Run an actual failing pytest through the unchanged workflow shell steps."""
    context["needs.prepare.outputs.pipeline-skip"] = "false"
    context["inputs.working-directory"] = str(work)
    context["inputs.test-path"] = "test_failure.py"
    (work / "test_failure.py").write_text(
        "def test_failure():\n    assert False\n",
    )
    # Only uv and its report flags are adapted. The installed pytest
    # executes a real failing test; no sync, network or plugin install.
    binary = work / "bin"
    binary.mkdir()
    uv = binary / "uv"
    uv.write_text(
        "#!/usr/bin/env python3\n"
        "import os, subprocess, sys\n"
        "assert sys.argv[1:4] == ['run', '--frozen', 'pytest']\n"
        "args = [a for a in sys.argv[4:]\n"
        "        if not a.startswith('--json-report')]\n"
        "command = [os.environ['PYTEST_PYTHON'], '-m', 'pytest', *args]\n"
        "raise SystemExit(subprocess.call(command))\n"
    )
    uv.chmod(0o755)
    os.environ["PATH"] = str(binary) + os.pathsep + os.environ["PATH"]
    os.environ["PYTEST_DISABLE_PLUGIN_AUTOLOAD"] = "1"
    step = steps["test"]["Run pytest"]
    assert enabled(step, context)
    result, recorded = execute(step, context, work, work)
    assert result.returncode == 1, result.stdout + result.stderr
    assert "1 failed" in result.stdout, result.stdout + result.stderr
    assert recorded["exit-code"] == "1"
    context["steps.run.outputs.exit-code"] = recorded["exit-code"]
    step = steps["test"]["Fail on pytest errors"]
    assert enabled(step, context)
    result, _ = execute(step, context, work, work)
    assert result.returncode == 1


def verify_failure(jobs: Jobs, steps: Steps, context: Context, work: Path) -> None:
    """Execute fail-closed aggregate guards for failed tests and preparation."""
    context["needs.prepare.outputs.pipeline-skip"] = "false"
    assert enabled(steps["test"]["Run pytest"], context)
    assert enabled(steps["aggregate"]["Aggregate matrix results"], context)
    # Execute actual failure steps, including always() after failures.
    for skip in ("false", "true"):
        context["needs.prepare.outputs.pipeline-skip"] = skip
        for status in ("failure", "cancelled", "skipped"):
            context["needs.test.result"] = status
            context["steps.aggregate.outputs.passed"] = "true"
            step = steps["aggregate"]["Fail if any matrix leg failed"]
            assert enabled(step, context)
            result, _ = execute(step, context, work, work)
            assert result.returncode == 1
            passed = value(jobs["aggregate"]["outputs"]["passed"], context)
            assert passed is False
    context.update(
        {
            "needs.test.result": "success",
            "needs.prepare.outputs.pipeline-skip": "false",
        }
    )
    for verdict in ("false", ""):
        context["steps.aggregate.outputs.passed"] = verdict
        assert enabled(
            steps["aggregate"]["Fail if any matrix leg failed"],
            context,
        )
    for status in ("failure", "cancelled"):
        context["needs.prepare.result"] = status
        step = steps["aggregate"]["Fail if matrix preparation did not succeed"]
        assert enabled(step, context)
        result, _ = execute(step, context, work, work)
        assert result.returncode == 1


def main() -> None:
    """Run the requested focused boundary scenarios."""
    mode, directory = sys.argv[1:]
    root = Path(directory)
    document = yaml.safe_load(
        (root / ".github/workflows/reusable-test-python.yml").read_text(),
    )
    jobs: Jobs = document["jobs"]
    call = document.get("on", document.get(True))["workflow_call"]
    inputs: dict[str, InputSpec] = call["inputs"]
    context: Context = {
        f"inputs.{input_key}": spec.get("default") for input_key, spec in inputs.items()
    }
    context.update(
        {
            "github.event_name": "pull_request",
            "github.ref": "refs/pull/1/merge",
            "github.event.pull_request.draft": False,
            "needs.prepare.result": "success",
            "needs.test.result": "success",
            "runner.os": "Linux",
            "runner.environment": "github-hosted",
            "inputs.publish-test-summary": False,
            "inputs.job-name": "Required Python Tests",
        }
    )
    steps: Steps = {
        job: {step["name"]: step for step in body["steps"]}
        for job, body in jobs.items()
        if "steps" in body
    }
    with tempfile.TemporaryDirectory(prefix="1297-") as temporary:
        work = Path(temporary)
        # Existing scripts are the tooling checkout in this local execution fixture.
        (work / ".lgtm-ci-tooling").symlink_to(root, target_is_directory=True)
        if mode == "planning":
            verify_planning(jobs, steps, context, work)
        elif mode == "lightweight":
            verify_lightweight(jobs, steps, context, work)
        elif mode == "real-failure":
            verify_real_failure(steps, context, work)
        elif mode == "failure":
            verify_failure(jobs, steps, context, work)
        else:
            raise ValueError(mode)
    print(f"{mode} boundaries verified (hosted context proof remains pending)")


if __name__ == "__main__":
    main()
