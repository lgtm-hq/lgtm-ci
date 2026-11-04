# SPDX-License-Identifier: MIT
"""Synthetic public fixtures for manual catalog subsequence candidates."""

from __future__ import annotations

import contextlib
import io
import unittest
from collections import Counter
from dataclasses import replace
from typing import Any
from unittest.mock import patch

import yaml
from duplication_scan_support import FakeGitHub, model, offline_cli, scan

AUDIT = "reusable-security-audit"
COMMENT = "reusable-publish-security-audit-comment"
PATH = ".github/workflows/security.yml"


def probe_unit(
    steps: list[dict[str, Any]],
    *,
    catalog: bool = False,
    inputs: dict[str, Any] | None = None,
    workflow_env: dict[str, Any] | None = None,
    job_env: dict[str, Any] | None = None,
) -> model.Unit:
    """Exercise production parsing, including inherited input provenance."""
    document = {
        "on": {"workflow_call": {"inputs": inputs or {}}},
        "env": workflow_env or {},
        "jobs": {"check": {"env": job_env or {}, "steps": steps}},
    }
    return model.units(
        "org/catalog" if catalog else "org/consumer",
        False,
        {PATH: yaml.safe_dump(document)},
        reference="probe" if catalog else "",
    )[0]


def malformed_documents() -> list[dict[str, Any]]:
    """Malformed mappings reached by core extraction must fail controllably."""
    documents: list[dict[str, Any]] = []
    call: Any
    invalid: Any
    for call in (
        None,
        [],
        "bad",
        {"inputs": None},
        {"inputs": []},
        {"inputs": {"script": None}},
        {"inputs": {"script": "bad"}},
    ):
        documents.append(
            {
                "on": {"workflow_call": call},
                "jobs": {"check": {"steps": [{"run": "bash '${{ inputs.script }}'"}]}},
            }
        )
    for key in ("env", "with"):
        for invalid in (None, [], "bad"):
            step = {"run": "bash helper.sh", key: invalid}
            documents.append({"jobs": {"check": {"steps": [step]}}})
    for invalid in (None, [], "bad"):
        documents.extend(
            [
                {"env": invalid, "jobs": {"check": {"steps": [{"run": "echo ok"}]}}},
                {"jobs": {"check": {"env": invalid, "steps": [{"run": "echo ok"}]}}},
            ]
        )
    return documents


def fixture_units(catalog: bool = False) -> list[model.Unit]:
    """Model the six/four-step consumers without copying any private source."""
    harden = {"uses": "step-security/harden-runner@pin"}
    checkout = {"uses": "actions/checkout@pin"}
    upload = {"uses": "actions/upload-artifact@pin"}
    download = {"uses": "actions/download-artifact@pin"}
    audit: dict[str, Any] = {"run": "./scripts/ci/security-audit.sh"}
    fail: dict[str, Any] = {"run": "./scripts/ci/fail-audit.sh"}
    prepare = {"run": "./scripts/ci/pull-lintro-image.sh"}
    comment = {
        "uses": "./.github/actions/post-pr-comment",
        "with": {"file": "audit.txt", "marker": "security-audit-report"},
    }
    inputs = {
        "audit-script": {"default": "scripts/security/run-lintro-audit.sh"},
        "fail-script": {"default": "scripts/security/fail-audit.sh"},
        "comment-file": {"default": "audit.txt"},
        "comment-marker": {"default": "security-audit-report"},
    }
    extra = []
    if catalog:
        audit = {
            "run": 'bash "$GITHUB_WORKSPACE/$AUDIT_SCRIPT"',
            "env": {"AUDIT_SCRIPT": "${{ inputs.audit-script }}"},
        }
        fail = {
            "run": 'bash "$GITHUB_WORKSPACE/$FAIL_SCRIPT"',
            "env": {"FAIL_SCRIPT": "${{ inputs.fail-script }}"},
        }
        prepare = {"uses": "docker/login-action@pin"}
        comment = {
            "uses": "./.lgtm-ci-tooling/.github/actions/post-pr-comment",
            "with": {
                "file": "${{ inputs.comment-file }}",
                "marker": "${{ inputs.comment-marker }}",
            },
        }
        extra = [
            {
                "name": "Fail on unknown egress-preset",
                "run": 'echo "$EGRESS_PRESET"; exit 1',
            },
            {"uses": "actions/checkout@other", "with": {"path": "tooling"}},
            {"uses": "./.lgtm-ci-tooling/.github/actions/checkout-and-harden"},
            {
                "name": "Warn on failed upload",
                "run": 'echo "::warning::Upload failed"',
            },
        ]
    jobs = {
        "audit": {
            "steps": [harden, checkout, *extra, prepare, audit, upload, fail],
        },
        "comment": {"steps": [harden, checkout, *extra, download, comment]},
    }
    document = {"on": {"workflow_call": {"inputs": inputs}}, "jobs": jobs}
    repository = "lgtm-hq/lgtm-ci" if catalog else "org/consumer"
    found = model.units(repository, False, {PATH: yaml.safe_dump(document)})
    return [
        replace(
            unit,
            reference=AUDIT if unit.job == "audit" else COMMENT,
        )
        for unit in found
    ]


class Cases(unittest.TestCase):
    """Require ordering, main-step evidence and a report-only publication path."""

    def test_malformed_model_mappings(self) -> None:
        """Invalid mappings are counted without an uncontrolled exception."""
        for document in malformed_documents():
            with self.subTest(document=document):
                skipped: Counter[str] = Counter()
                self.assertEqual(
                    model.units(
                        "org/consumer",
                        False,
                        {PATH: yaml.safe_dump(document)},
                        skipped=skipped,
                    ),
                    [],
                )
                self.assertEqual(skipped, {"invalid source": 1})
        control = probe_unit([{"run": "bash helper.sh"}])
        self.assertEqual(control.core, ("script:helper.sh",))
        self.assertEqual(control.main, "")

    def test_malformed_cli_partial(self) -> None:
        """Actual live CLI blocks issue creation after malformed source."""
        for document in malformed_documents():
            for dry_run in (True, False):
                with self.subTest(document=document, dry_run=dry_run):
                    repositories = [
                        {
                            "full_name": f"org/{name}",
                            "private": False,
                            "archived": False,
                            "files": {"scripts/check.sh": "echo check"},
                        }
                        for name in ("left", "right")
                    ]
                    repositories.append(
                        {
                            "full_name": "org/malformed",
                            "private": False,
                            "archived": False,
                            "files": {PATH: yaml.safe_dump(document)},
                        }
                    )
                    api = FakeGitHub(repositories=repositories)
                    output = io.StringIO()
                    with (
                        offline_cli(dry_run),
                        patch.dict(
                            "os.environ",
                            {"GH_TOKEN": "fixture", "GITHUB_STEP_SUMMARY": ""},
                        ),
                        patch.object(scan, "GitHub", return_value=api),
                        contextlib.redirect_stdout(output),
                    ):
                        self.assertEqual(scan.main(), int(not dry_run))
                    self.assertEqual(api.skipped["invalid source"], 1)
                    self.assertTrue(api.partial)
                    self.assertIn("Partial scan", output.getvalue())
                    self.assertIn("Issue action: blocked", output.getvalue())
                    self.assertEqual(api.writes, [])

    def test_executed_primary_provenance(self) -> None:
        """Only the executed operand inherits primary input provenance."""
        inputs = {
            "script": {"default": "bin/audit.sh"},
            "fail-script": {"default": "bin/audit.sh"},
        }
        prefix = {"uses": "org/core@v1"}
        consumer = probe_unit([prefix, {"run": "bin/audit.sh"}])
        for scope in ("workflow_env", "job_env", "step"):
            settings: dict[str, Any] = {}
            step: dict[str, Any] = {"run": 'bash "$SCRIPT"'}
            if scope == "step":
                step["env"] = {"SCRIPT": "${{ inputs.script }}"}
            else:
                settings[scope] = {"SCRIPT": "${{ inputs.script }}"}
            reference = probe_unit(
                [prefix, step],
                catalog=True,
                inputs=inputs,
                **settings,
            )
            self.assertEqual(reference.main, "script:audit.sh")
            self.assertEqual(
                len(model.catalog_subsequences([consumer], [reference])),
                1,
            )
        for step in (
            {"run": "bin/audit.sh", "env": {"UNRELATED": "${{ inputs.script }}"}},
            {"run": "bin/helper.sh", "env": {"UNRELATED": "${{ inputs.script }}"}},
            {"run": "bin/audit.sh '${{ inputs.script }}'"},
            {"run": "bash '${{ inputs.fail-script }}'"},
        ):
            reference = probe_unit([prefix, step], catalog=True, inputs=inputs)
            self.assertEqual(reference.main, "")
            self.assertFalse(model.catalog_subsequences([consumer], [reference]))
        direct = probe_unit(
            [prefix, {"run": "bash '${{ inputs.script }}'"}],
            catalog=True,
            inputs=inputs,
        )
        self.assertEqual(direct.main, "script:audit.sh")
        overridden = probe_unit(
            [prefix, {"run": 'bash "$SCRIPT"', "env": {"SCRIPT": "bin/audit.sh"}}],
            catalog=True,
            inputs=inputs,
            workflow_env={"SCRIPT": "${{ inputs.script }}"},
        )
        self.assertEqual(overridden.main, "")

    def test_whole_infrastructure_bodies(self) -> None:
        """Extra commands in warning/egress steps remain opaque core work."""
        prefix = [{"uses": "org/core@v1"}, {"run": "bin/main.sh"}]
        reference = probe_unit(
            [prefix[0], {"run": "${{ inputs.script }}"}],
            catalog=True,
            inputs={"script": {"default": "bin/main.sh"}},
        )
        pure = [
            {
                "name": "artifact warning",
                "run": 'echo "::warning:: upload unavailable"',
            },
            {
                "name": "Warn on failed comment upload",
                "run": 'echo "::warning::Audit comment upload failed; '
                'the audit result is unaffected."',
            },
            {
                "name": "Warn on missing artifact",
                "run": 'echo "::warning::${MISSING_ARTIFACT_WARNING}"',
            },
            {
                "name": "Fail on unknown egress-preset",
                "run": 'echo "::error title=unknown egress-preset::'
                "not a preset - '${EGRESS_PRESET}'\"; exit 1",
            },
        ]
        for step in pure:
            with self.subTest(pure=step):
                consumer = probe_unit([*prefix, step])
                self.assertEqual(
                    len(model.catalog_subsequences([consumer], [reference])),
                    1,
                )
        for step in (
            {**pure[0], "run": pure[0]["run"] + "\nbash extra-check.sh"},
            {
                "name": "Check egress-preset",
                "run": 'echo "$EGRESS_PRESET"; bash extra-check.sh',
            },
            {**pure[-1], "run": pure[-1]["run"] + "\nbash extra-check.sh"},
            {**pure[0], "run": 'echo "::warning::$(bash extra-check.sh)"'},
            {**pure[0], "run": 'echo "::warning:: upload unavailable\\"'},
            {**pure[0], "run": 'echo\n"::warning:: upload unavailable"'},
        ):
            with self.subTest(mixed=step):
                consumer = probe_unit([*prefix, step])
                self.assertEqual(len(consumer.core), 3)
                self.assertTrue(consumer.core[-1].startswith("opaque:"))
                self.assertFalse(model.catalog_subsequences([consumer], [reference]))

    def test_contextual_main_normalization(self) -> None:
        """The retained primary step uses the same contextual role as core."""
        reference = probe_unit(
            [
                {"run": "${{ inputs.audit-script }}"},
                {"run": "${{ inputs.image-script }}"},
            ],
            catalog=True,
            inputs={
                "audit-script": {"default": "bin/security-audit.sh"},
                "image-script": {"default": "bin/pull-lintro-image.sh"},
            },
        )
        consumer = probe_unit(
            [{"run": "bin/security-audit.sh"}, {"run": "bin/pull-lintro-image.sh"}]
        )
        self.assertEqual(reference.main, "role:prepare-audit-container")
        self.assertIn(reference.main, reference.core)
        self.assertEqual(len(model.catalog_subsequences([consumer], [reference])), 1)

    def test_simplified_jobs(self) -> None:
        """Both simplified consumers include the reusable's primary operation."""
        consumers, references = fixture_units(), fixture_units(True)
        matches = model.catalog_subsequences(consumers, references)
        self.assertEqual(
            [(left.job, right.reference, count) for left, right, count in matches],
            [("audit", AUDIT, 3), ("comment", COMMENT, 1)],
        )
        self.assertEqual(references[0].main, "script:security-audit")
        self.assertEqual(len(references[0].core), 3)

    def test_single_script_and_adoption(self) -> None:
        """Checkout plus a single script and already-adopted jobs never qualify."""
        references = fixture_units(True)
        for block in (
            {
                "steps": [
                    {"uses": "actions/checkout@v4"},
                    {"run": "./scripts/ci/security-audit.sh"},
                ],
            },
            {"uses": f"lgtm-hq/lgtm-ci/.github/workflows/{AUDIT}.yml@main"},
        ):
            source = yaml.safe_dump({"jobs": {"audit": block}})
            consumers = model.units("org/consumer", False, {PATH: source})
            self.assertFalse(model.catalog_subsequences(consumers, references, 1))

    def test_order_main_and_minimum(self) -> None:
        """Every operation must fit, main must be shared, and N is inclusive."""
        consumer, reference = fixture_units()[0], fixture_units(True)[0]
        for changed in (
            replace(consumer, core=consumer.core[:1] + consumer.core[2:]),
            replace(consumer, core=tuple(reversed(consumer.core))),
            replace(consumer, core=(*consumer.core, "command:unrelated")),
        ):
            self.assertFalse(model.catalog_subsequences([changed], [reference], 1))
        self.assertTrue(model.catalog_subsequences([consumer], [reference], 3))
        self.assertFalse(model.catalog_subsequences([consumer], [reference], 4))
        self.assertFalse(
            model.catalog_subsequences(fixture_units()[1:], fixture_units(True)[1:], 2)
        )

    def test_comment_role(self) -> None:
        """The same generic comment action with a different marker is unrelated."""
        consumer, reference = fixture_units()[1], fixture_units(True)[1]
        operation = consumer.core[0].replace("security-audit", "test")
        consumer = replace(consumer, core=(operation,))
        self.assertFalse(model.catalog_subsequences([consumer], [reference], 1))

    def test_live_is_report_only(self) -> None:
        """--dry-run=false exercises CLI live mode; the workflow guard is separate."""
        consumers, references = fixture_units(), fixture_units(True)
        source = "\n".join(unit.source for unit in consumers)
        files = {PATH: yaml.safe_dump({"jobs": yaml.safe_load(source)})}
        api = FakeGitHub(
            repositories=[
                {
                    "full_name": scan.TARGET,
                    "private": False,
                    "archived": False,
                    "files": {},
                },
                {
                    "full_name": "org/consumer",
                    "private": False,
                    "archived": False,
                    "files": files,
                },
            ],
        )
        output = io.StringIO()
        with (
            offline_cli(False),
            patch.dict(
                "os.environ",
                {"GH_TOKEN": "fixture", "DUPLICATION_SCAN_LIVE_ENABLED": "true"},
            ),
            patch.object(scan, "GitHub", return_value=api),
            patch.object(scan, "references", return_value=references),
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(scan.main(), 0)
        self.assertIn("Catalog subsequence candidates", output.getvalue())
        self.assertIn(AUDIT, output.getvalue())
        self.assertIn(COMMENT, output.getvalue())
        self.assertFalse(api.partial)
        self.assertEqual(api.skipped["invalid source"], 0)
        self.assertEqual(api.writes, [])

    def test_private_rendering(self) -> None:
        """Private jobs, tokens and source are absent from the manual report."""
        consumer, reference = fixture_units()[0], fixture_units(True)[0]
        consumer = replace(consumer, private=True, job="PRIVATE_JOB_CANARY")
        text = "\n".join(model.render_subsequences([(consumer, reference, 3)]))
        self.assertIn(consumer.path, text)
        self.assertNotIn(consumer.job, text)
        self.assertNotIn(consumer.core[0], text)
        self.assertNotIn("dup-scan:", text)
        hidden_reference = replace(
            reference,
            private=True,
            reference="PRIVATE_REF_CANARY",
        )
        text = "\n".join(model.render_subsequences([(consumer, hidden_reference, 3)]))
        self.assertNotIn("PRIVATE_REF_CANARY", text)


if __name__ == "__main__":
    unittest.main()
