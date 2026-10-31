# SPDX-License-Identifier: MIT
"""Conservative executable source regressions driven by the scanner BATS suite."""

from __future__ import annotations

import unittest

from duplication_scan_regression_checks import job_unit
from duplication_scan_support import FixtureCase, model, syntax


class Cases(FixtureCase):
    """Keep unknown imports isolated and executable constants significant."""

    def test_python_computed_process_launchers(self) -> None:
        """Literal/computed attribute names cannot erase process identities."""
        path = "scripts/check.py"
        for source in (
            'import os\ngetattr(os, "system")("tools/release")\n',
            'import os\ngetattr(os, "sys" + "tem")("tools/release")\n',
            'import os as ops\ngetattr(ops, name)("tools/release")\n',
            'import os\nlaunch = getattr(os, "system")\nlaunch("tools/release")\n',
            'import os\nos.__getattribute__("system")("tools/release")\n',
            'import os\nlookup = getattr\nlookup(os, name)("tools/release")\n',
            'import posix\ngetattr(posix, "system")("tools/release")\n',
            'import nt\ngetattr(nt, name)("tools/release")\n',
            "import asyncio as aio\nasync def main():\n"
            '    await getattr(aio, "create_" + "subprocess_shell")("tools/release")\n'
            "aio.run(main())\n",
        ):
            changed = source.replace("tools/release", "tools/check")
            repos = ("org/left", "org/right", "org/left")
            sources = (source, source, changed)
            scripts = [
                model.units(repo, False, {path: text})[0]
                for repo, text in zip(repos, sources, strict=True)
            ]
            jobs = [
                job_unit(
                    repo,
                    {"steps": [{"run": f"python {path}"}]},
                    files={path: text},
                )
                for repo, text in zip(repos, sources, strict=True)
            ]
            self.assertIn("<unresolved-python-command:", " ".join(scripts[0].shape))
            for left, copy, different in (scripts, jobs):
                with self.subTest(source=source, kind=left.kind):
                    for right in (copy, different):
                        self.assertNotEqual(left.fingerprint, right.fingerprint)
                        self.assertEqual(model.clusters([left, right], [], 0.8), [])
        # Launcher/lookup words inside data strings are still ordinary inputs.
        for word in ("getattr", "__getattribute__", "system", "sys", "tem"):
            scripts = [
                model.units(
                    repo,
                    False,
                    {path: f'import os\nprint("{word}", "{output}")\n'},
                )[0]
                for repo, output in (
                    ("org/left", "build/output"),
                    ("org/right", "dist/result"),
                )
            ]
            self.assertNotIn("<unresolved-", " ".join(scripts[0].shape))
            self.assertEqual(scripts[0].fingerprint, scripts[1].fingerprint)
            self.assertEqual(len(model.clusters(scripts, [], 0.8)), 1)

    def test_python_runpy_execution(self) -> None:
        """Uninspected file/module execution cannot establish equivalence."""
        path = "scripts/check.py"
        sources = (
            'import runpy\nrunpy.run_path("tools/release.py")\n',
            'import runpy as runner\nrunner.run_path("tools/release.py")\n',
            'from runpy import run_path as launch\nlaunch("tools/release.py")\n',
            'from runpy import (run_path as launch,)\nlaunch("tools/release.py")\n',
            'import runpy\nlaunch = runpy.run_path\nlaunch("tools/release.py")\n',
            "import runpy\nrunpy.run_path(target)\n",
            'import runpy\nrunpy.run_path("tools/" + name + ".py")\n',
            "import runpy as runner\ngetattr(runner, api)(target)\n",
            "from runpy import *\nrun_path(target)\n",
            'import runpy\nrunpy.run_module("tools.release")\n',
            "from runpy import run_module as launch\nlaunch(module)\n",
            'import runpy as runner\nrunner._run_module_as_main("tools.release")\n',
            "from runpy import _run_code as launch\nlaunch(code, {})\n",
            'getattr(__import__("runpy"), api)(target)\n',
            "from importlib import import_module as f\ngetattr(f(name), api)(target)\n",
            "import importlib as lib\ngetattr(lib, load)(name).run_path(target)\n",
        )
        for source in sources:
            for changed in (source, source.replace("release", "check")):
                for implementation in ("raise SystemExit(7)\n", None):
                    with self.subTest(
                        source=source,
                        changed=changed,
                        body=implementation,
                    ):
                        inventories = [
                            {path: source, "tools/release.py": "print('safe')\n"},
                        ]
                        other = {path: changed}
                        if implementation is not None:
                            other["tools/release.py"] = implementation
                            other["tools/check.py"] = implementation
                        inventories.append(other)
                        scripts = [
                            model.file_units(
                                repo,
                                False,
                                path,
                                files[path],
                                files,
                                "",
                            )[0]
                            for repo, files in zip(
                                ("org/left", "org/right"), inventories, strict=True
                            )
                        ]
                        jobs = [
                            job_unit(
                                repo,
                                {"steps": [{"run": f"python {path}"}]},
                                files=files,
                            )
                            for repo, files in zip(
                                ("org/left", "org/right"), inventories, strict=True
                            )
                        ]
                        self.assertIn(
                            "<unresolved-python-command:",
                            " ".join(scripts[0].shape),
                        )
                        for left, right in (scripts, jobs):
                            self.assertNotEqual(left.fingerprint, right.fingerprint)
                            self.assertEqual(model.clusters([left, right], [], 0.8), [])

    def test_python_numeric_strings(self) -> None:
        """String tokens alone never establish that a decimal is a version."""
        path = "scripts/check.py"
        for template, original, changed in (
            ('from decimal import Decimal\nvalue = Decimal("{}")\n', "1.5", "9.5"),
            ('threshold = float("{}")\n', "0.8", "0.9"),
            ("threshold = float('{}')\n", "1.2e3", "1.3e3"),
            ('if value == "{}":\n    raise SystemExit(1)\n', "1.5", "9.5"),
            ('version = "{}"\n', "3.11", "3.12"),
        ):
            values = (original, original, changed)
            sources = [template.format(value) for value in values]
            repos = ("org/left", "org/right", "org/right")
            scripts = [
                model.units(repo, False, {path: source})[0]
                for repo, source in zip(repos, sources, strict=True)
            ]
            jobs = [
                job_unit(
                    repo,
                    {"steps": [{"run": f"python {path}"}]},
                    files={path: source},
                )
                for repo, source in zip(repos, sources, strict=True)
            ]
            for left, same, right in (scripts, jobs):
                with self.subTest(template=template, kind=left.kind):
                    self.assertNotIn("<unresolved-", " ".join(left.shape))
                    self.assertEqual(left.fingerprint, same.fingerprint)
                    self.assertEqual(len(model.clusters([left, same], [], 0.8)), 1)
                    self.assertNotEqual(left.fingerprint, right.fingerprint)
                    self.assertEqual(model.clusters([left, right], [], 0.8), [])

    def test_decimal_command_arguments(self) -> None:
        """Durations, thresholds and timeouts are behavior, even when quoted."""
        path = "scripts/check.sh"
        for original, changed in (
            ("sleep 0.5", "sleep 30.0"),
            ('sleep "0.5"', 'sleep "30.0"'),
            ("sleep '0.5'", "sleep '30.0'"),
            ("check --threshold 0.8", "check --threshold 0.9"),
            ("check --timeout=1.5", "check --timeout=2.5"),
            ("check --threshold -1.2e3", "check --threshold -1.3e3"),
        ):
            with self.subTest(original=original, changed=changed):
                self.assertNotEqual(
                    syntax.normalize(original, "org/left"),
                    syntax.normalize(changed, "org/right"),
                )
                repos = ("org/left", "org/right", "org/right")
                sources = (original, original, changed)
                scripts = [
                    model.units(repo, False, {path: source})[0]
                    for repo, source in zip(repos, sources, strict=True)
                ]
                jobs = [
                    job_unit(repo, {"steps": [{"run": source}]})
                    for repo, source in zip(repos, sources, strict=True)
                ]
                callers = [
                    job_unit(
                        repo,
                        {"steps": [{"run": f"bash {path}"}]},
                        files={path: source},
                    )
                    for repo, source in zip(repos, sources, strict=True)
                ]
                for left, same, right in (scripts, jobs, callers):
                    self.assertNotIn("<unresolved-", " ".join(left.shape))
                    self.assertEqual(left.fingerprint, same.fingerprint)
                    self.assertEqual(len(model.clusters([left, same], [], 0.8)), 1)
                    self.assertNotEqual(left.fingerprint, right.fingerprint)
                    self.assertEqual(model.clusters([left, right], [], 0.8), [])
        self.assertEqual(
            syntax.normalize(
                "echo --outdir build/output --image ghcr.io/org/left:1.0",
                "org/left",  # Compare independently normalized repository parameters.
            ),
            syntax.normalize(
                "echo --outdir dist/result --image ghcr.io/org/right:2.0", "org/right"
            ),
        )

    def test_python_module_commands(self) -> None:
        """Module invocations cannot establish equality from uninspected bodies."""
        path = "scripts/check.sh"
        for command, dependency in (
            ("python -m tools.check", "tools/check.py"),
            ("python3.13 -m tools.check", "tools/check/__main__.py"),
            ("uv run python -m tools.check", "tools/check.py"),
            ("env MODE=test python -m tools.check", "tools/check.py"),
            ("python -m build", "build/__main__.py"),
        ):
            for implementation in ("print('check')\n", "raise SystemExit(7)\n", None):
                with self.subTest(command=command, implementation=implementation):
                    inventories = [{dependency: "print('check')\n"}]
                    other: dict[str, str] = {}
                    if implementation is not None:
                        other[dependency] = implementation
                    inventories.append(other)
                    jobs = [
                        job_unit(repo, {"steps": [{"run": command}]}, files=files)
                        for repo, files in zip(
                            ("org/left", "org/right"),
                            inventories,  # Pair missing implementations too.
                            strict=True,
                        )
                    ]
                    scripts = [
                        model.file_units(repo, False, path, command, files, "")[0]
                        for repo, files in zip(
                            ("org/left", "org/right"),
                            inventories,  # Pair missing implementations too.
                            strict=True,
                        )
                    ]
                    for left, right in (jobs, scripts):
                        self.assertIn("<unresolved-", " ".join(left.shape))
                        self.assertNotEqual(left.fingerprint, right.fingerprint)
                        self.assertEqual(model.clusters([left, right], [], 0.8), [])
        # Explicit Python files are still inspected; module-like data stays data.
        for command in ("python scripts/check.py", 'echo "python -m tools.check"'):
            jobs = [
                job_unit(
                    repo,
                    {"steps": [{"run": command}]},
                    files={"scripts/check.py": "print('check')\n"},
                )
                for repo in ("org/left", "org/right")
            ]
            self.assertEqual(jobs[0].fingerprint, jobs[1].fingerprint)
            self.assertEqual(len(model.clusters(jobs, [], 0.8)), 1)

    def test_python_operators(self) -> None:
        """Operators retain behavior in standalone and workflow-called scripts."""
        path = "scripts/check.py"
        for original, changed in (
            ("x // 2\n", "x //= 2\n"),
            ("x / 2\n", "x // 2\n"),
            ("x // 2\n", "x * 2\n"),
            ("x += 2\n", "x -= 2\n"),
        ):
            sources = (original, original, changed)
            repos = ("org/left", "org/right", "org/right")
            scripts = [
                model.units(repo, False, {path: source})[0]
                for repo, source in zip(repos, sources, strict=True)
            ]
            jobs = [
                job_unit(
                    repo,
                    {"steps": [{"run": f"python {path}"}]},
                    files={path: source},
                )
                for repo, source in zip(repos, sources, strict=True)
            ]
            for left, same, right in (scripts, jobs):
                with self.subTest(original=original, changed=changed, kind=left.kind):
                    self.assertEqual(left.fingerprint, same.fingerprint)
                    self.assertEqual(len(model.clusters([left, same], [], 0.8)), 1)
                    self.assertNotEqual(left.fingerprint, right.fingerprint)
                    self.assertEqual(model.clusters([left, right], [], 0.8), [])

    def test_python_numeric_thresholds(self) -> None:
        """Different numeric logic cannot qualify standalone or called scripts."""
        path = "scripts/check.py"
        for template, original, changed in (
            ("assert coverage >= {}\n", "0.8", "0.9"),
            ("threshold = {}\n", "1.5", "2.5"),
            ("assert delta >= {}\n", "-0.8", "-0.9"),
            ("assert coverage >= {}\n", "0.8", "1.2e3"),
            ("assert elapsed < {}\n", "1.2e3", "1.3e3"),
            ("if coverage < {}:\n    raise SystemExit(1)\n", "0.8", "0.9"),
            ("while elapsed < {}:\n    elapsed += 1\n", "1.2e3", "1.3e3"),
            ("threshold = {}\n", "1.2e3", "1.2E3"),
        ):
            values = (original, original, changed)
            sources = [template.format(value) for value in values]
            scripts = [
                model.units(repo, False, {path: source})[0]
                for repo, source in zip(
                    ("org/left", "org/right", "org/right"), sources, strict=True
                )
            ]
            jobs = [
                job_unit(
                    repo,
                    {"steps": [{"run": f"python {path}"}]},
                    files={path: source},
                )
                for repo, source in zip(
                    ("org/left", "org/right", "org/right"), sources, strict=True
                )
            ]
            for left, same, right in (scripts, jobs):
                with self.subTest(
                    template=template,
                    values=(original, changed),
                    kind=left.kind,
                ):
                    self.assertNotIn("<unresolved-", " ".join(left.shape))
                    self.assertEqual(left.fingerprint, same.fingerprint)
                    self.assertEqual(len(model.clusters([left, same], [], 0.8)), 1)
                    self.assertNotEqual(left.fingerprint, right.fingerprint)
                    self.assertEqual(model.clusters([left, right], [], 0.8), [])

    def test_python_known_parameters(self) -> None:
        """Path strings and explicit workflow version inputs still normalize."""
        path = "scripts/check.py"
        source = (
            'from pathlib import Path\nversion = "3.11"\n'
            'output = Path("build/output")\nassert coverage >= 0.8\n'
        )
        changed = source.replace("build/output", "dist/result")
        left, right = [
            model.units(repo, False, {path: text})[0]
            for repo, text in (("org/left", source), ("org/right", changed))
        ]
        self.assertEqual(left.fingerprint, right.fingerprint)
        self.assertEqual(len(model.clusters([left, right], [], 0.8)), 1)
        for action, name in (
            ("actions/setup-python", "python-version"),
            ("actions/setup-node", "node-version"),
            ("astral-sh/setup-uv", "version"),
            ("astral-sh/setup-uv", "python-version"),
        ):
            with self.subTest(action=action, name=name):
                jobs = [
                    job_unit(
                        repo,
                        {"steps": [{"uses": f"{action}@abc", "with": {name: version}}]},
                    )
                    for repo, version in (("org/left", "3.11"), ("org/right", "3.12"))
                ]
                self.assertEqual(jobs[0].fingerprint, jobs[1].fingerprint)
                self.assertEqual(len(model.clusters(jobs, [], 0.8)), 1)

    def test_python_local_imports(self) -> None:
        """An identical entrypoint cannot hide different imported implementations."""
        path = "scripts/check.py"
        for source, dependency in (
            ("from helper import main; main()\n", "scripts/helper.py"),
            ("import helper\nhelper.main()\n", "scripts/helper.py"),
            ("import helper as impl\nimpl.main()\n", "scripts/helper.py"),
            ("from helper import main as run\nrun()\n", "scripts/helper.py"),
            ("from helper import (\n    main,\n)\nmain()\n", "scripts/helper.py"),
            ("from .helper import main\nmain()\n", "scripts/helper.py"),
            ("from package.helper import main\nmain()\n", "scripts/package/helper.py"),
            ("import json, helper\nhelper.main()\n", "scripts/helper.py"),
            ("if True:\n from helper import main\n main()\n", "scripts/helper.py"),
        ):
            for helper in (
                "def main():\n    print('check')\n",
                "def main():\n    raise RuntimeError('release')\n",
                "import os\ndef main():\n    os.system('tools/release')\n",
                None,
            ):
                with self.subTest(source=source, helper=helper):
                    files = {path: source}
                    if helper is not None:
                        files[dependency] = helper
                    baseline = {path: source, dependency: "def main():\n    return 0\n"}
                    left = model.file_units(
                        "org/left",
                        False,
                        path,
                        source,
                        baseline,
                        "",
                    )[0]
                    right = model.file_units(
                        "org/right",
                        False,
                        path,
                        source,
                        files,
                        "",
                    )[0]
                    self.assertNotEqual(left.fingerprint, right.fingerprint)
                    self.assertEqual(model.clusters([left, right], [], 0.8), [])
                    self.assertIn("<unresolved-python-import:", " ".join(right.shape))
                    block = {"steps": [{"run": f"uv run python {path}"}]}
                    jobs = [
                        job_unit("org/left", block, files=baseline),
                        job_unit("org/right", block, files=files),
                    ]
                    self.assertEqual(model.clusters(jobs, [], 0.8), [])

    def test_python_stdlib_imports(self) -> None:
        """Known stdlib controls match; possible local shadows stay unknown."""
        path = "scripts/check.py"
        for source in (
            'from pathlib import Path\nif Path("out/x").exists():\n print("ok")\n',
            'import json,sys as rt\nif rt.argv:\n print(json.dumps("ok"))\n',
            "from json.tool import main as run\nif True:\n    run()\n",
            'from __future__ import annotations\nif True:\n    print("ok")\n',
            'from decimal import Decimal\nif Decimal("1.5") > 0:\n    print("ok")\n',
            'import json\nif True: print(json.dumps("runpy run_path run_module"))\n',
        ):
            with self.subTest(source=source):
                left = model.file_units("org/left", False, path, source, {}, "")[0]
                same = model.file_units("org/right", False, path, source, {}, "")[0]
                self.assertEqual(left.fingerprint, same.fingerprint)
                self.assertEqual(len(model.clusters([left, same], [], 0.8)), 1)
                jobs = [
                    job_unit(
                        repo,
                        {"steps": [{"run": f"python {path}"}]},
                        files={path: source},
                    )
                    for repo in ("org/left", "org/right")
                ]
                self.assertEqual(jobs[0].fingerprint, jobs[1].fingerprint)
                self.assertEqual(len(model.clusters(jobs, [], 0.8)), 1)
                changed = model.file_units(
                    "org/right", False, path, source.replace("if ", "if not "), {}, ""
                )[0]
                self.assertEqual(model.clusters([left, changed], [], 0.8), [])
        source = 'from pathlib import Path\nprint(Path("build/output"))\n'
        for shadow in ("scripts/pathlib.py", "scripts/pathlib/__init__.py"):
            files = {path: source, shadow: "def Path(value):\n    return value\n"}
            left = model.file_units("org/left", False, path, source, files, "")[0]
            right = model.file_units("org/right", False, path, source, files, "")[0]
            with self.subTest(shadow=shadow):
                self.assertEqual(model.clusters([left, right], [], 0.8), [])


if __name__ == "__main__":
    unittest.main()
