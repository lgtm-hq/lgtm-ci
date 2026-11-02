# SPDX-License-Identifier: MIT
"""Offline output-producer and step-directory expression scope regressions."""

from __future__ import annotations

import json
import unittest
from itertools import product
from typing import Any

import duplication_scan_dependency_checks as dependency
import yaml
from duplication_scan_dependency_checks import ACTION, LARGE, SMALL, WORKFLOW
from duplication_scan_yaml_checks import Cases as YamlCases


class Cases(YamlCases):
    """Exercise scoped carriers with production inventory and both CLI modes."""

    def test_output_producer_scopes(self) -> None:
        """Literal producers retain scoped data through exported output chains."""
        for scope, exported, producer_first in product(
            ("composite-input", "workflow-input", "job-env", "matrix"),
            (False, True),
            (False, True),
        ):
            step: dict[str, Any] = {"run": "printf ok", "shell": "bash"}
            producer: dict[str, Any] = {"steps": [step]}
            document: dict[str, Any] = {"description": SMALL}
            reference = "inputs.program"
            declaration = {"program": {"default": LARGE, "description": SMALL}}
            path = WORKFLOW
            if scope == "composite-input":
                path = ACTION
                document.update(
                    {
                        "inputs": declaration,
                        "outputs": {
                            "program": {
                                "value": "${{ inputs.program }}",
                                "description": SMALL,
                            }
                        },
                        "runs": {"using": "composite", "steps": [step]},
                    }
                )
            else:
                if scope == "workflow-input":
                    document["on"] = {"workflow_call": {"inputs": declaration}}
                elif scope == "job-env":
                    producer["env"] = {"SCRIPT": LARGE}
                    reference = "env.SCRIPT"
                else:
                    producer["strategy"] = {"matrix": {"script": [LARGE]}}
                    reference = "matrix.script"
                producer["outputs"] = {"program": "${{ " + reference + " }}"}
                bridge = {
                    "needs": "prepare",
                    "outputs": {
                        "program": "${{ needs.prepare.outputs.program }}",
                    },
                    "steps": [{"run": "printf ok"}],
                }
                jobs = {"prepare": producer, "bridge": bridge}
                if not producer_first:
                    jobs = dict(reversed(jobs.items()))
                document["jobs"] = jobs
                call = document.setdefault("on", {}).setdefault("workflow_call", {})
                call["outputs"] = {
                    "program": {
                        "value": "${{ jobs.bridge.outputs.program }}",
                        "description": SMALL,
                    },
                }
            if path == WORKFLOW and not exported:
                call.pop("outputs", None)
                document["jobs"]["check"] = {
                    "needs": "bridge",
                    "steps": [
                        {"run": "python '${{ needs.bridge.outputs.program }}'"},
                    ],
                }
            files = {path: yaml.safe_dump(document, sort_keys=False)}
            reference = "steps.emit" if path == ACTION else "needs.emit"
            consumer = {"run": f"python '${{{{ {reference}.outputs.program }}}}'"}
            if path == ACTION:
                files[WORKFLOW] = yaml.safe_dump(
                    {
                        "jobs": {
                            "check": {
                                "steps": [
                                    {
                                        "id": "emit",
                                        "uses": "./.github/actions/check",
                                    },
                                    consumer,
                                ]
                            }
                        }
                    }
                )
            else:
                files[".github/workflows/caller.yml"] = yaml.safe_dump(
                    {
                        "jobs": {
                            "emit": {"uses": "./" + WORKFLOW},
                            "check": {
                                "needs": "emit",
                                "steps": [
                                    consumer,
                                ],
                            },
                        }
                    }
                )
            with self.subTest(scope=scope, producer_first=producer_first):
                dependency.Cases().assert_reachable(files)

    def test_output_producer_scope_controls(self) -> None:
        """Exports do not retain unused scopes, defaults or descriptions."""
        for output in ("literal", "${{ contains('inputs.program env.SCRIPT', 'x') }}"):
            for path in (WORKFLOW, ACTION):
                document: dict[str, Any] = {
                    "description": LARGE,
                    "env": {"SCRIPT": LARGE},
                }
                declaration = {"program": {"default": LARGE, "description": LARGE}}
                step = {"run": "printf ok", "shell": "bash", "env": {"SCRIPT": LARGE}}
                exported = {"program": {"value": output, "description": LARGE}}
                if path == ACTION:
                    document.update(
                        {
                            "inputs": declaration,
                            "outputs": exported,
                            "runs": {"using": "composite", "steps": [step]},
                        }
                    )
                else:
                    document["on"] = {
                        "workflow_call": {"inputs": declaration, "outputs": exported},
                    }
                    document["jobs"] = {
                        "idle": {
                            "env": {"SCRIPT": LARGE},
                            "strategy": {"matrix": {"script": [LARGE]}},
                            "outputs": {"program": output},
                            "steps": [step],
                        },
                        "other": {
                            "env": {"SCRIPT": LARGE},
                            "steps": [{"run": "printf ok"}],
                        },
                    }
                with self.subTest(output=output, path=path):
                    self._assert_inert_modes({path: yaml.safe_dump(document)})
        # Without an executable consumer or export, even output expressions are unused.
        files = {
            WORKFLOW: yaml.safe_dump(
                {
                    "jobs": {
                        "idle": {
                            "env": {"SCRIPT": LARGE},
                            "outputs": {"program": "${{ env.SCRIPT }}"},
                            "steps": [{"run": "printf ok"}],
                        }
                    }
                }
            )
        }
        self._assert_inert_modes(files)
        # A consumed output's scope cannot reach a sibling step/job environment.
        consumer = {"run": "python '${{ needs.prepare.outputs.program }}'"}
        files = {
            WORKFLOW: yaml.safe_dump(
                {
                    "jobs": {
                        "prepare": {
                            "outputs": {"program": "${{ env.SCRIPT }}"},
                            "env": {"SCRIPT": "tools/gate.txt"},
                            "steps": [{"run": "printf ok", "env": {"SCRIPT": LARGE}}],
                        },
                        "idle": {
                            "env": {"SCRIPT": LARGE},
                            "strategy": {"matrix": {"script": [LARGE]}},
                            "steps": [{"run": "printf ok"}],
                        },
                        "check": {"needs": "prepare", "steps": [consumer]},
                    }
                }
            )
        }
        self._assert_inert_modes(files)

    def test_step_directory_expressions(self) -> None:
        """Only expression spans in a step's own directory read source hints."""
        for expression in (
            f"${{{{ hashFiles('{LARGE}') && '.' || '.' }}}}",
            "${{ fromJSON('" + json.dumps("\n./" + LARGE) + "') }}",
        ):
            for path in (WORKFLOW, ACTION):
                step = {
                    "run": "printf ok",
                    "shell": "bash",
                    "working-directory": expression,
                }
                document = (
                    {"jobs": {"check": {"steps": [step]}}}
                    if path == WORKFLOW
                    else {"runs": {"using": "composite", "steps": [step]}}
                )
                with self.subTest(expression=expression, path=path):
                    dependency.Cases().assert_reachable(
                        {path: yaml.safe_dump(document)},
                    )

    def test_step_directory_scoped_data(self) -> None:
        """Directory expressions retain their own inputs, env and matrix carriers."""
        input_scopes = ("workflow_call", "workflow_dispatch", "composite-input")
        env_scopes = ("workflow-env", "job-env", "step-env", "composite-env")
        for scope in (*input_scopes, *env_scopes, "matrix"):
            for indexed in (False, True):
                step: dict[str, Any] = {"run": "printf ok", "shell": "bash"}
                job: dict[str, Any] = {"steps": [step]}
                document: dict[str, Any] = {
                    "jobs": {"check": job},
                    "description": SMALL,
                }
                path, context, key = WORKFLOW, "env", "SCRIPT"
                if scope in {"workflow_call", "workflow_dispatch"}:
                    document["on"] = {
                        scope: {
                            "inputs": {
                                "program": {"default": LARGE, "description": SMALL},
                            }
                        }
                    }
                    context, key = "inputs", "program"
                elif scope in {"workflow-env", "job-env", "step-env"}:
                    owner = {
                        "workflow-env": document,
                        "job-env": job,
                        "step-env": step,
                    }[scope]
                    owner["env"] = {"SCRIPT": LARGE}
                elif scope == "matrix":
                    job["strategy"] = {"matrix": {"program": [LARGE]}}
                    context, key = "matrix", "program"
                else:
                    path = ACTION
                    document = {
                        "runs": {"using": "composite", "steps": [step]},
                        "description": SMALL,
                    }
                    if scope == "composite-input":
                        document["inputs"] = {
                            "program": {"default": LARGE, "description": SMALL},
                        }
                        context, key = "inputs", "program"
                    else:
                        step["env"] = {"SCRIPT": LARGE}
                reference = f"{context}['{key}']" if indexed else f"{context}.{key}"
                directory = "${{ hashFiles(" + reference + ") && '.' || '.' }}"
                step["working-directory"] = directory
                with self.subTest(scope=scope, indexed=indexed):
                    dependency.Cases().assert_reachable(
                        {path: yaml.safe_dump(document)},
                    )

    def test_step_directory_output_carriers(self) -> None:
        """Directory consumers retain output scopes regardless of producer order."""
        for scope in ("direct", "env", "matrix"):
            for producer_first in (False, True):
                reference = "needs.prepare.outputs.program"
                step: dict[str, Any] = {"run": "printf ok"}
                job: dict[str, Any] = {"needs": "prepare", "steps": [step]}
                if scope == "env":
                    step["env"] = {"PROGRAM": "${{ " + reference + " }}"}
                    reference = "env.PROGRAM"
                elif scope == "matrix":
                    job["strategy"] = {
                        "matrix": {"program": ["${{ " + reference + " }}"]},
                    }
                    reference = "matrix.program"
                directory = "${{ hashFiles(" + reference + ") && '.' || '.' }}"
                step["working-directory"] = directory
                jobs = {
                    "check": job,
                    "prepare": {
                        "env": {"SCRIPT": LARGE},
                        "outputs": {"program": "${{ env.SCRIPT }}"},
                        "steps": [{"run": "printf ok"}],
                    },
                }
                if producer_first:
                    jobs = dict(reversed(jobs.items()))
                with self.subTest(scope=scope, producer_first=producer_first):
                    dependency.Cases().assert_reachable(
                        {WORKFLOW: yaml.safe_dump({"jobs": jobs}, sort_keys=False)}
                    )

    def test_step_directory_scope_controls(self) -> None:
        """Literal directories and context-like quoted/descriptive data stay inert."""
        for directory in (
            LARGE,
            "env.SCRIPT",
            "${{ contains('env.SCRIPT inputs.program matrix.script', 'x') }}",
        ):
            for path in (WORKFLOW, ACTION):
                step = {
                    "run": "printf ok",
                    "shell": "bash",
                    "working-directory": directory,
                    "env": {"SCRIPT": LARGE},
                    "name": "${{ hashFiles('" + LARGE + "') }}",
                }
                document: dict[str, Any] = {
                    "env": {"SCRIPT": LARGE},
                    "description": LARGE,
                }
                if path == WORKFLOW:
                    document["on"] = {
                        "workflow_call": {"inputs": {"program": {"default": LARGE}}},
                    }
                    document["jobs"] = {
                        "check": {
                            "strategy": {"matrix": {"script": [LARGE]}},
                            "steps": [step],
                        }
                    }
                else:
                    document["inputs"] = {"program": {"default": LARGE}}
                    document["runs"] = {"using": "composite", "steps": [step]}
                with self.subTest(directory=directory, path=path):
                    self._assert_inert_modes({path: yaml.safe_dump(document)})
        idle = {
            "steps": [{"run": "printf ok"}],
            "env": {"SCRIPT": LARGE},
            "strategy": {"matrix": {"script": [LARGE]}},
        }
        directory = "${{ hashFiles(env.SCRIPT) && '.' || '.' }}"
        step = {
            "run": "printf ok",
            "env": {"SCRIPT": "tools/gate.txt"},
            "working-directory": directory,
        }
        document = {
            "jobs": {
                "idle": idle,
                "check": {
                    "steps": [
                        {"run": "printf ok", "env": {"SCRIPT": LARGE}},
                        step,
                    ]
                },
            }
        }
        self._assert_inert_modes({WORKFLOW: yaml.safe_dump(document)})


if __name__ == "__main__":
    unittest.main()
