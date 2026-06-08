#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate a GitHub Actions matrix for per-language CodeQL build modes.

set -euo pipefail

: "${LANGUAGES:=}"
: "${BUILD_MODE:=none}"
: "${LANGUAGE_BUILD_MODES:=}"

python3 - <<'PY'
import json
import os
import sys

github_output = os.environ.get("GITHUB_OUTPUT")
if not github_output:
    print("GITHUB_OUTPUT is required", file=sys.stderr)
    sys.exit(1)

raw_languages = os.environ.get("LANGUAGES", "").strip()
default_build_mode = os.environ.get("BUILD_MODE", "none").strip() or "none"
raw_build_modes = os.environ.get("LANGUAGE_BUILD_MODES", "").strip()

per_language_modes: dict[str, str] = {}
if raw_build_modes:
    try:
        parsed = json.loads(raw_build_modes)
    except json.JSONDecodeError as exc:
        print(f"LANGUAGE_BUILD_MODES must be valid JSON: {exc}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(parsed, dict):
        print("LANGUAGE_BUILD_MODES must be a JSON object", file=sys.stderr)
        sys.exit(1)
    for language, mode in parsed.items():
        if not isinstance(language, str) or not language.strip():
            print("LANGUAGE_BUILD_MODES keys must be non-empty strings", file=sys.stderr)
            sys.exit(1)
        if not isinstance(mode, str) or not mode.strip():
            print(
                f"LANGUAGE_BUILD_MODES[{language!r}] must be a non-empty string",
                file=sys.stderr,
            )
            sys.exit(1)
        per_language_modes[language.strip()] = mode.strip()

valid_modes = {"none", "autobuild", "manual"}

def resolve_mode(language: str) -> str:
    mode = per_language_modes.get(language, default_build_mode)
    if mode not in valid_modes:
        print(
            f"Invalid build-mode {mode!r} for language {language!r}; "
            f"expected one of {sorted(valid_modes)}",
            file=sys.stderr,
        )
        sys.exit(1)
    return mode

if raw_languages:
    languages = list(
        dict.fromkeys(
            language.strip()
            for language in raw_languages.split(",")
            if language.strip()
        )
    )
    if not languages:
        print("LANGUAGES must list at least one language when non-empty", file=sys.stderr)
        sys.exit(1)
    matrix = {
        "include": [
            {"language": language, "build-mode": resolve_mode(language)}
            for language in languages
        ]
    }
else:
    if default_build_mode not in valid_modes:
        print(
            f"Invalid BUILD_MODE {default_build_mode!r}; "
            f"expected one of {sorted(valid_modes)}",
            file=sys.stderr,
        )
        sys.exit(1)
    matrix = {"include": [{"language": "", "build-mode": default_build_mode}]}

with open(github_output, "a", encoding="utf-8") as output:
    output.write(f"matrix={json.dumps(matrix, separators=(',', ':'))}\n")

if raw_languages:
    summary = ", ".join(
        f"{entry['language']}:{entry['build-mode']}" for entry in matrix["include"]
    )
else:
    summary = f"auto-detect:{default_build_mode}"
print(f"CodeQL matrix: {summary}")
PY
