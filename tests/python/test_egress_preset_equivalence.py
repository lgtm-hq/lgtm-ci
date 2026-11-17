# SPDX-License-Identifier: MIT
"""What every hardened job may reach, per workflow and per preset name (#1623).

Each workflow embeds only the presets it accepts and carries GitHub's results
storage hosts once, under ``env.LGTM_CI_EGRESS_RESULTS_STORAGE``; the
expression that indexes the preset map appends them for the presets listed in
``env.LGTM_CI_EGRESS_RESULTS_STORAGE_PRESETS``. Until #1623 every workflow
embedded every preset with the storage hosts written into three of them, so a
job hardened with preset P could reach exactly ``egress_preset_endpoints P``.

This module evaluates the real ``allowed-endpoints`` expression of every
harden-runner step (and the scorecard job output that feeds one) and the
unknown-preset guard after it, for every workflow and every preset name, and
compares the hosts a job may reach with that baseline:

- a preset the workflow accepts reaches exactly the baseline set;
- any other name reaches nothing and fails the guard, as an unknown name
  always has.

The baseline is ``render-presets.sh --json`` (each preset's effective list
from ``presets.sh``). Set ``EGRESS_BASELINE_REF`` to a git revision, for
example the commit before #1623, to compare with the map each workflow
embedded at that revision instead.
"""

from __future__ import annotations

import json
import math
import os
import re
import subprocess
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from functools import cache
from pathlib import Path
from typing import Any

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
RENDER = ROOT / "scripts" / "ci" / "egress" / "render-presets.sh"
BEGIN_MARK = "# lgtm-ci-egress-presets:begin"
MAP_KEY = "LGTM_CI_EGRESS_PRESETS"
GUARD_NAME = "Fail on unknown egress-preset"
HARDEN_USES = "step-security/harden-runner@"
SELECTOR = re.compile(r"fromJSON\(env\.LGTM_CI_EGRESS_PRESETS\)\[([^\]]+)\]")

# ---------------------------------------------------------------------------
# A small evaluator for the expression subset the selectors use: literals,
# context paths, `!`, `&&`, `||`, `==`, `!=`, parentheses, indexing and the
# functions fromJSON, format and contains. It follows the runner's rules
# (docs.github.com, "Evaluate expressions in workflows and actions"):
#
# - `&&` and `||` short-circuit and return an operand, not a boolean, so
#   `false && fromJSON('') || ''` is `''` and never parses '' as JSON;
# - `==`, `!=` and `contains` on an array compare loosely: values of
#   different types are both converted to numbers (null and '' are 0, true is
#   1, a non-numeric string is NaN, which equals nothing), strings compare
#   case-insensitively, and an array or object equals only itself;
# - `contains` on a string converts the item to a string and ignores case;
# - falsy values are null, false, 0, NaN and ''.
#
# The parser compiles each expression to a tree of thunks so an operand that
# is short-circuited is never evaluated.
# ---------------------------------------------------------------------------

_TOKEN = re.compile(
    r"\s*(?:(?P<str>'(?:[^']|'')*')|(?P<op>&&|\|\||==|!=|!|\(|\)|\[|\]|,)"
    r"|(?P<num>-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?(?![A-Za-z0-9_.-]))"
    r"|(?P<ident>[A-Za-z_][A-Za-z0-9_-]*(?:\.[A-Za-z_][A-Za-z0-9_-]*)*))",
)
_NUMERIC = re.compile(r"[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")
_HEX = re.compile(r"0[xX][0-9a-fA-F]+")

Thunk = Callable[[], Any]


def _tokens(source: str) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    pos = 0
    source = source.strip()
    while pos < len(source):
        match = _TOKEN.match(source, pos)
        if match is None or match.lastgroup is None:
            raise ValueError(f"cannot tokenize {source[pos:]!r}")
        out.append((match.lastgroup, match.group(match.lastgroup)))
        pos = match.end()
        while pos < len(source) and source[pos].isspace():
            pos += 1
    return out


def _kind(value: Any) -> str:
    """Return the runner's type name for a value."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int | float):
        return "number"
    if isinstance(value, str):
        return "string"
    return "array" if isinstance(value, list) else "object"


def _string_number(text: str) -> float:
    """Parse a string as the runner does: blank is 0, hex and decimals parse."""
    text = text.strip()
    if not text:
        return 0.0
    if _HEX.fullmatch(text):
        return float(int(text, 16))
    return float(text) if _NUMERIC.fullmatch(text) else math.nan


def _number(value: Any) -> float:
    """Convert a primitive to a number as the runner does (NaN if it cannot)."""
    kind = _kind(value)
    if kind == "null":
        return 0.0
    if kind in ("boolean", "number"):
        return float(value)
    return _string_number(value) if kind == "string" else math.nan


def _truthy(value: Any) -> bool:
    kind = _kind(value)
    if kind == "null":
        return False
    if kind == "boolean":
        return bool(value)
    if kind == "number":
        return not (value == 0 or math.isnan(float(value)))
    if kind == "string":
        return bool(value != "")
    return True


def _equals(left: Any, right: Any) -> bool:
    """Loose equality: `==` and the element test of `contains` on an array."""
    left_kind, right_kind = _kind(left), _kind(right)
    if left_kind == right_kind:
        if left_kind == "string":
            return bool(left.casefold() == right.casefold())
        if left_kind in ("array", "object"):
            return left is right
        return bool(left == right)
    if {left_kind, right_kind} & {"array", "object"}:
        return False
    a, b = _number(left), _number(right)
    return not (math.isnan(a) or math.isnan(b)) and a == b


def _index(container: Any, key: Any) -> Any:
    if isinstance(container, dict) and isinstance(key, str):
        for name, value in container.items():
            if name.casefold() == key.casefold():
                return value
    if isinstance(container, list) and _kind(key) == "number":
        if not float(key).is_integer():
            return None
        position = int(key)
        return container[position] if 0 <= position < len(container) else None
    return None


def _text(value: Any) -> str:
    """Render a value as the runner interpolates it (null empty, bools lower)."""
    kind = _kind(value)
    if kind == "null":
        return ""
    if kind == "boolean":
        return "true" if value else "false"
    if kind == "number" and float(value).is_integer():
        return str(int(value))
    return str(value)


def _contains(search: Any, item: Any) -> bool:
    if isinstance(search, list):
        return any(_equals(element, item) for element in search)
    return _text(item).casefold() in _text(search).casefold()


class _Parser:
    def __init__(self, source: str, context: dict[str, Any]) -> None:
        self.tokens = _tokens(source)
        self.pos = 0
        self.context = context

    def peek(self) -> str | None:
        """Return the next token text, or None at the end."""
        return self.tokens[self.pos][1] if self.pos < len(self.tokens) else None

    def take(self, text: str | None = None) -> tuple[str, str]:
        """Consume the next token, optionally requiring its text."""
        if self.pos >= len(self.tokens):
            raise ValueError("unexpected end of expression")
        token = self.tokens[self.pos]
        if text is not None and token[1] != text:
            raise ValueError(f"expected {text!r}, got {token[1]!r}")
        self.pos += 1
        return token

    def parse(self) -> Any:
        """Compile the whole expression, then evaluate it."""
        thunk = self.parse_or()
        if self.peek() is not None:
            raise ValueError(f"trailing token {self.peek()!r}")
        return thunk()

    def parse_or(self) -> Thunk:
        """Compile a `||` chain: the first truthy operand, else the last."""
        thunk = self.parse_and()
        while self.peek() == "||":
            self.take()
            left, right = thunk, self.parse_and()

            def either(left: Thunk = left, right: Thunk = right) -> Any:
                value = left()
                return value if _truthy(value) else right()

            thunk = either
        return thunk

    def parse_and(self) -> Thunk:
        """Compile a `&&` chain: the first falsy operand, else the last."""
        thunk = self.parse_comparison()
        while self.peek() == "&&":
            self.take()
            left, right = thunk, self.parse_comparison()

            def both(left: Thunk = left, right: Thunk = right) -> Any:
                value = left()
                return right() if _truthy(value) else value

            thunk = both
        return thunk

    def parse_comparison(self) -> Thunk:
        """Compile an optional `==` or `!=`."""
        left = self.parse_unary()
        if self.peek() in ("==", "!="):
            negate = self.take()[1] == "!="
            right = self.parse_unary()
            return lambda: _equals(left(), right()) != negate
        return left

    def parse_unary(self) -> Thunk:
        """Compile an optional `!` prefix."""
        if self.peek() == "!":
            self.take()
            operand = self.parse_unary()
            return lambda: not _truthy(operand())
        return self.parse_postfix()

    def parse_postfix(self) -> Thunk:
        """Compile an operand and any `[...]` indexing after it."""
        thunk = self.parse_primary()
        while self.peek() == "[":
            self.take()
            key = self.parse_or()
            self.take("]")

            def indexed(container: Thunk = thunk, key: Thunk = key) -> Any:
                return _index(container(), key())

            thunk = indexed
        return thunk

    def parse_primary(self) -> Thunk:
        """Compile a literal, context path, function call or group."""
        kind, text = self.take()
        if text == "(":
            thunk = self.parse_or()
            self.take(")")
            return thunk
        if kind == "str":
            value: Any = text[1:-1].replace("''", "'")
            return lambda: value
        if kind == "num":
            number = float(text)
            return lambda: number
        if kind != "ident":
            raise ValueError(f"unexpected token {text!r}")
        if text in ("true", "false", "null"):
            literal = {"true": True, "false": False, "null": None}[text]
            return lambda: literal
        if self.peek() == "(":
            self.take()
            args: list[Thunk] = []
            while self.peek() != ")":
                args.append(self.parse_or())
                if self.peek() == ",":
                    self.take()
            self.take(")")
            if text not in ("fromJSON", "format", "contains"):
                raise ValueError(f"unsupported function {text}()")
            return lambda: self._call(text, [arg() for arg in args])
        return lambda: self.context.get(text)

    @staticmethod
    def _call(name: str, args: list[Any]) -> Any:
        if name == "fromJSON":
            return json.loads(_text(args[0]))
        if name == "format":
            fmt = _text(args[0])
            return re.sub(r"\{(\d+)\}", lambda m: _text(args[1 + int(m[1])]), fmt)
        return _contains(args[0], args[1])


def evaluate(template: str, context: dict[str, Any]) -> Any:
    """Evaluate a workflow value that holds `${{ }}` expressions.

    Args:
        template: The value, as YAML loaded it.
        context: Flat mapping of context paths (``inputs.x``, ``env.X``).

    Returns:
        The value of a lone expression, else the interpolated string.
    """
    spans = re.findall(r"\$\{\{(.*?)\}\}", template, flags=re.S)
    if len(spans) == 1 and template.strip() == "${{" + spans[0] + "}}":
        return _Parser(spans[0], context).parse()
    return re.sub(
        r"\$\{\{(.*?)\}\}",
        lambda m: _text(_Parser(m[1], context).parse()),
        template,
        flags=re.S,
    )


# ---------------------------------------------------------------------------
# Workflow model
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Site:
    """One place a job's allow-list is composed from the preset map.

    Attributes:
        workflow: Workflow file name.
        job: Job id.
        where: Step name or ``outputs.allowed-endpoints``.
        expression: The ``allowed-endpoints`` value.
        env: Workflow env overlaid with the job env.
        guards: ``if:`` of each unknown-preset guard in the job.
    """

    workflow: str
    job: str
    where: str
    expression: str
    env: dict[str, str]
    guards: tuple[str, ...]


def _load(text: str) -> dict[str, Any]:
    document = yaml.safe_load(text)
    assert isinstance(document, dict)
    return document


def _inputs(document: dict[str, Any]) -> dict[str, Any]:
    # PyYAML reads the bare key `on` as True.
    triggers: Any = next((v for k, v in document.items() if k in ("on", True)), {})
    call = triggers.get("workflow_call") if isinstance(triggers, dict) else None
    return (call or {}).get("inputs") or {}


def _bare(condition: str) -> str:
    """Strip an optional `${{ }}` wrapper from an `if:` expression."""
    return condition.removeprefix("${{").removesuffix("}}")


def _embedded(document: dict[str, Any]) -> dict[str, str]:
    """Return the env block that carries the preset map (workflow or job level)."""
    blocks: list[Any] = [document.get("env")]
    blocks += [job.get("env") for job in document["jobs"].values()]
    for block in blocks:
        if isinstance(block, dict) and MAP_KEY in block:
            return {str(key): str(value) for key, value in block.items()}
    raise AssertionError("no embedded preset map")


def _sites(name: str, document: dict[str, Any]) -> Iterator[Site]:
    workflow_env = document.get("env") or {}
    for job_id, job in document["jobs"].items():
        env = {**workflow_env, **(job.get("env") or {})}
        steps = job.get("steps") or []
        named = [step for step in steps if step.get("name") == GUARD_NAME]
        guards = tuple(str(step["if"]) for step in named)
        output = (job.get("outputs") or {}).get("allowed-endpoints")
        if isinstance(output, str) and SELECTOR.search(output):
            yield Site(name, job_id, "outputs.allowed-endpoints", output, env, guards)
        for step in steps:
            if not str(step.get("uses", "")).startswith(HARDEN_USES):
                continue
            value = str((step.get("with") or {}).get("allowed-endpoints", ""))
            if not SELECTOR.search(value):
                # The scorecard job hardens with the egress-preset job's
                # output, checked above as its own site (#1173).
                assert "needs." in value, f"{name}/{job_id}: {value!r}"
                continue
            yield Site(name, job_id, str(step.get("name")), value, env, guards)


@cache
def _workflows() -> dict[str, dict[str, Any]]:
    return {
        path.name: _load(path.read_text())
        for path in sorted(WORKFLOWS.glob("*.yml"))
        if BEGIN_MARK in path.read_text()
    }


@cache
def _baseline(name: str) -> dict[str, frozenset[str]]:
    """Return the hosts each preset reached before #1623, for one workflow."""
    ref = os.environ.get("EGRESS_BASELINE_REF")
    if ref:
        # Fail closed: an unknown ref must not fall back to the render and
        # pass as if the comparison had been made.
        resolved = subprocess.run(
            ["git", "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        assert resolved.returncode == 0, f"EGRESS_BASELINE_REF {ref!r} is not a commit"
        shown = subprocess.run(
            ["git", "show", f"{ref}:.github/workflows/{name}"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        if shown.returncode == 0:
            embedded = _embedded(_load(shown.stdout))
            assert set(embedded) == {MAP_KEY}, f"{ref}:{name} is not a pre-#1623 map"
            presets = json.loads(embedded[MAP_KEY])
            return {key: frozenset(value.split()) for key, value in presets.items()}
    rendered = subprocess.run(
        ["bash", str(RENDER), "--json"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    presets = json.loads(rendered)
    return {key: frozenset(value.split()) for key, value in presets.items()}


@cache
def _all_presets() -> tuple[str, ...]:
    rendered = subprocess.run(
        ["bash", str(RENDER), "--json"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return tuple(json.loads(rendered))


def _context(document: dict[str, Any], env: dict[str, str]) -> dict[str, Any]:
    context: dict[str, Any] = {
        f"inputs.{key}": spec.get("default", "")
        for key, spec in _inputs(document).items()
        if isinstance(spec, dict)
    }
    context.update({f"env.{key}": value for key, value in env.items()})
    return context


def _cases() -> Iterator[Any]:
    for name, document in _workflows().items():
        for site in _sites(name, document):
            yield pytest.param(site, id=f"{name}:{site.job}:{site.where}")


CASES = list(_cases())


def test_every_workflow_with_a_map_is_covered() -> None:
    """Each workflow that embeds the map either composes from it or is a wrapper."""
    covered = {case.values[0].workflow for case in CASES}
    for name, document in _workflows().items():
        if name in covered:
            continue
        # A wrapper only forwards egress-preset to the reusables it calls
        # and runs no harden-runner step of its own.
        text = (WORKFLOWS / name).read_text()
        assert HARDEN_USES not in text, name
        assert "egress-preset" in _inputs(document), name
    assert len(covered) >= 60


@pytest.mark.parametrize("site", CASES)
def test_reachable_hosts_per_preset_match_the_baseline(site: Site) -> None:
    """For every preset name: accepted -> baseline set; otherwise -> nothing + guard."""
    document = _workflows()[site.workflow]
    baseline = _baseline(site.workflow)
    accepted = set(json.loads(_embedded(document)[MAP_KEY]))
    selector = SELECTOR.search(site.expression)
    assert selector is not None
    preset_inputs = re.findall(r"inputs\.([a-z-]+)", selector[1])
    context = _context(document, site.env)

    if not preset_inputs:
        # A fixed preset ('github-minimal', ...): one evaluation.
        literal = re.findall(r"'([a-z-]+)'", selector[1])
        reached = frozenset(_text(evaluate(site.expression, context)).split())
        assert reached == baseline[literal[0]], literal[0]
        return

    for preset_input in preset_inputs:
        for preset in _all_presets():
            scenario = {**context, f"inputs.{preset_input}": preset}
            reached = frozenset(_text(evaluate(site.expression, scenario)).split())
            # The guard fires only when the selector's other inputs do not
            # take precedence; the site-quality test job falls back from
            # test-egress-preset to egress-preset, so setting the latter while
            # the former has a value would not select it.
            chosen = _text(evaluate("${{ " + selector[1] + " }}", scenario))
            # An `if:` is a bare expression; evaluate it as one.
            fails = [_truthy(_Parser(_bare(g), scenario).parse()) for g in site.guards]
            if chosen in accepted:
                assert reached == baseline[chosen], (preset_input, preset)
                assert not any(fails), (preset_input, preset)
            else:
                assert reached == frozenset(), (preset_input, preset)
                assert site.guards, "no unknown-preset guard in the job"
                assert all(fails), (preset_input, preset)


def test_storage_hosts_appear_once_per_workflow() -> None:
    """No workflow file lists a results storage host more than once."""
    for path in sorted(WORKFLOWS.glob("*.yml")):
        hosts = re.findall(
            r"productionresultssa\d+\.blob\.core\.windows\.net:443", path.read_text()
        )
        assert len(hosts) == len(set(hosts)), path.name


def test_evaluator_matches_the_runner_on_the_composed_shape() -> None:
    """The evaluator itself: null lookups, contains on arrays, case-insensitive keys."""
    context = {
        "env.M": '{"a":"x:1","b":"y:1"}',
        "env.L": '["b"]',
        "env.S": "s:1 t:1",
        "inputs.p": "B",
    }
    expression = (
        "${{ format('{0} {1}', fromJSON(env.M)[inputs.p], "
        "contains(fromJSON(env.L), inputs.p) && env.S || '') }}"
    )
    assert evaluate(expression, context) == "y:1 s:1 t:1"
    assert evaluate(expression, {**context, "inputs.p": "a"}) == "x:1 "
    assert evaluate(expression, {**context, "inputs.p": "zz"}) == " "
    assert evaluate("${{ fromJSON(env.M)['zz'] == null }}", context) is True
    assert evaluate("${{ !contains('abc', 'B') }}", context) is False
    with pytest.raises(ValueError, match="unsupported"):
        evaluate("${{ toJSON(env.M) }}", context)


@pytest.mark.parametrize(
    ("expression", "expected"),
    [
        # Loose equality: different types compare as numbers.
        ("null == ''", True),
        ("null == 0", True),
        ("null == false", True),
        ("'' == false", True),
        ("true == 1", True),
        ("'1' == 1", True),
        ("' 2 ' == 2", True),
        ("'0x10' == 16", True),
        ("'abc' == 0", False),
        ("'abc' != 0", True),
        ("null != ''", False),
        # Strings ignore case; arrays and objects equal only themselves.
        ("'ABC' == 'abc'", True),
        ("fromJSON('[]') == fromJSON('[]')", False),
        ("fromJSON('[]') == ''", False),
        # contains on an array uses the same loose equality.
        ("contains(fromJSON('[\"\"]'), null)", True),
        ("contains(fromJSON('[0]'), '')", True),
        ("contains(fromJSON('[\"A\"]'), 'a')", True),
        ("contains(fromJSON('[\"a\"]'), null)", False),
        # contains on a string converts the item and ignores case.
        ("contains('is TRUE here', true)", True),
        ("contains('abc', null)", True),
    ],
)
def test_evaluator_coerces_like_the_runner(expression: str, expected: bool) -> None:
    """==, != and contains follow the runner's loose comparison rules."""
    assert evaluate("${{ " + expression + " }}", {}) is expected


@pytest.mark.parametrize(
    ("expression", "expected"),
    [
        # A short-circuited operand is never evaluated: fromJSON('') would raise.
        ("false && fromJSON('') || ''", ""),
        ("true || fromJSON('')", True),
        ("'' && fromJSON('')", ""),
        # The operators return an operand, not a boolean.
        ("'a' && 'b'", "b"),
        ("0 || 'x'", "x"),
        ("null || ''", ""),
        ("'a' || fromJSON('')", "a"),
        # Falsy values: null, false, 0, '' (NaN: see the test below).
        ("!null && !false && !0 && !''", True),
        ("!fromJSON('[]')", False),
    ],
)
def test_evaluator_short_circuits_like_the_runner(
    expression: str,
    expected: Any,
) -> None:
    """&& and || are lazy and return operand values."""
    assert evaluate("${{ " + expression + " }}", {}) == expected


def test_evaluator_still_evaluates_the_operand_it_needs() -> None:
    """Laziness must not hide an operand that is evaluated."""
    with pytest.raises(json.JSONDecodeError):
        evaluate("${{ true && fromJSON('') }}", {})
    # NaN is falsy and equals nothing, itself included.
    assert not _truthy(math.nan)
    assert not _equals(math.nan, math.nan)
