#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Format lintro osv_scanner JSON output as a security PR comment.

Reads lintro JSON output (from --output-format json) and extracts the
osv_scanner result to produce a markdown PR comment body with a
vulnerability table and suppression status table.

Suppression status comes from the per-tool ``metadata.suppressions`` list that
lintro's osv-scanner plugin attaches after its probe scan (``id``,
``ignore_until``, ``reason``, ``status``). lintro omits the ``metadata`` key
entirely when the probe did not run, which is the normal case for a repository
without probe-eligible ``.osv-scanner.toml`` entries (every entry needs a
string ``id`` and a date ``ignoreUntil``). When the key is missing but the TOML
declares probe-eligible entries, the probe was skipped, disabled, or timed out,
and this script fails instead of presenting static TOML entries as status.

Compatibility shim: py-lintro < 0.95.0 emitted the same payload under
``ai_metadata`` (dual-emitted with ``metadata`` from 0.94.x; removed in 0.95.0
by lgtm-hq/py-lintro#1831 / #1863). The legacy key is still read, with a
deprecation warning on stderr. Remove the shim once no supported caller pins a
``lintro-image`` older than 0.95.0; ``LEGACY_PROBE_METADATA_KEY`` is the only
place that needs to go (lgtm-hq/lgtm-ci#825).

Usage:
    python3 scripts/ci/security/format-security-comment.py osv-results.json

Exit codes:
    0 - Success (markdown printed to stdout)
    1 - Invalid arguments, missing file, or suppression status unavailable
"""

# pylint: disable=invalid-name  # CLI script; hyphenated filename is the invocation contract

from __future__ import annotations

import json
import sys
from datetime import date, datetime
from pathlib import Path
from typing import Any

try:
    import tomllib
except ImportError:  # stdlib on Python >= 3.11; fallback omits TOML suppressions
    tomllib = None  # type: ignore[assignment]

#: Per-tool key lintro >= 0.94 attaches probe classifications under.
PROBE_METADATA_KEY = "metadata"
#: Pre-0.95.0 alias of ``PROBE_METADATA_KEY``; see the module docstring.
LEGACY_PROBE_METADATA_KEY = "ai_metadata"
#: List key inside the probe metadata object.
SUPPRESSIONS_KEY = "suppressions"
#: ``status`` values lintro's ``SuppressionStatus`` serializes to.
PROBE_STATUSES = frozenset({"active", "stale", "expired"})


def _escape_md_cell(value: str) -> str:
    """Escape a string for safe use inside a Markdown table cell."""
    escaped = value.replace("|", "\\|").replace("`", "\\`")
    return escaped.replace("\n", " ").replace("\r", "")


def _read_suppressions_from_toml() -> list[dict[str, object]]:
    """Read suppression entries from .osv-scanner.toml.

    Returns:
        Entries with a non-empty string ``id`` (as lintro's
        ``parse_suppressions`` accepts them) whose ``ignoreUntil`` is either
        absent or a date. Returns an empty list when the file is missing,
        unreadable, or ``tomllib`` is unavailable.
    """
    if tomllib is None:
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
            and entry["id"]
            and _valid_ignore_until(entry)
        ]
    except (tomllib.TOMLDecodeError, OSError) as e:
        print(f"Warning: failed to parse {toml_path}: {e}", file=sys.stderr)
        return []


def _is_probe_eligible(entry: dict[str, object]) -> bool:
    """Return whether lintro's probe classifies a TOML entry.

    Mirrors lintro's ``parse_suppressions``: an entry takes part in the probe
    only when its ``ignoreUntil`` is a plain date. Entries without one, or
    with a TOML datetime (a ``date`` subclass lintro rejects), never produce
    probe metadata.

    Args:
        entry: An entry returned by :func:`_read_suppressions_from_toml`.

    Returns:
        ``True`` when ``ignoreUntil`` is a date and not a datetime.
    """
    ignore_until = entry.get("ignoreUntil")
    return isinstance(ignore_until, date) and not isinstance(ignore_until, datetime)


def _probe_entry_error(entries: list[Any]) -> str | None:
    """Validate classified suppression entries against lintro's shape.

    lintro emits ``{"id": str, "ignore_until": str, "reason": str,
    "status": "active" | "stale" | "expired"}`` per entry; anything else is
    not probe output and must not be rendered as status.

    Args:
        entries: The ``suppressions`` list from the probe metadata.

    Returns:
        A diagnostic describing the first malformed entry, or ``None`` when
        every entry is well-formed.
    """
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            return f"entry {index} is not an object: {entry!r}"
        sid = entry.get("id")
        if not isinstance(sid, str) or not sid.strip():
            return f"entry {index} has no string 'id': {entry!r}"
        status = entry.get("status")
        if status not in PROBE_STATUSES:
            return (
                f"entry {index} ({sid}) has status {status!r}; expected one of "
                f"{sorted(PROBE_STATUSES)}"
            )
    return None


def _fence_code_block(text: str) -> str:
    """Wrap text in a Markdown code fence safe against embedded backticks."""
    fence = "```"
    while fence in text:
        fence += "`"
    return f"{fence}\n{text}\n{fence}"


def _load_lintro_results(json_path: str) -> list[Any] | None:
    """Read a lintro JSON report and return its ``results`` array.

    Args:
        json_path: Path to the lintro JSON output file.

    Returns:
        The ``results`` array, or ``None`` when the report is missing,
        unreadable, or malformed. A diagnostic is printed to stderr for
        every ``None`` case.
    """
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
    return results


def _osv_scanner_result(results: list[Any]) -> dict[str, Any] | None:
    """Return the osv_scanner entry from a lintro ``results`` array.

    Args:
        results: The ``results`` array from a lintro report.

    Returns:
        The first result whose ``tool`` is ``osv_scanner``, or ``None``
        when there is none.
    """
    for result in results:
        if isinstance(result, dict) and result.get("tool") == "osv_scanner":
            return result
    return None


def _suppressions_under(
    osv_result: dict[str, Any],
    key: str,
) -> list[dict[str, Any]] | None:
    """Return ``<key>.suppressions`` from a result when it is a list.

    Args:
        osv_result: The ``osv_scanner`` result object.
        key: Top-level result key holding the probe metadata object.

    Returns:
        The suppression list, or ``None`` when the key is absent, not an
        object, or its ``suppressions`` value is not a list.
    """
    meta = osv_result.get(key)
    if not isinstance(meta, dict):
        return None
    suppressions = meta.get(SUPPRESSIONS_KEY)
    return suppressions if isinstance(suppressions, list) else None


def _probe_suppressions(osv_result: dict[str, Any]) -> list[dict[str, Any]] | None:
    """Extract classified suppressions from a result's probe metadata.

    Reads ``metadata.suppressions`` first. Falls back to the legacy
    ``ai_metadata.suppressions`` key (py-lintro < 0.95.0) with a deprecation
    warning on stderr; see the module docstring for the removal note.

    Args:
        osv_result: The ``osv_scanner`` result object.

    Returns:
        The suppression entry list when either key carries one, else
        ``None`` (the probe produced no classifications).
    """
    suppressions = _suppressions_under(osv_result=osv_result, key=PROBE_METADATA_KEY)
    if suppressions is not None:
        return suppressions
    legacy = _suppressions_under(osv_result=osv_result, key=LEGACY_PROBE_METADATA_KEY)
    if legacy is not None:
        print(
            f"Warning: read suppression status from the legacy "
            f"'{LEGACY_PROBE_METADATA_KEY}' key; py-lintro >= 0.95.0 emits "
            f"'{PROBE_METADATA_KEY}' instead. Bump lintro-image — this "
            "compatibility shim will be removed (lgtm-hq/lgtm-ci#825).",
            file=sys.stderr,
        )
    return legacy


def _add_issue_table(
    sections: list[str],
    osv_result: dict[str, Any],
    issues_count: int,
) -> None:
    """Append the vulnerability table and recommended actions.

    Args:
        sections: Section list to append to.
        osv_result: The ``osv_scanner`` result object.
        issues_count: Number of reported vulnerabilities.
    """
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


def _add_vulnerability_sections(
    sections: list[str],
    osv_result: dict[str, Any],
) -> None:
    """Append the findings, scanner-error, or clean section for a result.

    Args:
        sections: Section list to append to.
        osv_result: The ``osv_scanner`` result object.
    """
    issues_count = osv_result.get("issues_count", 0)
    if issues_count > 0:
        _add_issue_table(sections, osv_result, issues_count)
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


def _add_probe_suppression_table(
    sections: list[str],
    probe_suppressions: list[dict[str, Any]],
) -> None:
    """Append the classified suppression table from probe metadata.

    Args:
        sections: Section list to append to.
        probe_suppressions: Classified suppression entries, already checked
            by :func:`_probe_entry_error`.
    """
    if not probe_suppressions:
        sections.append("No suppressions configured.")
        return
    sections.append("| ID | Expires | Status | Reason |")
    sections.append("|----|---------|--------|--------|")
    for suppression in probe_suppressions:
        sid = _escape_md_cell(str(suppression["id"]))
        expires = _escape_md_cell(str(suppression.get("ignore_until", "?")))
        status = str(suppression["status"])
        reason = _escape_md_cell(str(suppression.get("reason", "")))
        if status == "expired":
            icon = ":warning:"
            state = f"**EXPIRED** {expires}"
            row = f"| {icon} `{sid}` | {state} | {icon} Expired | {reason} |"
        elif status == "stale":
            note = ":warning: **Stale — safe to remove**"
            row = f"| `{sid}` | {expires} | {note} | {reason} |"
        else:
            row = f"| `{sid}` | {expires} | Active | {reason} |"
        sections.append(row)


def _add_toml_suppression_table(
    sections: list[str],
    toml_suppressions: list[dict[str, object]],
) -> None:
    """Append the unclassified suppression table read from .osv-scanner.toml.

    Only reached for entries lintro's probe cannot classify (no ``ignoreUntil``
    date), so the table is labelled as static rather than as probe status.

    Args:
        sections: Section list to append to.
        toml_suppressions: Entries from :func:`_read_suppressions_from_toml`.
    """
    sections.append(
        "_Status unavailable: these entries carry no plain-date `ignoreUntil` "
        "(missing or a datetime), so lintro's probe does not classify them. "
        "Listing `.osv-scanner.toml` as written._",
    )
    sections.append("")
    sections.append("| ID | Expires | Reason |")
    sections.append("|----|---------|--------|")
    for suppression in toml_suppressions:
        sid = _escape_md_cell(str(suppression.get("id", "?")))
        expires = _escape_md_cell(str(suppression.get("ignoreUntil", "?")))
        reason = _escape_md_cell(str(suppression.get("reason", "")))
        sections.append(f"| `{sid}` | {expires} | {reason} |")


def _report_probe_metadata_missing(eligible: list[dict[str, object]]) -> None:
    """Print the diagnostic for a probe that should have run but left no data.

    Args:
        eligible: Probe-eligible TOML entries the result failed to classify.
    """
    ids = ", ".join(str(entry.get("id")) for entry in eligible)
    print(
        "Suppression status unavailable: the osv_scanner result carries "
        f"neither '{PROBE_METADATA_KEY}.{SUPPRESSIONS_KEY}' nor the legacy "
        f"'{LEGACY_PROBE_METADATA_KEY}.{SUPPRESSIONS_KEY}', but "
        f".osv-scanner.toml declares {len(eligible)} probe-eligible "
        f"suppression(s): {ids}. lintro's probe scan was skipped, disabled "
        "(check_suppressions=false), failed, or timed out; refusing to report "
        "static TOML entries as suppression status. Next steps: check the "
        "lintro log for '[osv-scanner] Probe scan', confirm check_suppressions "
        "is not disabled, and confirm lintro-image is py-lintro >= 0.94.",
        file=sys.stderr,
    )


def _scan_failed(osv_result: dict[str, Any]) -> bool:
    """Return whether the main osv-scanner scan itself failed.

    Mirrors the scanner-error branch of :func:`_add_vulnerability_sections`:
    lintro returns ``success=False`` without probe metadata on a timeout,
    version-check failure, or network failure, so the missing key is a
    consequence of the scan failure and not a separate defect.

    Args:
        osv_result: The ``osv_scanner`` result object.

    Returns:
        ``True`` when the scan failed without reporting any issue.
    """
    return osv_result.get("success") is False and not osv_result.get("issues_count")


def _add_suppression_sections(
    sections: list[str],
    osv_result: dict[str, Any],
    probe_suppressions: list[dict[str, Any]] | None,
) -> bool:
    """Append the suppressed-vulnerabilities section.

    Args:
        sections: Section list to append to.
        osv_result: The ``osv_scanner`` result object.
        probe_suppressions: Classified suppressions from the probe metadata,
            or ``None`` when the result carried none.

    Returns:
        ``False`` when the probe metadata is malformed, or missing although
        the TOML declares probe-eligible entries and the scan itself
        succeeded (diagnostic printed to stderr), else ``True``.
    """
    sections.append("### 🔇 Suppressed Vulnerabilities:")
    toml_suppressions = _read_suppressions_from_toml()
    eligible = [e for e in toml_suppressions if _is_probe_eligible(e)]
    unclassified = [e for e in toml_suppressions if not _is_probe_eligible(e)]

    if probe_suppressions is None:
        if eligible and _scan_failed(osv_result):
            # The scanner-error section above carries the diagnostic; keep
            # it in the comment rather than failing the formatter too.
            sections.append(
                "_Suppression status unavailable: the scan failed, so "
                "lintro's probe did not run._",
            )
            return True
        if eligible:
            _report_probe_metadata_missing(eligible)
            return False
    else:
        error = _probe_entry_error(probe_suppressions)
        if error is not None:
            print(
                "Suppression status unavailable: malformed probe metadata "
                f"'{PROBE_METADATA_KEY}.{SUPPRESSIONS_KEY}' — {error}",
                file=sys.stderr,
            )
            return False
        if probe_suppressions or not unclassified:
            _add_probe_suppression_table(sections, probe_suppressions)
        if probe_suppressions and unclassified:
            sections.append("")

    # lintro's probe never sees undated entries, so list them alongside
    # whatever the probe classified rather than dropping them.
    if unclassified:
        _add_toml_suppression_table(sections, unclassified)
    elif probe_suppressions is None:
        sections.append("No suppressions configured.")
    return True


def format_comment(json_path: str) -> str | None:
    """Format osv-scanner JSON results as markdown.

    Args:
        json_path: Path to the lintro JSON output file.

    Returns:
        The markdown comment body, or ``None`` when the report is unusable
        or suppression status is unavailable (diagnostic on stderr).
    """
    results = _load_lintro_results(json_path)
    if results is None:
        return None
    osv_result = _osv_scanner_result(results)
    if osv_result is None:
        print("osv-scanner did not produce results.", file=sys.stderr)
        return None

    sections: list[str] = []
    sections.append("### 🔍 Checks Performed:")
    sections.append(
        "- **osv-scanner**: Scanned all lockfiles against the OSV database",
    )
    sections.append("")

    _add_vulnerability_sections(sections, osv_result)
    sections.append("")
    if not _add_suppression_sections(
        sections=sections,
        osv_result=osv_result,
        probe_suppressions=_probe_suppressions(osv_result),
    ):
        return None
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
