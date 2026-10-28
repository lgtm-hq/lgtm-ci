# SPDX-License-Identifier: MIT
"""Exercise conservative auth selection independently of runtime defaults."""

from types import ModuleType

import pytest
from assertpy import assert_that


@pytest.mark.parametrize("forwarded", [False, True])
@pytest.mark.parametrize("component", ["provider", "transport", "auth"])
@pytest.mark.parametrize(
    ("value", "variables"),
    [
        pytest.param("", {}, id="empty-input"),
        pytest.param(None, {}, id="omitted-input"),
        pytest.param("   ", {}, id="blank-input"),
        pytest.param("${{ needs.config.outputs.selector }}", {}, id="dynamic-input"),
        pytest.param("${{ vars.REVIEW_SELECTOR }}", {}, id="unset-variable"),
        pytest.param("${{ vars.REVIEW_SELECTOR }}", None, id="unreadable-variable"),
        pytest.param(
            "${{ vars.REVIEW_SELECTOR }}",
            {"REVIEW_SELECTOR": ""},
            id="empty-variable",
        ),
    ],
)
def test_unknown_component_filters_only_known_components(
    consumer_scan: ModuleType,
    component: str,
    value: str | None,
    variables: dict[str, str] | None,
    forwarded: bool,
) -> None:
    """An unknown component accepts any compatible slot and never an exact error."""
    policy = consumer_scan.review_auth_policy
    passed: dict[str, str | None] = {
        "provider": "openai",
        "transport": "cli",
        "auth": "api_key",
    }
    passed[component] = value
    mapping = {}
    if forwarded:
        mapping["CODEX_API_KEY"] = "${{ secrets.OPENAI_REVIEW_API_KEY }}"
    found = policy.findings(passed=passed, secrets=mapping, variables=variables)
    errors = {item for item in found if item.startswith("error:")}
    assert_that(bool(errors)).is_equal_to(not forwarded)
    assert_that("\n".join(errors)).does_not_contain("selected review slot")
    notes = found - errors
    assert_that(notes).is_length(1)
    assert_that(next(iter(notes))).contains(
        "auth selection unverified",
        "compatible tuples:",
        "openai/cli/api_key",
    )


@pytest.mark.parametrize(
    "slot",
    [None, "CODEX_API_KEY", "CODEX_AUTH_JSON", "OPENAI_API_KEY"],
)
@pytest.mark.parametrize("provider", ["", "openai"])
def test_dynamic_auth_with_config_or_literal_provider(
    consumer_scan: ModuleType,
    provider: str,
    slot: str | None,
) -> None:
    """Config providers stay possible, and dynamic auth permits either CLI auth."""
    mapping = {}
    if slot:
        source = "OPENAI_REVIEW_API_KEY" if slot.endswith("API_KEY") else slot
        mapping[slot] = f"${{{{ secrets.{source} }}}}"
    found = consumer_scan.review_auth_policy.findings(
        passed={
            "provider": provider,
            "transport": "cli",
            "auth": "${{ needs.config.outputs.auth }}",
        },
        secrets=mapping,
        variables={},
    )
    errors = {item for item in found if item.startswith("error:")}
    assert_that(bool(errors)).is_equal_to(slot in (None, "OPENAI_API_KEY"))
    notes = found - errors
    assert_that(notes).is_length(1)
    assert_that(next(iter(notes))).contains(
        "auth selection unverified",
        "openai/cli/oauth",
        "openai/cli/api_key",
    ).does_not_contain("openai/api/api_key")


@pytest.mark.parametrize("variables", [None, {}, {"LINTRO_AI_AUTH": "api_key"}])
def test_known_tuple_requires_exact_slot(
    consumer_scan: ModuleType,
    variables: dict[str, str] | None,
) -> None:
    """Literal selectors override unknown or conflicting variables and stay strict."""
    found = consumer_scan.review_auth_policy.findings(
        passed={"provider": "openai", "transport": "cli", "auth": "oauth"},
        secrets={"CODEX_API_KEY": "${{ secrets.OPENAI_REVIEW_API_KEY }}"},
        variables=variables,
    )
    assert_that(found).is_equal_to(
        {"error: selected review slot CODEX_AUTH_JSON is missing"},
    )


def test_known_unsupported_tuple_is_an_error(consumer_scan: ModuleType) -> None:
    """Fully known unsupported selectors cannot be repaired by repository config."""
    found = consumer_scan.review_auth_policy.findings(
        passed={"provider": "cursor", "transport": "api", "auth": "api_key"},
        secrets={"CURSOR_API_KEY": "${{ secrets.CURSOR_API_KEY }}"},
        variables={},
    )
    assert_that(found).is_equal_to(
        {"error: selected review tuple cursor/api/api_key is unsupported"},
    )
