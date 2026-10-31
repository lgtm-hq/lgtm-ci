#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Prove Renovate tracks reusable runner-image defaults (#1230).

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

@test "runner-image manager: extracts 26.04 from reusable input defaults" {
	run python3 - "${RENOVATE_JSON}" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as config_file:
    config = json.load(config_file)
manager, = [m for m in config["customManagers"] if m.get("datasourceTemplate") == "github-runners"]
pattern = manager["matchStrings"][0]
pattern = re.sub(r"\(\?<([A-Za-z_][A-Za-z0-9_]*)>", r"(?P<\1>", pattern)
for quote in ('"', "'", ""):
    for newline in ("\n", "\r\n"):
        for comment in ("", " # note"):
            snippet = newline.join([
                "on:", "  workflow_call:", "    inputs:",
                f"      runner-image:{comment}",
                "        description: >-", "          Runner label for every job.",
                "          default: ubuntu-24.04 is just description text.",
                "        required: false", "        type: string",
                f"        default: {quote}ubuntu-26.04{quote} # pinned",
                "      timeout-minutes:", "        default: 10", "",
            ])
            matches = list(re.finditer(pattern, snippet))
            assert [m.group("currentValue") for m in matches] == ["26.04"], snippet

file_patterns = [re.compile(p[1:-1]) for p in manager["managerFilePatterns"]]
for path, expected in [
    (".github/workflows/reusable-quality-lint.yml", True),
    (".github/workflows/reusable-release-recover.yml", True),
    ("scripts/ci/quality/validate-runner-contract.sh", True),
    ("catalog/catalog.yml", True),
    ("docs/catalog.md", True),
    (".github/workflows/ci.yml", False),
    ("scripts/ci/actions/docker/classify.sh", False),
    ("examples/reusable-example.yml", False),
    ("tests/fixtures/.github/workflows/reusable-example.yml", False),
]:
    assert any(p.search(path) for p in file_patterns) == expected, path
PY
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

@test "runner-image manager: tracks every repository reusable input default" {
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
contract = (root / "scripts/ci/quality/validate-runner-contract.sh").read_text(encoding="utf-8")
standard_runner, = re.findall(r'^STANDARD_RUNNER = "(ubuntu-[0-9]+\.[0-9]+)"$', contract, re.M)
tracked = 0
for path in sorted((root / ".github/workflows").glob("reusable-*.yml")):
    content = path.read_text(encoding="utf-8")
    doc = yaml.safe_load(content)
    inputs = doc.get(True, doc.get("on"))["workflow_call"].get("inputs", {})
    if "runner-image" not in inputs:
        continue
    default = inputs["runner-image"]["default"]
    assert default == standard_runner, (path, default, standard_runner)
    matches = list(re.finditer(pattern, content))
    assert [m.group("currentValue") for m in matches] == [default.removeprefix("ubuntu-")], path
    tracked += 1
assert tracked > 0
print(f"Tracked {tracked} runner-image defaults")
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
    content = f'\nSTANDARD_RUNNER = {quote}ubuntu-28.04{quote}\n'
    assert [m.group("currentValue") for m in re.finditer(pattern, content)] == ["28.04"]
assert re.search(pattern, 'OTHER_RUNNER = "ubuntu-28.04"') is None
PY
	assert_success
}

@test "runner-image manager: extracts catalog labels while preserving Docker fallback and action evidence" {
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

@test "runner-image manager: extracts rendered catalog labels while preserving Docker fallback and action evidence" {
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

@test "runner-image manager: a future bump satisfies the runner contract and catalog render check" {
	require_python_yaml
	run "${PY}" - "${RENOVATE_JSON}" "${PROJECT_ROOT}" <<'PY'
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[2])
sys.path.insert(0, str(root / "scripts/ci/catalog"))
import catalog_lib

with open(sys.argv[1], encoding="utf-8") as config_file:
    config = json.load(config_file)
manager, = [m for m in config["customManagers"] if m.get("datasourceTemplate") == "github-runners"]
patterns = [re.compile(re.sub(r"\(\?<([A-Za-z_][A-Za-z0-9_]*)>", r"(?P<\1>", p))
            for p in manager["matchStrings"]]
file_patterns = [re.compile(p[1:-1]) for p in manager["managerFilePatterns"]]
contract_path = Path("scripts/ci/quality/validate-runner-contract.sh")
contract = (root / contract_path).read_text(encoding="utf-8")
current, = [m.group("currentValue") for m in patterns[1].finditer(contract)]
major, minor = current.split(".")
future = f"{int(major) + 2}.{minor}"

with tempfile.TemporaryDirectory() as directory:
    fixture = Path(directory)
    for rel in (".github/workflows", ".github/actions", "catalog"):
        shutil.copytree(root / rel, fixture / rel)
    for rel in (contract_path, Path("docs/catalog.md"), Path("README.md")):
        (fixture / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / rel, fixture / rel)

    tracked = {}
    for path in sorted(fixture.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(fixture).as_posix()
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

    assert tracked[contract_path.as_posix()] == 1
    assert tracked["catalog/catalog.yml"] == tracked["docs/catalog.md"] > 0
    catalog = catalog_lib.load_catalog(path=fixture / "catalog/catalog.yml")
    for entry in catalog["entries"]:
        if entry["kind"] != "reusable-workflow":
            continue
        facts = catalog_lib.workflow_facts(
            workflows_dir=fixture / ".github/workflows", name=f'{entry["id"]}.yml',
        )
        assert set(facts.runners) <= set(entry["runners"]), (entry["id"], facts.runners)
    subprocess.run(["bash", str(fixture / contract_path)], check=True)
    subprocess.run([sys.executable, str(root / "scripts/ci/catalog/render.py"),
                    "--check", "--repo-root", str(fixture)], check=True)
    print(f"Simulated runner bump {current} -> {future}: {sum(tracked.values())} custom matches")
PY
	assert_success
}
