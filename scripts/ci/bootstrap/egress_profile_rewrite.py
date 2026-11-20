# SPDX-License-Identifier: MIT
# For license details, see the repository root LICENSE file.
"""Rewrite one workflow for an egress profile (#1597).

The text rewrites behind ``render-egress-profile.py``, which owns the file
tree, the marker file and the command line. Text is edited line by line, so
comments and formatting survive. Every rewrite is followed by checks on its
own output: a shape this module does not recognise is a :class:`ProfileError`,
never a silent pass.

Profiles:

``block``
    Nothing changes. The policy check below still runs on the source.

``audit``
    harden-runner runs with ``egress-policy: audit``; the verify step becomes
    the generated notice step; the recheck steps and the Docker blocked-egress
    summaries are removed; ``validate-runner-policy`` gets ``tier: permissive``.

``none``
    harden-runner is not run: its steps are removed with every step that only
    computes or validates egress configuration for it, the verify step becomes
    the notice step, and every egress-policy value becomes ``none``.
"""

from __future__ import annotations

import re
import sys
from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum, auto
from pathlib import Path
from types import ModuleType

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]

NOTICE_ID = "egress-profile-notice"
NOTICE_SCRIPT = "scripts/ci/bootstrap/egress-profile-notice.sh"
VERIFY_ID = "verify-harden-runner-agent"
RECHECK_ID = "recheck-harden-runner-agent"
# The verify step's opt-in for harden-runner's eBPF fallback agent (#1668).
# The notice step does not take it over.
EBPF_OPT_IN = "LGTM_CI_ALLOW_HARDEN_RUNNER_EBPF_AGENT"
VERIFY_NAME = "Verify harden-runner agent"
NOTICE_NAME = "Report egress not enforced"
GENERATOR = "render-egress-profile.py"

STEP_NAME = re.compile(r"^(?P<indent>[ ]*)- name: (?P<name>.+?)\s*$")
ITEM = re.compile(r"^(?P<indent>[ ]*)- (?P<rest>.*)$")
KEY_VALUE = re.compile(r"^(?P<indent>[ ]*)(?P<key>[A-Za-z0-9_-]+):(?P<value>.*)$")
RECHECK_STEP = re.compile(r"^Recheck harden-runner agent( before .+)?$")
HARDEN_USES = re.compile(r"^step-security/harden-runner@")
POLICY_ACTION = re.compile(r"\S*/validate-runner-policy$")
STRICT_TIER = re.compile(r"^(?P<head>[ ]+tier: )(?:strict|hardened)\s*$")
VERIFY_COMMENT = re.compile(r"^(?P<indent>[ ]*)# Every runner \(#1203\):.*$")
ENV_KEY = re.compile(r"^(?P<indent>[ ]+)env:\s*$")
INPUT_REF = "${{ inputs.egress-policy }}"
# A policy value as written: optional list dash, optional quotes on the key.
POLICY_LINE = re.compile(
    r"^(?P<head>[ ]*(?:- +)?(?P<q>['\"]?)(?P<key>egress-policy|EGRESS_POLICY)"
    r"(?P=q)[ \t]*:)(?P<value>.*?)(?P<newline>\r?\n?)$",
)
FLOW_POLICY = re.compile(
    r"[{,][ \t]*['\"]?(?:egress-policy|EGRESS_POLICY)['\"]?[ \t]*:",
)
DEFAULT_LINE = re.compile(r"^(?P<head>[ ]+default:[ \t]*)(?P<value>.*?)(?P<nl>\r?\n?)$")
# Inputs that only configure harden-runner (egress-policy, *egress-preset,
# *allowed-endpoints and the -mode/-build/-deploy variants).
EGRESS_INPUT = re.compile(
    r"^(?:[a-z]+-)?(?:egress-policy|egress-preset|allowed-endpoints)(?:-[a-z]+)?$",
)
BLOCK_SCALAR = re.compile(r"^[>|][+-]?$")
# A YAML anchor or alias as a list item or a mapping value. Removing a step
# that defines an anchor leaves its aliases undefined, and an alias repeats a
# step this rewrite never sees, so neither is supported.
ANCHOR = re.compile(
    r"^[ ]*(?:- +)?(?:[\w-]+:[ \t]+)?(?:- +)?(?P<token>[&*][\w-]+)(?:[ \t]|$)",
    re.ASCII,
)
SUMMARY_STEP = "summarize-blocked-egress"

# Steps removed, by name, outside of the harden-runner, verify and recheck
# steps. Each entry: name -> profiles that remove it, and why.
REMOVED_BY_NAME: dict[str, tuple[frozenset[str], str]] = {
    # Its message ("Likely blocked egress ... add ... to allowed-endpoints")
    # assumes enforcement; it is wrong when nothing is blocked.
    "Summarize blocked egress": (
        frozenset({"audit", "none"}),
        "advice assumes blocked egress",
    ),
    "Fail on unknown egress-preset": (
        frozenset({"none"}),
        "validates a preset only harden-runner reads",
    ),
    "Wait for hardener Docker readiness": (
        frozenset({"none"}),
        "waits for a harden-runner agent that is not installed",
    ),
    "Refuse block egress on runners that cannot enforce it": (
        frozenset({"none"}),
        "validates egress-policy for harden-runner",
    ),
}


def unused_removals(profile: str, removed: dict[str, int]) -> list[str]:
    """Return the :data:`REMOVED_BY_NAME` steps a whole render never removed.

    A step renamed in the source would otherwise be kept silently, and a copy
    would run a step that assumes enforcement.

    Args:
        profile: Egress profile the tree was rendered with.
        removed: Removed-step totals across the tree, by reason.

    Returns:
        The step names the profile removes that matched no step.
    """
    return [
        name
        for name, (profiles, reason) in REMOVED_BY_NAME.items()
        if profile in profiles and not removed.get(reason)
    ]


class Profile(StrEnum):
    """Egress profile a copy is generated with."""

    BLOCK = auto()
    AUDIT = auto()
    NONE = auto()


class ProfileError(ValueError):
    """The source does not have the shape a profile rewrite expects."""


@dataclass
class Counts:
    """What one rewrite did, for the generator's log.

    Attributes:
        notices: Verify steps turned into notice steps.
        removed: Other steps removed, by reason.
    """

    notices: int = 0
    removed: dict[str, int] | None = None

    def add(self, reason: str) -> None:
        """Count one removed step.

        Args:
            reason: Short reason the step was removed.
        """
        self.removed = self.removed or {}
        self.removed[reason] = self.removed.get(reason, 0) + 1


# Description and comment rewrites: pattern -> replacement per profile. They
# apply to the whole text; a line wrap inside a phrase is matched by \s+.
WORDING: tuple[tuple[re.Pattern[str], dict[Profile, str]], ...] = (
    (
        re.compile(r" ?\(block only; audit rejected\)"),
        {
            Profile.AUDIT: " (audit only in this generated copy)",
            # The none profile prefixes the description with IGNORED_PREFIX.
            Profile.NONE: "",
        },
    ),
    (
        re.compile(r"enforced \(#913\)"),
        {
            Profile.AUDIT: "enforced only in a block-profile copy (#913)",
            Profile.NONE: "ignored, as this copy does not run harden-runner (#913)",
        },
    ),
    (
        re.compile(r"Enforced at job start"),
        {
            Profile.AUDIT: "Enforced only in a block-profile copy",
            Profile.NONE: "Ignored: this copy does not run harden-runner",
        },
    ),
    (
        re.compile(r"enforced at job(\s+)start"),
        {
            Profile.AUDIT: r"enforced only in a block-profile\1copy",
            Profile.NONE: r"ignored: no harden-runner\1in this copy",
        },
    ),
    (
        re.compile(
            r"Block on every run, dry-runs included: audit is rejected \(#1203\)\.",
        ),
        {
            Profile.AUDIT: "Audit egress profile (#1597): logs, blocks nothing.",
            Profile.NONE: "Egress profile none (#1597): harden-runner is not run.",
        },
    ),
)
# Left in any copy, these would claim enforcement that does not happen.
STALE_CLAIMS = re.compile(
    r"block only; audit rejected|enforced \(#913\)|[Ee]nforced at job\s+start"
    r"|audit is rejected",
)
# Replaces the verify step's "# Every runner (#1203): ..." comment.
NOTICE_COMMENT = {
    Profile.AUDIT: "# Audit egress profile (#1597): egress is not enforced;",
    Profile.NONE: "# Egress profile none (#1597): harden-runner is not run;",
}
IGNORED_PREFIX = "Ignored in this copy (egress profile none, harden-runner is not run)."


def header(profile: Profile) -> str:
    """Return the comment line a rewritten workflow starts with.

    Args:
        profile: The copy's profile.

    Returns:
        The line without its line ending.
    """
    return f"# Generated by {GENERATOR}, egress profile {profile} (#1597): do not edit."


def _sync_module() -> ModuleType:
    """Return ``sync_inline_blocks``, which the generator loads before this module.

    Raises:
        ImportError: When this module is loaded on its own.
    """
    try:
        return sys.modules["sync_inline_blocks"]
    except KeyError as error:  # pragma: no cover - the generator loads it first
        raise ImportError(
            "load egress_profile_rewrite through render-egress-profile.py",
        ) from error


SYNC = _sync_module()


def inline_bodies(root: Path = ROOT) -> dict[str, list[str]]:
    """Return every inline block body, the notice included.

    Args:
        root: Repository root the source scripts are relative to.

    Returns:
        Body lines keyed by block id.

    Raises:
        ProfileError: When the notice source lacks one marker pair.
    """
    bodies = {block_id: SYNC.generated_body(block_id, root) for block_id in SYNC.BLOCKS}
    notice = (root / NOTICE_SCRIPT).read_text(encoding="utf-8").splitlines()
    begin = f"# lgtm-ci-inline:begin {NOTICE_ID}"
    end = f"# lgtm-ci-inline:end {NOTICE_ID}"
    if notice.count(begin) != 1 or notice.count(end) != 1:
        raise ProfileError(
            f"{NOTICE_SCRIPT}: needs exactly one {NOTICE_ID} marker pair",
        )
    bodies[NOTICE_ID] = notice[notice.index(begin) + 1 : notice.index(end)]
    return bodies


def _indent(line: str) -> int:
    """Return the number of leading spaces of a line."""
    return len(line) - len(line.lstrip(" "))


def _newline(line: str) -> str:
    """Return the line ending of a line ("" on a last line without one)."""
    return line[len(line.rstrip("\r\n")) :]


def extent(lines: list[str], start: int) -> int:
    """Return the index just past the YAML node that begins at ``start``.

    The node holds every following line that is blank or indented deeper than
    ``lines[start]``. Trailing blank lines are left outside it, so the blank
    line between two jobs survives when the node is dropped.

    Args:
        lines: File lines with their endings.
        start: Index of the node's first line (a ``- name:`` or a key).

    Returns:
        The exclusive end index.
    """
    indent = _indent(lines[start])
    end = last = start + 1
    while end < len(lines):
        line = lines[end]
        if line.strip():
            if _indent(line) <= indent:
                break
            last = end + 1
        end += 1
    return last


def item_keys(item: list[str]) -> dict[str, str]:
    """Return the scalar keys of one YAML list item (a step).

    Args:
        item: The item's lines, from its ``- `` line.

    Returns:
        Each key written on the dash line or one level below it, with its
        stripped value (an empty string for a nested mapping).
    """
    first = ITEM.match(item[0].rstrip("\r\n"))
    if first is None:
        return {}
    level = len(first["indent"]) + 2
    keys: dict[str, str] = {}
    for line in [" " * level + first["rest"], *item[1:]]:
        match = KEY_VALUE.match(line.rstrip("\r\n"))
        if match and len(match["indent"]) == level:
            keys.setdefault(match["key"], match["value"].strip())
    return keys


def _removal(keys: dict[str, str], profile: Profile) -> str | None:
    """Return why a step is removed under a profile, or ``None`` to keep it."""
    name = keys.get("name", "")
    uses = keys.get("uses", "").split(" #")[0].strip()
    if RECHECK_STEP.match(name):
        return "recheck"
    if profile is Profile.NONE and HARDEN_USES.match(uses):
        return "harden-runner"
    if profile is Profile.NONE and POLICY_ACTION.search(uses):
        return "validate-runner-policy"
    rule = REMOVED_BY_NAME.get(name)
    if rule and profile in rule[0]:
        return rule[1]
    return None


def _rewrite_verify(step: list[str], profile: Profile) -> list[str]:
    """Turn one "Verify harden-runner agent" step into the notice step.

    Args:
        step: The step's lines, from its ``- name:`` line.
        profile: ``audit`` or ``none``.

    Returns:
        The notice step's lines; its body is filled in by the inline renderer.

    Raises:
        ProfileError: When the step lacks a part the rewrite relies on.
    """
    first = ITEM.match(step[0].rstrip("\r\n"))
    if first is None or not first["rest"].startswith("name:"):
        # The first line is replaced; another key there (``- id:``) would be
        # lost and the name duplicated.
        raise ProfileError(f"{VERIFY_NAME!r} step does not start with its name")
    newline = _newline(step[0])
    indent = " " * _indent(step[0])
    out = [f"{indent}- name: {NOTICE_NAME}{newline}"]
    seen = {"comment": 0, "env": 0, "begin": 0, "end": 0}
    for line in step[1:]:
        text = line.rstrip("\r\n")
        comment = VERIFY_COMMENT.match(text)
        if comment:
            seen["comment"] += 1
            said = f"{NOTICE_COMMENT[profile]} this step says so."
            out.append(f"{comment['indent']}{said}{newline}")
            continue
        if text.lstrip().startswith(f"{EBPF_OPT_IN}:"):
            # The notice checks no agent, and the profile drops the rechecks.
            continue
        env = ENV_KEY.match(text)
        if env:
            seen["env"] += 1
            out.append(line)
            out.append(f"{env['indent']}  EGRESS_PROFILE: {profile}{_newline(line)}")
            continue
        for kind in ("begin", "end"):
            if text.strip() == f"# lgtm-ci-inline:{kind} {VERIFY_ID}":
                seen[kind] += 1
                line = line.replace(VERIFY_ID, NOTICE_ID)
        if text.lstrip().startswith("#"):
            line = line.replace(
                "verify-harden-runner-agent.sh",
                "egress-profile-notice.sh",
            )
        out.append(line)
    missing = [part for part, count in seen.items() if count != 1]
    if missing:
        raise ProfileError(f"{VERIFY_NAME!r} step lacks exactly one {missing}")
    return out


def rewrite_steps(lines: list[str], profile: Profile) -> tuple[list[str], Counts]:
    """Replace verify steps and drop the steps a profile removes.

    Args:
        lines: File lines with their endings.
        profile: ``audit`` or ``none``.

    Returns:
        The new lines and what was done.
    """
    out: list[str] = []
    counts = Counts()
    index = 0
    while index < len(lines):
        if ITEM.match(lines[index].rstrip("\r\n")) is None:
            out.append(lines[index])
            index += 1
            continue
        end = extent(lines, index)
        keys = item_keys(lines[index:end])
        reason = _removal(keys, profile)
        if reason is not None:
            counts.add(reason)
        elif keys.get("name") == VERIFY_NAME:
            out.extend(_rewrite_verify(lines[index:end], profile))
            counts.notices += 1
        else:
            # Not a step this rewrite touches: keep its first line and look
            # inside it (a job's steps are items nested in other items only
            # in matrices, which hold no steps, but look anyway).
            out.append(lines[index])
            index += 1
            continue
        index = end
    return out, counts


def scalar_lines(lines: list[str]) -> set[int]:
    """Return the indexes of lines inside block scalars (``run: |``, ``>-``).

    Their text is shell or prose, never YAML keys, so policy rewrites and
    checks skip it.
    """
    inside: set[int] = set()
    for index, line in enumerate(lines):
        text = line.rstrip("\r\n")
        item = ITEM.match(text)
        if item:
            text = " " * (len(item["indent"]) + 2) + item["rest"]
        match = KEY_VALUE.match(text)
        if not match or not BLOCK_SCALAR.match(match["value"].split(" #")[0].strip()):
            continue
        level = len(match["indent"])
        for inner in range(index + 1, len(lines)):
            if lines[inner].strip() and _indent(lines[inner]) <= level:
                break
            inside.add(inner)
    return inside


def _declarations(lines: list[str], wanted: Callable[[str], bool]) -> list[int]:
    """Return the indexes of input declarations (``name:`` with a mapping body)."""
    found: list[int] = []
    for index, line in enumerate(lines):
        match = KEY_VALUE.match(line.rstrip("\r\n"))
        if not match or match["value"].strip() or not wanted(match["key"]):
            continue
        level = len(match["indent"]) + 2
        body = lines[index + 1 : extent(lines, index)]
        if any(
            (m := KEY_VALUE.match(b.rstrip("\r\n")))
            and len(m["indent"]) == level
            and m["key"] in ("description", "type", "default")
            for b in body
        ):
            found.append(index)
    return found


def _rewrite_defaults(lines: list[str], profile: Profile) -> list[str]:
    """Make every ``egress-policy`` input default to the profile's policy."""
    out = list(lines)
    for index in _declarations(lines, lambda key: key == "egress-policy"):
        level = _indent(lines[index]) + 2
        for inner in range(index + 1, extent(lines, index)):
            default = DEFAULT_LINE.match(out[inner])
            if default and _indent(out[inner]) == level:
                value = default["value"]
                if value in ("block", '"block"'):
                    value = value.replace("block", str(profile))
                out[inner] = f"{default['head']}{value}{default['nl']}"
    return out


def _mark_ignored(lines: list[str]) -> list[str]:
    """Prefix the description of every egress input with :data:`IGNORED_PREFIX`.

    Raises:
        ProfileError: When a description has a form this does not edit.
    """
    out = list(lines)
    inserts: list[tuple[int, str]] = []
    for index in _declarations(lines, lambda key: bool(EGRESS_INPUT.match(key))):
        level = _indent(lines[index]) + 2
        for inner in range(index + 1, extent(lines, index)):
            match = KEY_VALUE.match(lines[inner].rstrip("\r\n"))
            if not match or match["key"] != "description":
                continue
            if len(match["indent"]) != level:
                continue
            value = match["value"].strip()
            nl = _newline(lines[inner])
            head = f"{match['indent']}description: "
            if BLOCK_SCALAR.match(value):
                inserts.append((inner + 1, f"{' ' * (level + 2)}{IGNORED_PREFIX}{nl}"))
            elif value[:1] in ("'", '"'):
                out[inner] = f"{head}{value[0]}{IGNORED_PREFIX} {value[1:]}{nl}"
            elif value:
                out[inner] = f"{head}{IGNORED_PREFIX} {value}{nl}"
            else:
                raise ProfileError(f"line {inner + 1}: empty input description")
    for position, line in sorted(inserts, reverse=True):
        out.insert(position, line)
    return out


def _rewrite_lines(lines: list[str], profile: Profile) -> list[str]:
    """Set policy values and validate-runner-policy tiers for a profile."""
    out = list(lines)
    scalars = scalar_lines(lines)
    for index, line in enumerate(lines):
        policy = POLICY_LINE.match(line)
        if policy and index not in scalars and not line.lstrip().startswith("#"):
            value = policy["value"].strip()
            if value == "block" or (profile is Profile.NONE and value == INPUT_REF):
                out[index] = f"{policy['head']} {profile}{policy['newline']}"
        if profile is Profile.AUDIT and _uses_policy_action(line):
            start = index
            while start > 0 and not lines[start].lstrip().startswith("- "):
                start -= 1
            for inner in range(start, extent(lines, start)):
                tier = STRICT_TIER.match(out[inner].rstrip("\r\n"))
                if tier:
                    out[inner] = f"{tier['head']}permissive{_newline(out[inner])}"
    return out


def _uses_policy_action(line: str) -> bool:
    """Tell whether a line is ``uses:`` of the validate-runner-policy action.

    A trailing comment is dropped first, as :func:`_removal` does, and other
    lines that merely end in the action's path (a script, a comment) are not
    matched.
    """
    text = line.strip().removeprefix("- ").lstrip()
    if not text.startswith("uses:"):
        return False
    uses = text.removeprefix("uses:").split(" #")[0].strip().strip("'\"")
    return POLICY_ACTION.search(uses) is not None


def _check_default(lines: list[str], index: int, profile: Profile, path: str) -> None:
    """Fail when the ``egress-policy`` input declared at ``index`` defaults wrongly.

    Raises:
        ProfileError: Naming the file and line of the default.
    """
    level = _indent(lines[index]) + 2
    for inner in range(index + 1, extent(lines, index)):
        default = DEFAULT_LINE.match(lines[inner])
        if (
            default
            and _indent(lines[inner]) == level
            and default["value"] not in (str(profile), f'"{profile}"')
        ):
            raise ProfileError(
                f"{path}:{inner + 1}: egress-policy default"
                f" {default['value']!r} is not {profile!s}",
            )


def check_policies(text: str, profile: Profile, path: str) -> None:
    """Fail on any policy value that is not exactly the profile's form.

    Covers ``egress-policy`` and ``EGRESS_POLICY`` values and the default of
    every ``egress-policy`` input. Quoted values, trailing comments,
    expressions other than ``${{ inputs.egress-policy }}`` and flow mappings
    are rejected rather than guessed at.

    Args:
        text: Rendered file contents.
        profile: The profile the file must carry.
        path: File name for the error message.

    Raises:
        ProfileError: Naming the file and line of the first bad value.
    """
    allowed = {str(profile)} if profile is Profile.NONE else {str(profile), INPUT_REF}
    lines = text.splitlines(keepends=True)
    declared = set(_declarations(lines, lambda key: key == "egress-policy"))
    scalars = scalar_lines(lines)
    for index, line in enumerate(lines):
        stripped = line.strip()
        if index in scalars or stripped.startswith("#"):
            continue
        where = f"{path}:{index + 1}"
        if FLOW_POLICY.search(line):
            raise ProfileError(f"{where}: egress-policy in a flow mapping: {stripped}")
        policy = POLICY_LINE.match(line)
        if policy is None:
            continue
        value = policy["value"].strip()
        if index in declared:
            _check_default(lines, index, profile, path)
            continue
        if value not in allowed:
            raise ProfileError(
                f"{where}: {policy['key']} {value!r} is not one of {sorted(allowed)}"
                f" ({profile} profile)",
            )


def _refuse_anchors(lines: list[str]) -> None:
    """Refuse YAML anchors and aliases outside block scalars.

    Raises:
        ProfileError: Naming the line of the first one.
    """
    skipped = scalar_lines(lines)
    for index, line in enumerate(lines):
        if index in skipped:
            continue
        match = ANCHOR.match(line.rstrip("\r\n"))
        if match:
            raise ProfileError(
                f"line {index + 1}: YAML anchor or alias {match['token']!r};"
                " a non-block profile cannot rewrite a file that uses them",
            )


def _check_output(text: str, profile: Profile) -> None:
    """Fail when a step this profile removes or replaces survived.

    Raises:
        ProfileError: Naming what survived.
    """
    for block_id in (VERIFY_ID, RECHECK_ID):
        if f"# lgtm-ci-inline:begin {block_id}" in text:
            raise ProfileError(f"a {block_id} block is not inside a step it rewrites")
    if f"STEP: {SUMMARY_STEP}" in text:
        raise ProfileError(f"a {SUMMARY_STEP} step is not named as the rewrite expects")
    stale = STALE_CLAIMS.search(text)
    if stale:
        raise ProfileError(f"wording still claims enforcement: {stale.group(0)!r}")
    if profile is Profile.NONE:
        for line in text.splitlines():
            stripped = line.strip().removeprefix("- ")
            survivors = ("step-security/harden-runner", "validate-runner-policy")
            if stripped.startswith("uses:") and any(s in stripped for s in survivors):
                raise ProfileError(f"a step survived the none profile: {stripped}")


def rewrite(
    text: str,
    profile: Profile,
    bodies: dict[str, list[str]],
    path: str = "<workflow>",
) -> tuple[str, Counts]:
    """Rewrite one workflow or example for a profile, then check the result.

    Args:
        text: File contents.
        profile: Egress profile; ``block`` returns the text unchanged.
        bodies: Inline block bodies keyed by id, including :data:`NOTICE_ID`.
        path: File name for error messages.

    Returns:
        The rewritten text and what was done.

    Raises:
        ProfileError: When the source has an unexpected shape or the output
            breaks a profile invariant.
    """
    if profile is Profile.BLOCK:
        check_policies(text, profile, path)
        return text, Counts()
    lines = text.splitlines(keepends=True)
    try:
        _refuse_anchors(lines)
        lines, counts = rewrite_steps(lines, profile)
        lines = _rewrite_defaults(lines, profile)
        lines = _rewrite_lines(lines, profile)
        if profile is Profile.NONE:
            lines = _mark_ignored(lines)
    except ProfileError as error:
        raise ProfileError(f"{path}: {error}") from error
    joined = "".join(lines)
    for pattern, replacements in WORDING:
        joined = pattern.sub(replacements[profile], joined)
    newline = _newline(lines[0]) if lines else "\n"
    joined = f"{header(profile)}{newline or chr(10)}{joined}"
    try:
        rendered, _counts = SYNC.render(joined, bodies)
    except SYNC.MarkerError as error:
        raise ProfileError(f"{path}: {error}") from error
    try:
        _check_output(rendered, profile)
    except ProfileError as error:
        raise ProfileError(f"{path}: {error}") from error
    check_policies(rendered, profile, path)
    return rendered, counts
