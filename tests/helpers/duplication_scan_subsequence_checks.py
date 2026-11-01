# SPDX-License-Identifier: MIT
"""Synthetic public fixtures for manual catalog subsequence candidates."""

from __future__ import annotations

import contextlib
import io
import unittest
from dataclasses import replace
from unittest.mock import patch

import yaml
from duplication_scan_support import FakeGitHub, model, offline_cli, scan

AUDIT = "reusable-security-audit"
COMMENT = "reusable-publish-security-audit-comment"
PATH = ".github/workflows/security.yml"


def fixture_units(catalog: bool = False) -> list[model.Unit]:
    """Model the six/four-step consumers without copying any private source."""
    harden = {"uses": "step-security/harden-runner@pin"}
    checkout = {"uses": "actions/checkout@pin"}
    upload = {"uses": "actions/upload-artifact@pin"}
    download = {"uses": "actions/download-artifact@pin"}
    audit = {"run": "./scripts/ci/security-audit.sh"}
    fail = {"run": "./scripts/ci/fail-audit.sh"}
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
        """Live mode prints the new category without any issue mutations."""
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
