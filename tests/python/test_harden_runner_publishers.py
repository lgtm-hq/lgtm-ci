# SPDX-License-Identifier: MIT
"""The publish-step detector behind the pre-publish recheck contract (#1551).

``tests/helpers/harden_runner_publishers.py`` flags every step of a
harden-runner-verified job that publishes; each flagged step must be listed in
``PRE_PUBLISH`` (guarded by the recheck, see
``test_harden_runner_verify_contract.py``) or in ``ALLOWED_UNGUARDED`` with a
reason. These tests run it over the real workflows and over fixtures.
"""

from __future__ import annotations

from collections.abc import Mapping
from pathlib import Path
from typing import Any

import harden_runner_publishers
import pytest
from assertpy import assert_that
from harden_runner_publishers import (
    ALLOWED_UNGUARDED,
    NAME,
    PRE_PUBLISH,
    VERIFY_ID,
    WORKFLOWS,
    Scope,
    Step,
    all_publish_steps,
    findings,
    load,
    publish_steps,
    unguarded_publishers,
)


def test_every_publish_step_is_guarded_or_allowed() -> None:
    """Each publishing step of a verified job is in PRE_PUBLISH or allowed."""
    unlisted = [
        f"{key}: {sorted(found)}"
        for key, found in all_publish_steps().items()
        if key not in PRE_PUBLISH and key not in ALLOWED_UNGUARDED
    ]
    assert_that(unlisted).is_empty()


def test_listed_steps_are_detected_publishers() -> None:
    """The detector flags every listed step: no stale or invisible entries."""
    flagged = all_publish_steps()
    missed = [key for key in (*PRE_PUBLISH, *ALLOWED_UNGUARDED) if key not in flagged]
    assert_that(missed).is_empty()
    assert_that(set(PRE_PUBLISH) & set(ALLOWED_UNGUARDED)).is_empty()


def test_build_docker_steps_publish_by_mode() -> None:
    """build-docker.sh publishes for STEP push or sign-image, not otherwise."""
    document = load(WORKFLOWS / "reusable-docker-build.yml")
    flagged = publish_steps(document, "reusable-docker-build.yml")
    steps = document["jobs"]["build"]["steps"]
    runs = {str(step["name"]): str(step.get("run", "")) for step in steps}
    dispatched = {name for name, run in runs.items() if "build-docker.sh" in run}
    publishing = {name for _w, job, name in flagged if job == "build"} & dispatched
    assert_that(publishing).is_equal_to({"Push image after health check", "Sign image"})
    assert_that(len(dispatched)).is_greater_than(len(publishing))


def _workflow(
    *steps: Step,
    inputs: Mapping[str, Any] | None = None,
    job_env: Mapping[str, Any] | None = None,
) -> dict[Any, Any]:
    """Return an in-memory workflow with one verified job running ``steps``."""
    verify: Step = {"name": NAME, "id": VERIFY_ID, "run": "true"}
    job: dict[str, Any] = {"steps": [verify, *steps]}
    if job_env is not None:
        job["env"] = dict(job_env)
    return {
        "on": {"workflow_call": {"inputs": dict(inputs or {})}},
        "jobs": {"j": job},
    }


TOOLING = ".lgtm-ci-tooling/scripts/ci"
CHECK_SCRIPT_INPUT = {
    "check-script": {"default": "scripts/ci/security/check-vuln-suppressions.sh"},
}
NO_DEFAULT_INPUT = {"script": {"type": "string", "required": True}}
GRAPHQL_READ = "query { viewer { login } }"


@pytest.mark.parametrize(
    ("step", "inputs"),
    [
        pytest.param({"run": "docker push ghcr.io/o/i:1"}, None, id="docker-push"),
        pytest.param({"run": 'gh release create "$TAG"'}, None, id="gh-release"),
        pytest.param({"run": "git push origin v1"}, None, id="git-push"),
        pytest.param({"run": "npm publish --access public"}, None, id="npm"),
        pytest.param({"run": "cargo publish --locked"}, None, id="cargo"),
        pytest.param({"run": 'cosign sign --yes "$REF"'}, None, id="cosign"),
        pytest.param(
            {"run": "gh api -X DELETE /user/packages/container/x/versions/1"},
            None,
            id="package-version-delete",
        ),
        pytest.param(
            {"run": 'gh api "repos/$R/issues" \\\n  -f title=x'},
            None,
            id="gh-api-implicit-post",
        ),
        pytest.param(
            {"run": "gh api graphql -f query='mutation { a }'"},
            None,
            id="gh-api-graphql-mutation",
        ),
        pytest.param(
            {"run": 'gh api graphql --input "$PAYLOAD"'},
            None,
            id="gh-api-graphql-body-from-file",
        ),
        pytest.param(
            {"run": 'curl -sS --data-binary @x.json "$URL"'},
            None,
            id="curl-implicit-post",
        ),
        pytest.param(
            {"run": 'curl -fsS -T dist.tgz "$URL"'},
            None,
            id="curl-upload-file",
        ),
        pytest.param(
            {"run": 'python3 - <<EOF\ngh(\n    "api",\n    url,\n    "-f",\n)\nEOF'},
            None,
            id="python-gh-api-field",
        ),
        pytest.param(
            {"run": "docker buildx build --output type=registry -t i ."},
            None,
            id="buildx-registry-output",
        ),
        pytest.param({"run": "skopeo copy oci:x docker://r/i"}, None, id="skopeo"),
        pytest.param({"run": "aws s3 sync site/ s3://b/"}, None, id="aws-s3"),
        pytest.param({"run": "rsync -a site/ deploy@host:/srv"}, None, id="rsync"),
        pytest.param({"run": "bunx semantic-release"}, None, id="semantic-release"),
        pytest.param({"run": "uv publish dist/*"}, None, id="uv-publish"),
        pytest.param({"run": "gh repo create o/r --public"}, None, id="gh-repo"),
        pytest.param(
            {"env": {"STEP": "push"}, "run": f"{TOOLING}/actions/build-docker.sh"},
            None,
            id="build-docker-push",
        ),
        pytest.param(
            {
                "env": {"STEP": "build", "PUSH": "${{ inputs.push }}"},
                "run": f"{TOOLING}/actions/build-docker.sh",
            },
            None,
            id="build-docker-build-push-input",
        ),
        pytest.param(
            {"run": f"{TOOLING}/release/recover/redispatch-homebrew.sh"},
            None,
            id="script-indirect-gh-variable",
        ),
        pytest.param(
            {
                "env": {"CHECK_SCRIPT": "${{ inputs.check-script }}"},
                "run": 'bash "$GITHUB_WORKSPACE/$CHECK_SCRIPT"',
            },
            CHECK_SCRIPT_INPUT,
            id="script-indirect-via-input-default",
        ),
        pytest.param(
            {"env": {"SCRIPT": "${{ inputs.script }}"}, "run": 'bash "$SCRIPT"'},
            NO_DEFAULT_INPUT,
            id="unknown-executable-env",
        ),
        pytest.param(
            {"run": '"${{ inputs.script }}" --apply'},
            NO_DEFAULT_INPUT,
            id="unknown-executable-inline",
        ),
        pytest.param(
            {"uses": "./.lgtm-ci-tooling/.github/actions/sign-artifact"},
            None,
            id="composite-action",
        ),
        pytest.param(
            {"uses": "docker/build-push-action@x", "with": {"push": True}},
            None,
            id="build-push-action",
        ),
        pytest.param(
            {"uses": "anchore/sbom-action@x"},
            None,
            id="sbom-action-release-upload-default",
        ),
        pytest.param(
            {
                "uses": "lgtm-hq/lgtm-ci/.github/actions/generate-sbom@x",
                "with": {"upload-release-assets": "true"},
            },
            None,
            id="remote-composite-release-upload",
        ),
    ],
)
def test_detector_rejects_an_unlisted_publisher(
    step: Step,
    inputs: Mapping[str, Any] | None,
) -> None:
    """An unlisted publish step fails; listing it in PRE_PUBLISH clears it."""
    document = _workflow({"name": "P", **step}, inputs=inputs)
    assert_that(unguarded_publishers(document, "w.yml")).is_length(1)
    guarded = [("w.yml", "j", "P")]
    assert_that(unguarded_publishers(document, "w.yml", guarded)).is_empty()


@pytest.mark.parametrize(
    ("step", "inputs"),
    [
        pytest.param(
            {"env": {"STEP": "metadata"}, "run": f"{TOOLING}/actions/build-docker.sh"},
            None,
            id="build-docker-metadata",
        ),
        pytest.param(
            {
                "env": {"STEP": "build", "PUSH": "false"},
                "run": f"{TOOLING}/actions/build-docker.sh",
            },
            None,
            id="build-docker-build-no-push",
        ),
        pytest.param(
            {"env": {"PUSH": "false"}, "run": f"{TOOLING}/release/update-changelog.sh"},
            None,
            id="update-changelog-no-push",
        ),
        pytest.param(
            {"uses": "docker/build-push-action@x", "with": {"push": False}},
            None,
            id="build-push-action-no-push",
        ),
        pytest.param(
            {
                "uses": "./.lgtm-ci-tooling/.github/actions/generate-sbom",
                "with": {"upload-release-assets": "false"},
            },
            None,
            id="composite-no-release-upload",
        ),
        pytest.param({"run": 'echo "npm publish done"'}, None, id="message-only"),
        pytest.param({"run": "gh api repos/o/r/pulls"}, None, id="gh-api-get"),
        pytest.param(
            {"run": "gh api -X GET search/issues -f q=x"},
            None,
            id="gh-api-explicit-get-with-fields",
        ),
        pytest.param(
            {"run": f"gh api graphql -F n=1 -f query='{GRAPHQL_READ}'"},
            None,
            id="gh-api-graphql-query",
        ),
        pytest.param(
            {"run": f"Q='{GRAPHQL_READ}'\ngh api graphql \\\n  -f query=\"$Q\""},
            None,
            id="gh-api-graphql-query-variable",
        ),
        pytest.param(
            {"run": 'curl -fsSG --get -d q=x "$URL"'},
            None,
            id="curl-get-with-data",
        ),
        pytest.param({"run": "rsync -a site/ out/"}, None, id="rsync-local"),
        pytest.param(
            {"env": {"REF": "${{ inputs.script }}"}, "run": 'git log "$REF"'},
            NO_DEFAULT_INPUT,
            id="input-argument-not-executed",
        ),
    ],
)
def test_detector_passes_a_non_publishing_mode(
    step: Step,
    inputs: Mapping[str, Any] | None,
) -> None:
    """Reads, local copies and non-publishing modes are not flagged."""
    document = _workflow({"name": "P", **step}, inputs=inputs)
    assert_that(publish_steps(document, "w.yml")).is_empty()


def test_job_and_workflow_env_commands_are_scanned() -> None:
    """A command held in job- or workflow-level env flags the run: steps."""
    step: Step = {"name": "P", "run": "$RELEASE"}
    document = _workflow(step, job_env={"RELEASE": "gh release create v1"})
    assert_that(unguarded_publishers(document, "w.yml")).is_length(1)
    document = _workflow(step)
    document["env"] = {"RELEASE": "npm publish"}
    assert_that(unguarded_publishers(document, "w.yml")).is_length(1)


def test_scripts_are_followed_transitively(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A publish four calls deep is found; a call cycle terminates."""
    for name, body in {
        "a.sh": 'bash "$DIR/b.sh"',
        "b.sh": "source lib/c.sh",
        "lib/c.sh": 'bash "$SCRIPT_DIR/../d.sh"\nbash a.sh',
        "d.sh": "gh release upload v1 x.tgz",
    }.items():
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"#!/usr/bin/env bash\n{body}\n", encoding="utf-8")
    monkeypatch.setattr(harden_runner_publishers, "SCRIPTS_CI", tmp_path)
    found = findings({"run": "bash scripts/ci/a.sh"}, Scope(inputs={}, env={}))
    assert_that(sorted(found)).is_equal_to(["scripts/ci/d.sh: gh release write"])


def test_detector_ignores_jobs_without_the_verify_step() -> None:
    """Only verified jobs are in scope; the verify contract covers the rest."""
    document = {"jobs": {"j": {"steps": [{"name": "P", "run": "git push"}]}}}
    assert_that(publish_steps(document, "w.yml")).is_empty()
