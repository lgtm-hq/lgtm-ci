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

@test "runner-image manager: extracts 26.04 from reusable input defaults" {
	run python3 - "${RENOVATE_JSON}" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as config_file:
    config = json.load(config_file)
manager, = [m for m in config["customManagers"] if m.get("datasourceTemplate") == "github-runners"]
pattern, = manager["matchStrings"]
pattern = re.sub(r"\(\?<([A-Za-z_][A-Za-z0-9_]*)>", r"(?P<\1>", pattern)
for quote in ('"', "'", ""):
    for newline in ("\n", "\r\n"):
        snippet = newline.join([
            "on:", "  workflow_call:", "    inputs:",
            "      runner-image:",
            "        description: >-", "          Runner label for every job.",
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
    (".github/workflows/ci.yml", False),
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
pattern, = manager["matchStrings"]
pattern = re.sub(r"\(\?<([A-Za-z_][A-Za-z0-9_]*)>", r"(?P<\1>", pattern)
for snippet in [
    '      other-image:\n        default: "ubuntu-26.04"\n',
    '      runner-image:\n        type: string\n'
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
pattern, = manager["matchStrings"]
pattern = re.sub(r"\(\?<([A-Za-z_][A-Za-z0-9_]*)>", r"(?P<\1>", pattern)
tracked = 0
for path in sorted((Path(sys.argv[2]) / ".github/workflows").glob("reusable-*.yml")):
    content = path.read_text(encoding="utf-8")
    inputs = yaml.safe_load(content)[True]["workflow_call"].get("inputs", {})
    if "runner-image" not in inputs:
        continue
    default = inputs["runner-image"]["default"]
    assert default == "ubuntu-26.04", (path, default)
    matches = list(re.finditer(pattern, content))
    assert [m.group("currentValue") for m in matches] == [default.removeprefix("ubuntu-")], path
    tracked += 1
assert tracked > 0
print(f"Tracked {tracked} runner-image defaults")
PY
	assert_success
}
