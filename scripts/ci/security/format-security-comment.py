#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Format lintro osv_scanner JSON output as a security PR comment.

Reads lintro JSON output (from --output-format json) and extracts the
osv_scanner result to produce a markdown PR comment body with a
vulnerability table and suppression status table.

Usage:
    python3 scripts/ci/security/format-security-comment.py osv-results.json

Exit codes:
    0 - Success (markdown printed to stdout)
    1 - Invalid arguments or missing file
"""

from __future__ import annotations

import json
import sys
from datetime import date
from pathlib import Path


def _escape_md_cell(value: str) -> str:
    """Escape a string for safe use inside a Markdown table cell."""
    escaped = value.replace("|", "\\|").replace("`", "\\`")
    return escaped.replace("\n", " ").replace("\r", "")


def _read_suppressions_from_toml() -> list[dict[str, object]]:
    """Read suppression entries from .osv-scanner.toml as a fallback."""
    try:
        import tomllib
    except ImportError:
        return []

    toml_path = Path(".osv-scanner.toml")
    if not toml_path.exists():
        return []
    try:
        with toml_path.open("rb") as f:
            data = tomllib.load(f)

        def _valid_ignore_until(entry: dict[str, object]) -> bool:
            ignore_until = entry.get("ignoreUntil")
            return ignore_until is None or isinstance(ignore_until, date)

        return [
            entry
            for entry in data.get("IgnoredVulns", [])
            if isinstance(entry, dict)
            and isinstance(entry.get("id"), str)
            and entry["id"].strip()
            and _valid_ignore_until(entry)
        ]
    except (tomllib.TOMLDecodeError, OSError) as e:
        print(f"Warning: failed to parse {toml_path}: {e}", file=sys.stderr)
        return []


def _fence_code_block(text: str) -> str:
    """Wrap text in a Markdown code fence safe against embedded backticks."""
    fence = "```"
    while fence in text:
        fence += "`"
    return f"{fence}\n{text}\n{fence}"


def format_comment(json_path: str) -> str | None:
    """Format osv-scanner JSON results as markdown."""
    path = Path(json_path)
    if not path.exists():
        print(
            "No osv-results.json found — osv-scanner may not have run.",
            file=sys.stderr,
        )
        return None

    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        print(f"Failed to read {path}: {e}", file=sys.stderr)
        return None

    try:
        data = json.loads(content)
    except json.JSONDecodeError as e:
        print(f"Failed to parse JSON from {path}: {e}", file=sys.stderr)
        return None

    if not isinstance(data, dict):
        print(
            "Invalid JSON structure: top-level value is not an object",
            file=sys.stderr,
        )
        return None

    results = data.get("results", [])
    if not isinstance(results, list):
        print("Invalid JSON structure: 'results' is not a list", file=sys.stderr)
        return None

    osv_result = None
    for result in results:
        if isinstance(result, dict) and result.get("tool") == "osv_scanner":
            osv_result = result
            break

    if osv_result is None:
        print("osv-scanner did not produce results.", file=sys.stderr)
        return None

    ai_meta = osv_result.get("ai_metadata")
    probe_suppressions: list[dict[str, object]] | None = None
    if isinstance(ai_meta, dict) and isinstance(
        ai_meta.get("suppressions"),
        list,
    ):
        probe_suppressions = ai_meta["suppressions"]

    sections: list[str] = []

    sections.append("### 🔍 Checks Performed:")
    sections.append(
        "- **osv-scanner**: Scanned all lockfiles against the OSV database",
    )
    sections.append("")

    issues_count = osv_result.get("issues_count", 0)
    if issues_count > 0:
        issues_list = osv_result.get("issues", [])
        sections.append("### 🚨 Vulnerability Report:")
        sections.append("| Vulnerability | File |")
        sections.append("|---------------|------|")
        if issues_list:
            for issue in issues_list:
                if not isinstance(issue, dict):
                    continue
                msg = _escape_md_cell(str(issue.get("message") or "?"))
                file = _escape_md_cell(str(issue.get("file") or "?"))
                sections.append(f"| {msg} | `{file}` |")
        else:
            sections.append(
                f"| {issues_count} vulnerabilities found (details unavailable) | — |",
            )
        sections.append("")
        sections.append("### 🔧 Recommended Actions:")
        sections.append("1. Review the vulnerabilities above")
        sections.append("2. Update affected packages if fixes are available")
        sections.append("3. Suppress in .osv-scanner.toml when no fix exists")
    elif osv_result.get("success") is False:
        output_text = osv_result.get("output", "")
        sections.append("### ⚠️ Scanner Error:")
        sections.append("osv-scanner failed. Review the CI logs for details.")
        if output_text:
            preview = output_text[:500]
            sections.append("")
            sections.append(_fence_code_block(preview))
    else:
        sections.append("No security vulnerabilities found in dependencies.")

    sections.append("")
    sections.append("### 🔇 Suppressed Vulnerabilities:")
    if probe_suppressions is not None:
        if not probe_suppressions:
            sections.append("No suppressions configured.")
        else:
            sections.append("| ID | Expires | Status | Reason |")
            sections.append("|----|---------|--------|--------|")
            for suppression in probe_suppressions:
                if not isinstance(suppression, dict):
                    continue
                sid = _escape_md_cell(str(suppression.get("id", "?")))
                expires = _escape_md_cell(str(suppression.get("ignore_until", "?")))
                status = str(suppression.get("status", "active"))
                reason = _escape_md_cell(str(suppression.get("reason", "")))
                if status == "expired":
                    sections.append(
                        f"| :warning: `{sid}` | **EXPIRED** {expires} "
                        f"| :warning: Expired | {reason} |",
                    )
                elif status == "stale":
                    sections.append(
                        f"| `{sid}` | {expires} "
                        f"| :warning: **Stale — safe to remove** | {reason} |",
                    )
                else:
                    sections.append(
                        f"| `{sid}` | {expires} | Active | {reason} |",
                    )
    else:
        toml_suppressions = _read_suppressions_from_toml()
        if toml_suppressions:
            sections.append("| ID | Expires | Reason |")
            sections.append("|----|---------|--------|")
            for suppression in toml_suppressions:
                sid = _escape_md_cell(str(suppression.get("id", "?")))
                expires = _escape_md_cell(str(suppression.get("ignoreUntil", "?")))
                reason = _escape_md_cell(str(suppression.get("reason", "")))
                sections.append(f"| `{sid}` | {expires} | {reason} |")
        else:
            sections.append("No suppressions configured.")

    return "\n".join(sections)


def main() -> None:
    """Entry point."""
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <json_file>", file=sys.stderr)
        sys.exit(1)

    output = format_comment(sys.argv[1])
    if output is not None:
        print(output)
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
