#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Evaluate CI caller concurrency identities, not hosted scheduling (#1298)

load "../../helpers/common"

_check_concurrency() {
	require_python_yaml
	run "$PY" -B - "$PROJECT_ROOT" "$1" <<'PY'
from pathlib import Path
import re
import sys

import yaml

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "tests/helpers"))
from gha_expr import Parser, tokenize

workflow = yaml.safe_load((root / ".github/workflows/ci.yml").read_text())
scenario = sys.argv[2]


def context(**overrides):
    values = {
        "github.workflow": "CI",
        "github.workflow_ref": "lgtm-hq/lgtm-ci/.github/workflows/ci.yml@refs/pull/1298/merge",
        "github.event_name": "pull_request",
        "github.event.pull_request.number": 1298.0,
        "github.ref": "refs/pull/1298/merge",
        "github.sha": "old-head",
        "github.run_id": "1001",
        "github.run_attempt": 1.0,
    }
    return values | overrides


def value(expression, values):
    if not isinstance(expression, str):
        return expression
    source = expression.strip().removeprefix("${{").removesuffix("}}")
    return Parser(tokenize(source), values).parse()


def identity(policy, values):
    def replace(match):
        result = value(match[1], values)
        if isinstance(result, float):
            return str(int(result))
        return "" if result is None else str(result)

    group = re.sub(r"\$\{\{(.*?)\}\}", replace, policy["group"], flags=re.S)
    assert group.strip() and "${{" not in group, group
    # GitHub concurrency groups compare without regard to case.
    return group.casefold(), value(policy["cancel-in-progress"], values)


if scenario == "callees":
    seen = set()

    def visit(path, caller=False):
        if path in seen:
            return
        seen.add(path)
        document = yaml.safe_load(path.read_text())
        if not caller:
            assert "concurrency" not in document, f"callee group: {path}"
        for job_id, job in document["jobs"].items():
            assert "concurrency" not in job, f"job group: {path}:{job_id}"
            if "uses" in job:
                uses = job["uses"]
                assert uses.startswith("./.github/workflows/"), uses
                visit(root / uses)

    visit(root / ".github/workflows/ci.yml", caller=True)
    assert len(seen) > 1, "no reusables checked"
    print(f"checked {len(seen) - 1} reachable reusables: no callee or job groups")
else:
    assert "concurrency" in workflow, "CI caller has no concurrency policy"
    policy = workflow["concurrency"]
    first = context()
    group, cancel = identity(policy, first)
    assert cancel is True, "PR replacements must cancel superseded work"

    if scenario == "replacement":
        for attempt in (1.0, 2.0):
            replacement = context(**{
                "github.run_id": "1002", "github.sha": "new-head",
                "github.run_attempt": attempt,
            })
            assert identity(policy, replacement) == (group, True)
    elif scenario == "prs":
        # Hold ref/workflow_ref constant to independently exercise the PR number.
        other = context(**{"github.event.pull_request.number": 1299.0})
        assert identity(policy, other)[0] != group, "different PRs share a group"
    elif scenario == "workflows":
        for name in ("CI", "Other CI"):
            other = context(**{
                "github.workflow": name,
                "github.workflow_ref": first["github.workflow_ref"].replace("ci.yml@", "other.yml@"),
            })
            assert identity(policy, other)[0] != group, "different workflow files share a group"
    elif scenario in ("non-pr", "events", "example"):
        executions = [first]
        for event, ref in (
            ("push", "refs/heads/main"),
            ("push", "refs/tags/v1.0.0"),
            ("release", "refs/tags/v1.0.0"),
            ("merge_group", "refs/heads/gh-readonly-queue/main/pr-1298-head"),
            ("workflow_dispatch", "refs/heads/main"),
        ):
            groups = set()
            for run_id in ("1001", "1002", "1003", "1004"):
                for attempt in (1.0, 2.0):
                    execution = context(**{
                        "github.event_name": event, "github.ref": ref,
                        "github.workflow_ref": first["github.workflow_ref"].split("@")[0] + "@" + ref,
                        "github.event.pull_request.number": None,
                        "github.run_id": run_id, "github.run_attempt": attempt,
                    })
                    key, cancel = identity(policy, execution)
                    assert cancel is False, f"{event} can cancel running work"
                    assert key not in groups, f"{event} can replace pending work: {key}"
                    assert key != group, f"{event} shares a PR group"
                    groups.add(key)
                    executions.append(execution)
        if scenario == "events":
            # Same run/ref identity is a deliberate control for event isolation.
            keys = [identity(policy, context(**{"github.event_name": event}))[0]
                    for event in ("pull_request", "push", "release", "merge_group")]
            assert len(set(keys)) == len(keys), "different events share a group"
        if scenario == "example":
            text = (root / "docs/workflows/testing.md").read_text()
            section = text.split("## Caller concurrency", 1)[1].split("\n## ", 1)[0]
            example = yaml.safe_load(section.split("```yaml\n", 1)[1].split("```", 1)[0])
            for execution in executions:
                assert identity(example["concurrency"], execution) == identity(policy, execution)
    else:
        raise AssertionError(f"unknown scenario: {scenario}")
PY
	assert_success
}

@test "CI concurrency: superseded commits and reruns of one PR share a cancelling group" {
	_check_concurrency replacement
}

@test "CI concurrency: different PR numbers are isolated" {
	_check_concurrency prs
}

@test "CI concurrency: different workflow files, even with the same name, are isolated" {
	_check_concurrency workflows
}

@test "CI concurrency: every non-PR run and attempt retains its own noncancelling group" {
	_check_concurrency non-pr
}

@test "CI concurrency: PR, push, release and merge queue events are isolated" {
	_check_concurrency events
}

@test "CI concurrency: reachable reusables cannot reacquire the caller group" {
	_check_concurrency callees
	assert_output 'checked 9 reachable reusables: no callee or job groups'
}

@test "CI concurrency: documented safe caller evaluates like the actual CI caller" {
	_check_concurrency example
}
