# SPDX-License-Identifier: MIT
"""Conservative Python source regressions driven by the scanner BATS suite."""

from __future__ import annotations

import unittest

from duplication_scan_regression_checks import job_unit
from duplication_scan_support import FixtureCase, model


class Cases(FixtureCase):
    """Keep unknown imports isolated and executable constants significant."""

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
        """Path/version strings and safe workflow inputs still mask parameters."""
        path = "scripts/check.py"
        source = (
            'from pathlib import Path\nversion = "3.11"\n'
            'output = Path("build/output")\nassert coverage >= 0.8\n'
        )
        changed = source.replace('"3.11"', '"3.12"')
        changed = changed.replace("build/output", "dist/result")
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
        ):
            with self.subTest(source=source):
                left = model.file_units("org/left", False, path, source, {}, "")[0]
                same = model.file_units("org/right", False, path, source, {}, "")[0]
                self.assertEqual(left.fingerprint, same.fingerprint)
                self.assertEqual(len(model.clusters([left, same], [], 0.8)), 1)
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
