# SPDX-License-Identifier: MIT
"""Synthetic public fixtures for manual catalog subsequence candidates."""

from __future__ import annotations

import contextlib
import io
import re
import unittest
from collections import Counter
from dataclasses import replace
from pathlib import Path
from typing import Any
from unittest.mock import patch

import yaml
from duplication_scan_support import FakeGitHub, comment_probe, model, offline_cli, scan

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
        [],
        "bad",
        1,
        False,
        {"inputs": []},
        {"inputs": "bad"},
        {"inputs": 1},
        {"inputs": False},
        {"inputs": {"script": None}},
        {"inputs": {"script": "bad"}},
        {"inputs": {"script": []}},
        {"inputs": {"script": 1}},
        {"inputs": {"script": False}},
    ):
        documents.append(
            {
                "on": {"workflow_call": call},
                "jobs": {"check": {"steps": [{"run": "bash '${{ inputs.script }}'"}]}},
            }
        )
    for key in ("env", "with"):
        for invalid in ([], "bad", 1, False):
            step = {"run": "bash helper.sh", key: invalid}
            documents.append({"jobs": {"check": {"steps": [step]}}})
    for invalid in ([], "bad", 1, False):
        documents.extend(
            [
                {"env": invalid, "jobs": {"check": {"steps": [{"run": "echo ok"}]}}},
                {"jobs": {"check": {"env": invalid, "steps": [{"run": "echo ok"}]}}},
            ]
        )
    return documents


def valid_optional_documents() -> list[dict[str, Any]]:
    """Null optional mappings retain units without inventing a primary input."""
    steps = [{"run": "bash helper.sh"}]
    calls: tuple[dict[str, Any] | None, ...] = (
        None,
        {},
        {"inputs": None},
        {"inputs": {}},
    )
    documents: list[dict[str, Any]] = []
    for call in calls:
        documents.append(
            {"on": {"workflow_call": call}, "jobs": {"check": {"steps": steps}}},
        )
    documents.append({"on": "workflow_call", "jobs": {"check": {"steps": steps}}})
    empty: dict[str, Any] | None
    for empty in (None, {}):
        documents.extend(
            [
                {"env": empty, "jobs": {"check": {"steps": steps}}},
                {"jobs": {"check": {"env": empty, "steps": steps}}},
            ],
        )
        for key in ("env", "with"):
            for step in ({"run": "bash helper.sh"}, {"uses": "org/core@v1"}):
                documents.append({"jobs": {"check": {"steps": [{**step, key: empty}]}}})
    documents.append(
        {
            "on": {"workflow_call": {"inputs": None}},
            "env": None,
            "jobs": {
                "check": {
                    "env": None,
                    "steps": [
                        {
                            "run": "bash '${{ inputs.script }}'",
                            "env": None,
                            "with": None,
                        },
                    ],
                },
            },
        },
    )
    # Minimal Rustume build-binary.yml regression: main 992c5f25, blob fc549259.
    # Preserve its bare events and a build operand; never execute source.
    documents.append(
        yaml.safe_load(
            '"on":\n  workflow_call:\n  workflow_dispatch:\n'
            "jobs:\n  build:\n    steps:\n"
            "      - run: ./scripts/ci/release/build-binaries.sh\n",
        ),
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


class Cases(unittest.TestCase):  # pylint: disable=too-many-public-methods
    """Require ordering, main-step evidence and a report-only publication path."""

    def test_unresolved_comment_markers_model_and_cli(self) -> None:
        """Unresolved roles cannot match each other or a known literal role."""
        declaration: dict[str, Any]
        for marker, declaration in (
            ("${{ env.MARKER }}", {}),
            ("${{ inputs.marker }}", {}),
            ("${{ inputs.marker }}", {"marker": {"required": True}}),
            ("${{ inputs.marker }}", {"marker": {"default": "${{ env.MARKER }}"}}),
            ("${{ github.event_name }}", {}),
            ("${{ env.MARKER || 'security' }}", {}),
            ("prefix-${{ env.MARKER }}", {}),
        ):
            reference = comment_probe(marker, catalog=True, inputs=declaration)
            literal = comment_probe("security", catalog=True)
            for value in ("tests", "security", None):
                with self.subTest(marker=marker, declared=value):
                    consumer = comment_probe(marker, marker_value=value)
                    self.assert_candidate_cli(consumer, reference, False)
                    self.assert_candidate_cli(consumer, literal, False)
            self.assert_candidate_cli(comment_probe("security"), reference, False)

    def test_literal_comment_markers_model_and_cli(self) -> None:
        """Literal roles and declared direct input defaults retain matching."""
        for marker in ("security", "${{ inputs.marker }}"):
            reference = comment_probe(
                marker,
                catalog=True,
                inputs={"marker": {"default": "security"}},
            )
            for value, expected in (("security", True), ("tests", False)):
                with self.subTest(marker=marker, value=value):
                    self.assert_candidate_cli(comment_probe(value), reference, expected)
        self.assert_candidate_cli(fixture_units()[1], fixture_units(True)[1], True)

    def test_diagnostic_expansions_model_and_cli(self) -> None:
        """Executable parameter checks and assignments remain required work."""
        middle = {"uses": "org/middle@v1"}
        script = {"run": "bash audit.sh"}
        reference = probe_unit(
            [middle, {"run": "bash ${{ inputs.script }}"}],
            catalog=True,
            inputs={"script": {"default": "audit.sh"}},
        )
        for expansion in (
            "${OTHER:?failure}",
            "${OTHER?failure}",
            "${OTHER:=value}",
            "${OTHER=value}",
            "${OTHER:-fallback}",
            "${OTHER-fallback}",
            "${OTHER:+alternate}",
            "${OTHER+alternate}",
            "${#OTHER}",
            "${!OTHER}",
            "${OTHER/value/replacement}",
            "$(bash extra-check.sh)",
            "$((OTHER += 1))",
            "`bash extra-check.sh`",
        ):
            for name, command in (
                ("artifact warning", f'echo "::warning::{expansion}"'),
                ("Check egress-preset", f'echo "$EGRESS_PRESET {expansion}"; exit 1'),
            ):
                with self.subTest(expansion=expansion, name=name):
                    consumer = probe_unit(
                        [{"name": name, "run": command}, middle, script],
                    )
                    self.assert_candidate_cli(consumer, reference, False)
                    self.assertEqual(len(consumer.core), 3)
                    self.assertTrue(consumer.core[0].startswith("opaque:"))

    def test_literal_diagnostics_model_and_cli(self) -> None:
        """Inert quoting, ordinary variables and genuine egress stay excluded."""
        middle = {"uses": "org/middle@v1"}
        script = {"run": "bash audit.sh"}
        reference = probe_unit(
            [middle, {"run": "bash ${{ inputs.script }}"}],
            catalog=True,
            inputs={"script": {"default": "audit.sh"}},
        )
        for command in (
            'echo "::warning::upload failed"',
            'printf "::warning::upload failed"',
            'echo "::warning::${MISSING_ARTIFACT_WARNING}"',
            'echo "::warning::$MISSING_ARTIFACT_WARNING"',
            "echo '::warning::${OTHER:?failure}'",
            "echo '::warning::${OTHER:=value}'",
            "echo '::warning::$(bash extra-check.sh)'",
            "echo '::warning::`bash extra-check.sh`'",
            r'echo "::warning::\${OTHER:?failure}"',
            r'echo "::warning::\${OTHER:=value}"',
        ):
            with self.subTest(command=command):
                warning = {"name": "artifact warning", "run": command}
                consumer = probe_unit([warning, middle, script])
                self.assertEqual(
                    consumer.core,
                    ("action:org/middle", "script:audit.sh"),
                )
                self.assert_candidate_cli(consumer, reference, True)
                self.assert_candidate_cli(
                    probe_unit([warning, script]),
                    reference,
                    False,
                )
        for command in (
            'echo "$EGRESS_PRESET"; exit 1',
            'echo "::error title=unknown egress-preset::'
            "not a preset - '${EGRESS_PRESET}'\"; exit 1",
        ):
            self.assert_candidate_cli(
                probe_unit(
                    [{"name": "Check egress-preset", "run": command}, middle, script],
                ),
                reference,
                True,
            )

    def assert_candidate_cli(
        self, consumer: model.Unit, reference: model.Unit, expected: bool
    ) -> None:
        """Check real matching and dry/live CLI publication on parsed fixtures."""
        reference = replace(reference, repository=scan.TARGET)
        self.assertEqual(
            bool(model.catalog_subsequences([consumer], [reference])),
            expected,
        )
        for dry_run in (True, False):
            api = FakeGitHub(
                repositories=[
                    {
                        "full_name": scan.TARGET,
                        "private": False,
                        "archived": False,
                        "files": {},
                    },
                    {
                        "full_name": consumer.repository,
                        "private": False,
                        "archived": False,
                        "files": {
                            PATH: yaml.safe_dump(
                                {"jobs": yaml.safe_load(consumer.source)},
                            ),
                        },
                    },
                ]
            )
            output = io.StringIO()
            with (
                offline_cli(dry_run),
                patch.dict(
                    "os.environ",
                    {"GH_TOKEN": "fixture", "GITHUB_STEP_SUMMARY": ""},
                ),
                patch.object(scan, "GitHub", return_value=api),
                patch.object(scan, "references", return_value=[reference]),
                contextlib.redirect_stdout(output),
            ):
                self.assertEqual(scan.main(), 0)
            self.assertEqual(
                "Catalog subsequence candidates" in output.getvalue(),
                expected,
            )
            self.assertEqual(api.skipped["invalid source"], 0)
            self.assertFalse(api.partial)
            self.assertEqual(api.writes, [])

    def test_selected_main_occurrence_model_and_cli(self) -> None:
        """Repeated tokens must align through the actual last primary step."""
        audit = {"run": "bash audit.sh"}
        middle = {"uses": "org/middle@v1"}
        primary = {"run": "bash ${{ inputs.script }}"}
        for steps, consumer_steps, index, expected in (
            ([audit, middle, primary], [audit, middle], 2, False),
            ([audit, middle, primary], [middle, audit], 2, True),
            # Greedy matching consumes the earlier audit, but a later alignment
            # includes main. Both consumer occurrences of audit must be tried.
            ([audit, middle, primary, middle], [audit, middle], 2, True),
            ([audit, primary, middle], [audit, audit, middle], 1, True),
        ):
            with self.subTest(steps=steps, consumer=consumer_steps):
                reference = probe_unit(
                    steps, catalog=True, inputs={"script": {"default": "audit.sh"}}
                )
                self.assertEqual(reference.main_index, index)
                self.assertEqual(reference.core[index], reference.main)
                self.assert_candidate_cli(
                    probe_unit(consumer_steps),
                    reference,
                    expected,
                )

    def test_selected_main_offsets_and_context_model_and_cli(self) -> None:
        """Exclusions and contextual rewrites preserve the selected occurrence."""
        checkout = {"uses": "actions/checkout@v4"}
        upload = {"uses": "actions/upload-artifact@v4"}
        middle = {"uses": "org/middle@v1"}
        audit = {"run": "bash security-audit.sh"}
        prepare = {"run": "bash pull-lintro-image.sh"}
        reference = probe_unit(
            [
                checkout,
                prepare,
                audit,
                upload,
                middle,
                checkout,
                {"run": "bash ${{ inputs.script }}"},
                upload,
            ],
            catalog=True,
            inputs={"script": {"default": "pull-lintro-image.sh"}},
        )
        self.assertEqual(reference.main_index, 3)
        self.assertEqual(reference.main, "role:prepare-audit-container")
        self.assertEqual(reference.core[0], reference.core[3])
        for steps, expected in (
            ([checkout, prepare, audit, middle, upload], False),
            ([checkout, audit, middle, prepare, upload], True),
            ([audit, prepare], True),
        ):
            with self.subTest(steps=steps):
                self.assert_candidate_cli(probe_unit(steps), reference, expected)

    def test_missing_or_inconsistent_main_metadata_model_and_cli(self) -> None:
        """Legacy units stay constructible and fail closed for manual matching."""
        consumer = probe_unit([{"run": "audit.sh"}, {"uses": "org/middle@v1"}])
        reference = probe_unit(
            [{"run": "${{ inputs.script }}"}, {"uses": "org/middle@v1"}],
            catalog=True,
            inputs={"script": {"default": "audit.sh"}},
        )
        for index in (None, -1, len(reference.core), 1, True):
            with self.subTest(index=index):
                changed = replace(reference, main_index=index)
                self.assert_candidate_cli(consumer, changed, False)
                self.assertEqual(changed.source, reference.source)
                self.assertEqual(changed.shape, reference.shape)
                self.assertEqual(changed.fingerprint, reference.fingerprint)
                self.assertTrue(model.catalog_match(changed, reference))
        absent = probe_unit(
            [{"run": "audit.sh"}, {"uses": "org/middle@v1"}],
            catalog=True,
        )
        self.assertIsNone(absent.main_index)
        self.assert_candidate_cli(consumer, absent, False)
        legacy = model.Unit(
            reference.repository,
            reference.path,
            reference.job,
            reference.private,
            reference.kind,
            reference.shape,
            reference.source,
            core=reference.core,
            main=reference.main,
        )
        self.assertIsNone(legacy.main_index)
        self.assert_candidate_cli(consumer, legacy, False)

    def test_interpreter_options_model_and_cli(self) -> None:
        """Unsupported options retain interpreter identity and literal commands."""
        main = {"run": "bash ${{ inputs.script }}"}
        reference = probe_unit(
            [{"run": "bash -e audit.js"}, main],
            catalog=True,
            inputs={"script": {"default": "audit.sh"}},
        )
        self.assertEqual(reference.core[0], "command:bash -e audit.js")
        for command, expected in (
            ("node -e audit.js", False),
            ("bash -e audit.js", True),
            ("-e audit.js", False),
            ("audit.js", False),
        ):
            with self.subTest(command=command):
                consumer = probe_unit([{"run": command}, {"run": "bash audit.sh"}])
                self.assert_candidate_cli(consumer, reference, expected)
        literal = probe_unit(
            [{"run": "npm test"}, main],
            catalog=True,
            inputs={"script": {"default": "audit.sh"}},
        )
        for command, expected in (("npm test", True), ("npm build", False)):
            self.assert_candidate_cli(
                probe_unit([{"run": command}, {"run": "audit.sh"}]), literal, expected
            )

    def test_supported_script_forms_model_and_cli(self) -> None:
        """Plain interpreters/direct scripts normalize with STEP selectors intact."""
        prefix = {"uses": "org/middle@v1"}
        for command in (
            "bash audit.sh",
            "sh ./bin/audit.sh",
            "python audit.py",
            "python3 ./bin/audit.py",
            "node audit.js",
            "node audit.mjs",
            "./bin/audit.sh",
        ):
            operand = command.split()[-1]
            reference = probe_unit(
                [prefix, {"run": "${{ inputs.script }}", "env": {"STEP": "check"}}],
                catalog=True,
                inputs={"script": {"default": operand}},
            )
            for selector, expected in (("check", True), ("build", False)):
                with self.subTest(command=command, selector=selector):
                    consumer = probe_unit(
                        [prefix, {"run": command, "env": {"STEP": selector}}],
                    )
                    self.assert_candidate_cli(consumer, reference, expected)

    def test_bats_wiring_complete(self) -> None:
        """Every public helper test is selected by an actual BATS case."""
        bats = Path(__file__).resolve().parents[1] / "bats/unit/maintenance"
        source = (bats / "test_duplication_scan.bats").read_text()
        wired = set(
            re.findall(
                r'^\s*check_case (test_\w+) "\$SUBSEQUENCE_CHECKS"\s*$',
                source,
                re.M,
            )
        )

        def missing() -> set[str]:
            return set(unittest.defaultTestLoader.getTestCaseNames(Cases)) - wired

        self.assertEqual(missing(), set())
        with patch.object(
            Cases,
            "test_deliberately_unwired",
            lambda self: None,
            create=True,
        ):
            self.assertEqual(missing(), {"test_deliberately_unwired"})
            with self.assertRaises(AssertionError):
                self.assertEqual(missing(), set())

    def test_shell_quoting_model_and_cli(self) -> None:
        """Literal/escaped dollars and split operands cannot manufacture matches."""
        prefix = {"uses": "org/core@v1"}
        inputs = {"script": {"default": "security-audit.sh"}}
        reference = probe_unit(
            [prefix, {"run": "bash '${{ inputs.script }}'"}],
            catalog=True,
            inputs=inputs,
        )
        self.assertEqual(reference.main, "script:security-audit")
        for command, value, expected in (
            ("bash '$SCRIPT'", "security-audit.sh", False),
            ('bash "$SCRIPT"', "security-audit.sh", True),
            ("bash $SCRIPT", "security-audit.sh", True),
            ('bash "${SCRIPT}"', "security-audit.sh", True),
            (r"bash \$SCRIPT", "security-audit.sh", False),
            (r'bash "\$SCRIPT"', "security-audit.sh", False),
            ("bash $SCRIPT", "security-audit.sh ignored", False),
            ('bash "$SCRIPT"', "security-audit.sh ignored", False),
            ('bash "$SCRIPT"', 'security-audit.sh" ignored', False),
            ('bash "${SCRIPT:-security-audit.sh}"', "security-audit.sh", False),
        ):
            with self.subTest(command=command, value=value):
                consumer = probe_unit(
                    [prefix, {"run": command}],
                    job_env={"SCRIPT": value},
                )
                self.assertEqual(consumer.core[-1] == reference.main, expected)
                self.assert_candidate_cli(consumer, reference, expected)
                inherited = probe_unit(
                    [prefix, {"run": command}],
                    catalog=True,
                    inputs={"script": {"default": value}},
                    job_env={"SCRIPT": "${{ inputs.script }}"},
                )
                self.assertEqual(bool(inherited.main), expected)

    def test_action_file_defaults_model_and_cli(self) -> None:
        """A file input needs a declared supported default to anchor an action."""
        action = {
            "uses": "org/core@v1",
            "with": {"file": "${{ inputs.report-file }}"},
        }
        consumer = probe_unit(
            [{"uses": "org/core@v1", "with": {"file": "unrelated.txt"}}],
        )
        for declaration in (
            {},
            {"report-file": {"required": True, "type": "string"}},
            {"report-file": {"default": ""}},
            {"report-file": {"default": None}},
            {"report-file": {"default": 42}},
            {"report-file": {"default": "${{ github.workspace }}/report.txt"}},
            {
                "report-file": {"default": "${{ inputs.other }}"},
                "other": {"default": "report.txt"},
            },
            {"report-file": {"default": "audit.txt"}},
        ):
            with self.subTest(inputs=declaration):
                expected = declaration == {"report-file": {"default": "audit.txt"}}
                reference = probe_unit([action], catalog=True, inputs=declaration)
                self.assertEqual(bool(reference.main), expected)
                self.assert_candidate_cli(consumer, reference, expected)
        unsupported = probe_unit(
            [
                {
                    **action,
                    "with": {"file": "${{ inputs.report-file || 'fallback.txt' }}"},
                },
            ],
            catalog=True,
            inputs={"report-file": {"default": "audit.txt"}},
        )
        self.assertEqual(unsupported.main, "")
        self.assert_candidate_cli(consumer, unsupported, False)
        path = f".github/workflows/{COMMENT}.yml"
        comment = model.units(
            scan.TARGET,
            False,
            {path: (scan.ROOT / path).read_text()},
            reference=COMMENT,
        )[0]
        self.assertTrue(comment.main.startswith("action:lgtm-ci/post-pr-comment:"))
        self.assert_candidate_cli(fixture_units()[1], comment, True)

    def test_valid_optional_model_mappings(self) -> None:
        """Optional nulls are empty; required input definitions remain strict."""
        for document in valid_optional_documents():
            with self.subTest(document=document):
                skipped: Counter[str] = Counter()
                found = model.units(
                    "org/consumer",
                    False,
                    {PATH: yaml.safe_dump(document)},
                    skipped=skipped,
                )
                self.assertEqual(skipped, {})
                self.assertEqual(len(found), 1)
                self.assertTrue(found[0].core)
                self.assertEqual(found[0].main, "")

    def test_valid_optional_cli_mappings(self) -> None:
        """Dry/live CLI retains null controls and publishes no manual candidates."""
        manual = yaml.safe_dump(
            {
                "jobs": yaml.safe_load(
                    "\n".join(unit.source for unit in fixture_units()),
                ),
            },
        )
        for document in valid_optional_documents():
            for dry_run in (True, False):
                with self.subTest(document=document, dry_run=dry_run):
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
                                "files": {
                                    PATH: yaml.safe_dump(document),
                                    ".github/workflows/manual.yml": manual,
                                },
                            },
                        ],
                    )
                    output = io.StringIO()
                    with (
                        offline_cli(dry_run),
                        patch.dict(
                            "os.environ",
                            {"GH_TOKEN": "fixture", "GITHUB_STEP_SUMMARY": ""},
                        ),
                        patch.object(scan, "GitHub", return_value=api),
                        patch.object(
                            scan,
                            "references",
                            return_value=fixture_units(True),
                        ),
                        contextlib.redirect_stdout(output),
                    ):
                        self.assertEqual(scan.main(), 0)
                    self.assertEqual(api.skipped["invalid source"], 0)
                    self.assertFalse(api.partial)
                    self.assertNotIn("Partial scan", output.getvalue())
                    self.assertIn("; 3 units;", output.getvalue())
                    self.assertIn(AUDIT, output.getvalue())
                    self.assertIn(COMMENT, output.getvalue())
                    self.assertEqual(api.writes, [])

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
