#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Prove Renovate tracks runner selection fallbacks (#1230, #1231).

load "../../../helpers/common"

RENOVATE_JSON="${PROJECT_ROOT}/renovate.json"

@test "runner-image manager: shares the built-in Ubuntu runner dependency" {
	run jq -e '
		[.customManagers[] | select(.datasourceTemplate == "github-runners")] |
		length == 1 and all(.[];
			.customType == "regex" and .depNameTemplate == "ubuntu" and
			(.description | length > 0))
	' "${RENOVATE_JSON}"
	assert_success
}

@test "runner-image manager: groups every runner update type on one branch" {
	run jq -e '
		any(.packageRules[];
			.matchDatasources == ["github-runners"] and
			.groupName == "github runner images" and
			.groupSlug == "github-runner-images" and
			(has("matchUpdateTypes") | not))
	' "${RENOVATE_JSON}"
	assert_success
}

@test "runner-image manager: JavaScript regex extracts only the fallback version" {
	command -v node >/dev/null 2>&1 || skip "node is required for the JavaScript regex check"
	run node - "${RENOVATE_JSON}" <<'JS'
const fs = require('node:fs')
const assert = require('node:assert/strict')
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const managers = config.customManagers.filter(m => m.datasourceTemplate === 'github-runners')
assert.equal(managers.length, 1)
const manager = managers[0]
const pattern = new RegExp(manager.matchStrings[0], 'g')
for (const prefix of ["vars.LGTM_CI_RUNNER", "inputs.runner-image || vars.LGTM_CI_RUNNER", "matrix.runner || inputs.runner-image || vars.LGTM_CI_RUNNER"]) {
  const text = "    runs-on: ${{ " + prefix + " || 'ubuntu-26.04' }}\r\n"
  const matches = [...text.matchAll(pattern)]
  assert.deepEqual(matches.map(m => m.groups.currentValue), ['26.04'])
  assert.equal(text.replace(pattern, m => m.replace('26.04', '28.04')),
    text.replace("'ubuntu-26.04'", "'ubuntu-28.04'"))
}
for (const text of ["runs-on: ubuntu-26.04", "default: \"ubuntu-26.04\"",
  "${{ inputs.runner-image }}", "${{ inputs.runner-image || vars.LGTM_CI_RUNNER || 'ubuntu-26.04-arm' }}"]) {
  assert.equal([...text.matchAll(pattern)].length, 0, text)
}
const filePatterns = manager.managerFilePatterns.map(p => new RegExp(p.slice(1, -1)))
for (const [path, expected] of [
  ['.github/workflows/reusable-quality-lint.yml', true],
  ['scripts/ci/lib/standard-runner.sh', true],
  ['scripts/ci/quality/validate-runner-contract.sh', false],
  ['catalog/catalog.yml', true], ['docs/catalog.md', true],
  ['docs/workflow-contract.md', true],
  ['.github/workflows/ci.yml', false],
  ['scripts/ci/actions/docker/classify.sh', false],
  ['examples/reusable-example.yml', false],
  ['tests/fixtures/.github/workflows/reusable-example.yml', false],
]) assert.equal(filePatterns.some(p => p.test(path)), expected, path)
JS
	assert_success
}

@test "runner-image manager: ignores neighboring defaults and caller with values" {
	run python3 - "${RENOVATE_JSON}" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as config_file:
    config = json.load(config_file)
manager, = [m for m in config["customManagers"] if m.get("datasourceTemplate") == "github-runners"]
pattern = manager["matchStrings"][0]
pattern = re.sub(r"\(\?<([A-Za-z_][A-Za-z0-9_]*)>", r"(?P<\1>", pattern)
for snippet in [
    '      other-image:\n        default: "ubuntu-26.04"\n',
    '      runner-image:\n        type: string\n'
    '      other-image:\n        default: "ubuntu-26.04"\n',
    '      runner-image: # no default here\n        description: |\n'
    '          default: ubuntu-26.04\n'
    '      other-image:\n        default: "ubuntu-26.04"\n',
    '      runner-image:\n        default: ""\n'
    '      other-image:\n        default: "ubuntu-26.04"\n',
    '    with:\n      runner-image: ubuntu-26.04\n',
    '    runs-on: ubuntu-26.04\n',
    '      runner-image:\n        default: "ubuntu-26.04-arm"\n',
]:
    assert re.search(pattern, snippet) is None, snippet
PY
	assert_success
}

@test "runner-image manager: tracks every repository reusable runner fallback" {
	require_python_yaml
	run "${PY}" - "${RENOVATE_JSON}" "${PROJECT_ROOT}" <<'PY'
import json
import re
import sys
from pathlib import Path

import yaml

with open(sys.argv[1], encoding="utf-8") as config_file:
    config = json.load(config_file)
manager, = [m for m in config["customManagers"] if m.get("datasourceTemplate") == "github-runners"]
pattern = manager["matchStrings"][0]
pattern = re.sub(r"\(\?<([A-Za-z_][A-Za-z0-9_]*)>", r"(?P<\1>", pattern)
root = Path(sys.argv[2])
contract = (root / "scripts/ci/lib/standard-runner.sh").read_text(encoding="utf-8")
standard_runner, = re.findall(r'^STANDARD_RUNNER="(ubuntu-[0-9]+\.[0-9]+)"$', contract, re.M)
tracked = 0
for path in sorted((root / ".github/workflows").glob("reusable-*.yml")):
    content = path.read_text(encoding="utf-8")
    doc = yaml.safe_load(content)
    inputs = doc.get(True, doc.get("on"))["workflow_call"].get("inputs", {})
    if "runner-image" not in inputs:
        continue
    default = inputs["runner-image"]["default"]
    assert default == "", (path, default)
    matches = list(re.finditer(pattern, content))
    expected = content.count("|| vars.LGTM_CI_RUNNER || '")
    assert [m.group("currentValue") for m in matches] == [standard_runner.removeprefix("ubuntu-")] * expected, path
    tracked += expected
assert tracked > 0
consumer_contract = (root / "docs/workflow-contract.md").read_text(encoding="utf-8")
assert [m.group("currentValue") for m in re.finditer(pattern, consumer_contract)] == [standard_runner.removeprefix("ubuntu-")]
print(f"Tracked {tracked} runner fallbacks and the consumer snippet")
PY
	assert_success
}

@test "runner-image manager: covers control-plane fallbacks and resolved catalog labels" {
	require_python_yaml
	run "${PY}" - "${RENOVATE_JSON}" "${PROJECT_ROOT}" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[2])
config = json.loads(Path(sys.argv[1]).read_text())
manager, = [m for m in config["customManagers"] if m.get("datasourceTemplate") == "github-runners"]
patterns = [re.compile(re.sub(r"\(\?<([A-Za-z_][A-Za-z0-9_]*)>", r"(?P<\1>", p))
            for p in manager["matchStrings"]]
file_patterns = [re.compile(p[1:-1]) for p in manager["managerFilePatterns"]]
contract = (root / "scripts/ci/lib/standard-runner.sh").read_text()
version, = [m.group("currentValue") for m in patterns[1].finditer(contract)]
for name in ("semantic-pr-title", "pr-labeler", "dependency-review"):
    workflow = f"reusable-{name}"
    for relative, pattern, section in (
        (f".github/workflows/{workflow}.yml", patterns[0], None),
        ("catalog/catalog.yml", patterns[2], rf"  - id: {workflow}\n.*?(?=\n  - id:|\Z)"),
        ("docs/catalog.md", patterns[3], rf"#### `{workflow}`\n.*?(?=\n#### |\Z)"),
    ):
        assert any(p.search(relative) for p in file_patterns), relative
        content = (root / relative).read_text()
        if section:
            content = re.search(section, content, re.S)[0]
        assert [m.group("currentValue") for m in pattern.finditer(content)] == [version], (workflow, relative)
print("Tracked all three control-plane fallbacks and both catalog representations")
PY
	assert_success
}

@test "runner-image manager: extracts the contract standard in every quote style" {
	run python3 - "${RENOVATE_JSON}" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as config_file:
    config = json.load(config_file)
manager, = [m for m in config["customManagers"] if m.get("datasourceTemplate") == "github-runners"]
pattern = re.sub(r"\(\?<([A-Za-z_][A-Za-z0-9_]*)>", r"(?P<\1>", manager["matchStrings"][1])
for quote in ('"', "'"):
    content = f'\nSTANDARD_RUNNER={quote}ubuntu-28.04{quote}\n'
    assert [m.group("currentValue") for m in re.finditer(pattern, content)] == ["28.04"]
for content in ('OTHER_RUNNER="ubuntu-28.04"', 'STANDARD_RUNNER="ubuntu-28.04-arm"'):
    assert re.search(pattern, content) is None
PY
	assert_success
}

@test "runner-image manager: extracts catalog labels while preserving explicit runners and action evidence" {
	run python3 - "${RENOVATE_JSON}" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as config_file:
    config = json.load(config_file)
manager, = [m for m in config["customManagers"] if m.get("datasourceTemplate") == "github-runners"]
pattern = re.sub(r"\(\?<([A-Za-z_][A-Za-z0-9_]*)>", r"(?P<\1>", manager["matchStrings"][2])
for newline in ("\n", "\r\n"):
    content = newline.join([
        "entries:", "  - id: reusable-demo", "    kind: reusable-workflow",
        "    runners: [ubuntu-28.04]",
        "  - id: reusable-docker", "    kind: reusable-workflow",
        "    runners: [ubuntu-24.04, ubuntu-28.04]",
        "  - id: reusable-action-only", "    runners: [ubuntu-latest]",
        "  - id: run-pytest", "    kind: composite-action",
        "    runners: [ubuntu-24.04]", "",
    ])
    matches = list(re.finditer(pattern, content))
    assert [m.group("currentValue") for m in matches] == ["28.04", "28.04"]
    updated = re.sub(pattern, lambda m: m.group().replace(m.group("currentValue"), "30.04"), content)
    assert "runners: [ubuntu-24.04, ubuntu-30.04]" in updated
    assert "runners: [ubuntu-24.04]" in updated
PY
	assert_success
}

@test "runner-image manager: extracts rendered catalog labels while preserving explicit runners and action evidence" {
	run python3 - "${RENOVATE_JSON}" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as config_file:
    config = json.load(config_file)
manager, = [m for m in config["customManagers"] if m.get("datasourceTemplate") == "github-runners"]
pattern = re.sub(r"\(\?<([A-Za-z_][A-Za-z0-9_]*)>", r"(?P<\1>", manager["matchStrings"][3])
for newline in ("\n", "\r\n"):
    content = newline.join([
        "#### `reusable-demo`", "", "A demo workflow", "",
        "- **Runners:** `ubuntu-28.04`", "",
        "#### `reusable-docker`", "", "A Docker workflow", "",
        "- **Runners:** `ubuntu-24.04`, `ubuntu-28.04`", "",
        "#### `reusable-action-only`", "", "- **Runners:** `ubuntu-latest`", "",
        "#### `run-pytest`", "", "- **Runners:** `ubuntu-24.04`", "",
    ])
    matches = list(re.finditer(pattern, content))
    assert [m.group("currentValue") for m in matches] == ["28.04", "28.04"]
    updated = re.sub(pattern, lambda m: m.group().replace(m.group("currentValue"), "30.04"), content)
    assert "- **Runners:** `ubuntu-24.04`, `ubuntu-30.04`" in updated
    assert "- **Runners:** `ubuntu-24.04`" in updated
PY
	assert_success
}

@test "runner-image manager: nested BATS preserves tracing and failure propagation" {
	run python3 "${PROJECT_ROOT}/tests/python/test_bats_subprocess.py"
	assert_success
}

@test "runner-image manager: a future bump satisfies the contract, catalog and workflow tests" {
	require_python_yaml
	run "${PY}" - "${RENOVATE_JSON}" "${PROJECT_ROOT}" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[2])
sys.path.insert(0, str(root / "scripts/ci/catalog"))
import catalog_lib
sys.path.insert(0, str(root / "tests/helpers"))
from bats_subprocess import run_bats

with open(sys.argv[1], encoding="utf-8") as config_file:
    config = json.load(config_file)
manager, = [m for m in config["customManagers"] if m.get("datasourceTemplate") == "github-runners"]
patterns = [re.compile(re.sub(r"\(\?<([A-Za-z_][A-Za-z0-9_]*)>", r"(?P<\1>", p))
            for p in manager["matchStrings"]]
file_patterns = [re.compile(p[1:-1]) for p in manager["managerFilePatterns"]]
contract_path = Path("scripts/ci/quality/validate-runner-contract.sh")
standard_path = Path("scripts/ci/lib/standard-runner.sh")
contract = (root / standard_path).read_text(encoding="utf-8")
current, = [m.group("currentValue") for m in patterns[1].finditer(contract)]
major, minor = current.split(".")
future = f"{int(major) + 2}.{minor}"

with tempfile.TemporaryDirectory() as directory:
    fixture = Path(directory)
    for rel in (".github/workflows", ".github/actions", "catalog", "scripts/ci"):
        shutil.copytree(root / rel, fixture / rel,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    for rel in (Path("docs/catalog.md"), Path("docs/workflow-contract.md"), Path("README.md")):
        (fixture / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / rel, fixture / rel)

    tracked = {}
    for path in sorted(fixture.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(fixture).as_posix()
        if not (any(p.search(rel) for p in file_patterns) or rel.startswith(".github/workflows/")):
            continue
        content = path.read_text(encoding="utf-8")
        if any(p.search(rel) for p in file_patterns):
            count = sum(len(list(p.finditer(content))) for p in patterns)
            if count:
                tracked[rel] = count
            for pattern in patterns:
                content = pattern.sub(lambda m: m.group().replace(m.group("currentValue"), future), content)
        # Model the built-in github-actions manager's literal runs-on update.
        if rel.startswith(".github/workflows/"):
            content = re.sub(r"(runs-on: [\"']?ubuntu-)" + re.escape(current) + r"(?=[\"'\s]|$)",
                             lambda m: m.group(1) + future, content)
        path.write_text(content, encoding="utf-8")

    assert tracked[standard_path.as_posix()] == 1
    assert tracked["docs/workflow-contract.md"] == 1
    consumer_contract = (fixture / "docs/workflow-contract.md").read_text()
    assert "${{ vars.LGTM_CI_RUNNER || 'ubuntu-" + future + "' }}" in consumer_contract
    assert tracked["catalog/catalog.yml"] == tracked["docs/catalog.md"] > 0
    catalog = catalog_lib.load_catalog(path=fixture / "catalog/catalog.yml")
    for entry in catalog["entries"]:
        if entry["kind"] != "reusable-workflow":
            continue
        facts = catalog_lib.workflow_facts(
            workflows_dir=fixture / ".github/workflows", name=f'{entry["id"]}.yml',
        )
        assert set(facts.runners) <= set(entry["runners"]), (entry["id"], facts.runners)
    environment = {
        **os.environ, "PROJECT_ROOT": str(fixture), "PYTHON": sys.executable,
        "PATH": str(Path(sys.executable).parent) + os.pathsep + os.environ["PATH"],
    }
    subprocess.run(["bash", str(fixture / contract_path)], check=True, env=environment)
    subprocess.run([sys.executable, str(root / "scripts/ci/catalog/render.py"),
                    "--check", "--repo-root", str(fixture)], check=True)

    # Tests are deliberately not Renovate targets: their expectations must
    # follow the contract without editing the copied test source.
    shutil.copytree(root / "tests/helpers", fixture / "tests/helpers")
    suite_paths = (
        "tests/bats/unit/actions/docker/test_classify.bats",
        "tests/bats/integration/test_reusable_docker_workflow.bats",
        "tests/bats/integration/test_reusable_docker_build_workflow.bats",
        "tests/bats/integration/test_reusable_docker_multiplatform_workflow.bats",
        "tests/bats/integration/test_reusable_docker_smoke_test_workflow.bats",
        "tests/bats/integration/test_reusable_runner_contract.bats",
    )
    suites = []
    for name in suite_paths:
        relative = Path(name)
        target = fixture / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / relative, target)
        suites.append(str(target))
    run_bats(
        ["--filter", "runner|unmapped platforms use|single.*platform|disables split|enables split", *suites],
        environment,
    )
    print(f"Simulated runner bump {current} -> {future}: {sum(tracked.values())} custom matches")
PY
	assert_success
}
