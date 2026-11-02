# SPDX-License-Identifier: MIT
"""Offline safety and decision tests; fixtures are explicitly synthetic."""

import copy
import json
import os
import subprocess
import sys
from collections.abc import Callable
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from types import ModuleType
from typing import Any, Never, cast

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests/fixtures/runner-governor"
SCRIPT = ROOT / "scripts/ci/runners/runner_governor.py"


@pytest.fixture(name="governor")
def fixture_governor(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the standalone governor without importing a project package."""
    return load_script("scripts/ci/runners/runner_governor.py")


@pytest.fixture(name="data")
def fixture_data() -> dict[str, Any]:
    """Read fresh synthetic inputs for each test."""
    return {
        name: json.loads((FIXTURES / f"{name}.json").read_text())
        for name in ("blacksmith", "github", "repositories", "contract")
    }


@pytest.fixture(autouse=True)
def fixture_workflow_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    """Model a successful main-branch setup unless a test overrides it."""
    monkeypatch.setenv("SETUP_READY", "true")
    monkeypatch.setenv("GITHUB_REF", "refs/heads/main")


def decision(
    governor: ModuleType,
    data: dict[str, Any],
    bs: int = 0,
    gh: int = 0,
    **knobs: Any,
) -> dict[str, str]:
    """Evaluate synthetic usage with convenient threshold overrides."""
    data = copy.deepcopy(data)
    data["blacksmith"]["synthetic_aggregate"]["fixture_vcpu_minutes"] = bs * 2
    data["github"]["usageItems"] = [data["github"]["usageItems"][0]]
    data["github"]["usageItems"][0]["quantity"] = gh
    return cast(
        dict[str, str],
        governor.decide(
            governor.Usage(
                data["blacksmith"],
                data["github"],
                data["repositories"],
                "2026-10",
            ),
            governor.Knobs(**knobs),
            data["contract"],
        ),
    )


@pytest.mark.parametrize(
    "case",
    [
        (2699, 2999, {}, "blacksmith-2vcpu-ubuntu-2604"),
        (2700, 2849, {}, "ubuntu-26.04"),
        (2700, 2850, {}, "ubuntu-26.04"),
        (2700, 2850, {"overage": "blacksmith"}, "blacksmith-2vcpu-ubuntu-2604"),
        (9999, 9999, {"mode": "blacksmith"}, "blacksmith-2vcpu-ubuntu-2604"),
        (0, 0, {"mode": "github"}, "ubuntu-26.04"),
        (0, 0, {"label": "blacksmith-4vcpu-custom"}, "blacksmith-4vcpu-custom"),
        (2700, 2850, {"budget": Decimal(2800)}, "blacksmith-2vcpu-ubuntu-2604"),
        (2700, 2850, {"included": Decimal(4000)}, "ubuntu-26.04"),
        (0, 0, {"budget": Decimal(0), "included": Decimal(0)}, "ubuntu-26.04"),
    ],
)
def test_decision_table(
    governor: ModuleType,
    data: dict[str, Any],
    case: tuple[int, int, dict[str, Any], str],
) -> None:
    """Cover threshold equality, both overages, forced modes and knobs."""
    bs, gh, knobs, expected = case
    result = decision(governor, data, bs, gh, **knobs)
    assert result["desired"] == expected
    assert result["reason"]


def test_private_skus_and_public_storage_exclusion(
    governor: ModuleType,
    data: dict[str, Any],
) -> None:
    """Count private minute SKUs while excluding public and storage usage."""
    result = governor.decide(
        governor.Usage(
            data["blacksmith"],
            data["github"],
            data["repositories"],
            "2026-10",
        ),
        governor.Knobs(),
        data["contract"],
    )
    assert Decimal(result["github_minutes"]) == 220
    assert Decimal(result["blacksmith_minutes"]) == 100


@pytest.mark.parametrize(
    "value",
    [None, True, False, -1, "NaN", "Infinity", "-Infinity", "bad", [], {}, "-0.01"],
)
def test_invalid_usage_never_becomes_zero(
    governor: ModuleType,
    data: dict[str, Any],
    value: Any,
) -> None:
    """Reject invalid usage even when a forced mode could choose a runner."""
    data["blacksmith"]["synthetic_aggregate"]["fixture_vcpu_minutes"] = value
    with pytest.raises(governor.GovernorError):
        governor.decide(
            governor.Usage(
                data["blacksmith"],
                data["github"],
                data["repositories"],
                "2026-10",
            ),
            governor.Knobs(mode="github"),
            data["contract"],
        )


@pytest.mark.parametrize(
    "key,value",
    [
        ("quantity", None),
        ("quantity", True),
        ("quantity", -1),
        ("quantity", "NaN"),
        ("sku", "unknown"),
        ("sku", None),
        ("repositoryName", None),
        ("repositoryName", "other/repo"),
        ("organizationName", "other"),
        ("date", "2026-09-30"),
        ("date", "bad"),
        ("unitType", None),
        ("product", None),
    ],
)
def test_bad_github_rows_fail(
    governor: ModuleType,
    data: dict[str, Any],
    key: str,
    value: Any,
) -> None:
    """Fail closed for untrusted attribution, dates, quantities and SKUs."""
    data["github"]["usageItems"][0][key] = value
    with pytest.raises(governor.GovernorError):
        governor.decide(
            governor.Usage(
                data["blacksmith"],
                data["github"],
                data["repositories"],
                "2026-10",
            ),
            governor.Knobs(),
            data["contract"],
        )


@pytest.mark.parametrize(
    "metadata",
    [
        None,
        {},
        {"private": False},
        {
            "private": True,
            "visibility": "public",
            "full_name": "lgtm-hq/fixture-private",
        },
        {
            "private": "true",
            "visibility": "private",
            "full_name": "lgtm-hq/fixture-private",
        },
    ],
)
def test_unknown_visibility_fail_closed(
    governor: ModuleType,
    data: dict[str, Any],
    metadata: Any,
) -> None:
    """Require consistent API metadata before counting private usage."""
    data["repositories"]["lgtm-hq/fixture-private"] = metadata
    with pytest.raises(governor.GovernorError):
        decision(governor, data)


@pytest.mark.parametrize(
    "source,value",
    [
        ("blacksmith", {}),
        ("github", {}),
        ("github", {"usageItems": None}),
        ("github", {"usageItems": [None]}),
        ("repositories", None),
        ("contract", {"verified": False}),
    ],
)
def test_unreadable_sources_in_all_modes(
    governor: ModuleType,
    data: dict[str, Any],
    source: str,
    value: Any,
) -> None:
    """Require all input sources for automatic and forced choices."""
    data[source] = value
    for mode in ("auto", "github", "blacksmith"):
        with pytest.raises(governor.GovernorError):
            governor.decide(
                governor.Usage(
                    data["blacksmith"],
                    data["github"],
                    data["repositories"],
                    "2026-10",
                ),
                governor.Knobs(mode=mode),
                data["contract"],
            )


@pytest.mark.parametrize(
    "key,value",
    [
        ("verified", False),
        ("verified", "true"),
        ("evidence", ""),
        ("blacksmith_total_path", None),
        ("blacksmith_total_path", []),
        ("blacksmith_minutes_per_unit", 0),
        ("github_sku_multipliers", {}),
        ("github_sku_multipliers", {"actions linux": -1}),
    ],
)
def test_contract_validation(
    governor: ModuleType,
    data: dict[str, Any],
    key: str,
    value: Any,
) -> None:
    """Reject incomplete or unreviewed accounting contracts."""
    data["contract"][key] = value
    with pytest.raises(governor.GovernorError):
        decision(governor, data)


@pytest.mark.parametrize(
    "key,value",
    [
        ("MODE", "bad"),
        ("OVERAGE", "bad"),
        ("BUDGET_MINUTES", "NaN"),
        ("GITHUB_INCLUDED_MINUTES", "-1"),
        ("CYCLE_DAY", "0"),
        ("CYCLE_DAY", "29"),
        ("CYCLE_DAY", "bad"),
        ("BLACKSMITH_LABEL", "ubuntu-latest"),
        ("BLACKSMITH_LABEL", "blacksmith-a\nexec"),
    ],
)
def test_invalid_knobs(governor: ModuleType, key: str, value: Any) -> None:
    """Reject unsupported modes, labels and numeric settings."""
    with pytest.raises((governor.GovernorError, ValueError)):
        governor.Knobs.from_env({"LGTM_CI_RUNNER_" + key: value})


def test_empty_knobs_use_defaults(governor: ModuleType) -> None:
    """Treat empty Actions variables as absent settings."""
    assert governor.Knobs.from_env({"LGTM_CI_RUNNER_MODE": ""}) == governor.Knobs()


@pytest.mark.parametrize(
    "timestamp,day,expected",
    [
        ("2026-11-01T00:00:00+00:00", 1, "2026-11-01T00:00:00+00:00"),
        ("2026-10-31T23:59:59+00:00", 1, "2026-10-01T00:00:00+00:00"),
        ("2027-01-01T00:00:00+00:00", 2, "2026-12-02T00:00:00+00:00"),
        ("2026-11-01T00:30:00+01:00", 1, "2026-10-01T00:00:00+00:00"),
    ],
)
def test_calendar_cycle(
    governor: ModuleType,
    timestamp: str,
    day: int,
    expected: str,
) -> None:
    """Resolve cycle boundaries in UTC, including year rollover."""
    actual = governor.cycle_start(datetime.fromisoformat(timestamp), day)
    assert actual.isoformat() == expected


class API:
    """Record offline requests and model the selected-visibility variable."""

    def __init__(
        self,
        value: Any = "ubuntu-26.04",
        visibility: str | None = "selected",
    ) -> None:
        self.value = value
        self.visibility = visibility
        self.calls: list[tuple[str, str, Any]] = []
        self.issues: list[dict[str, Any]] = []

    def request(self, path: str, method: str = "GET", body: Any = None) -> Any:
        """Record the call and serve synthetic API responses."""
        self.calls.append((path, method, body))
        if path == "orgs/lgtm-hq/actions/variables/LGTM_CI_RUNNER":
            if method == "PATCH":
                assert set(body) == {"value"}
                self.value = body["value"]
                return None
            return {"value": self.value, "visibility": self.visibility}
        if "/issues?" in path:
            return self.issues
        return {}

    @property
    def writes(self) -> list[tuple[str, str, Any]]:
        """Return only mutations so tests can prove zero writes."""
        return [call for call in self.calls if call[1] != "GET"]


def test_live_changes_blocked_without_durable_reporting(
    governor: ModuleType,
    data: dict[str, Any],
) -> None:
    """Repeated invocations cannot enter the PATCH/report loss window."""
    api, reporter = API(), API()
    for _ in range(3):
        result = decision(governor, data)
        with pytest.raises(
            governor.GovernorError,
            match="durable report reconciliation",
        ):
            governor.apply(api, reporter, result, dry_run=False)
        assert result["value_changed"] == "false"
        assert result["report_completed"] == "false"
    assert not api.writes
    assert not reporter.calls
    assert api.value == "ubuntu-26.04"


def test_initial_unchanged_is_clean_noop(
    governor: ModuleType,
    data: dict[str, Any],
) -> None:
    """Current value alone never creates a receipt or a status notification."""
    result = decision(governor, data)
    api, reporter = API(value=result["desired"]), API()
    for _ in range(3):
        assert governor.apply(api, reporter, result, dry_run=False) == "unchanged"
    assert not api.writes
    assert not reporter.calls
    assert result["value_changed"] == "false"
    assert result["report_completed"] == "false"


def test_dry_run_no_writes(governor: ModuleType, data: dict[str, Any]) -> None:
    """Preview a different desired value without touching org or status."""
    api = API()
    result = decision(governor, data)
    assert governor.apply(api, None, result, dry_run=True) == "dry-run; no writes"
    assert not api.writes
    assert api.value == "ubuntu-26.04"


@pytest.mark.parametrize("visibility", ["all", "private", None])
def test_visibility_not_mutated(
    governor: ModuleType,
    data: dict[str, Any],
    visibility: str | None,
) -> None:
    """Refuse non-selected visibility without attempting repairs."""
    api = API(visibility=visibility)
    with pytest.raises(governor.GovernorError):
        governor.apply(api, API(), decision(governor, data), dry_run=False)
    assert not api.writes


def status_record(governor: ModuleType, **overrides: Any) -> dict[str, Any]:
    """Build the identity emitted by the real status-issue creation path."""
    return {
        "number": 3,
        "body": governor.MARKER + "\n\nPrevious report",
        "title": "Runner governor status",
        "state": "open",
        "labels": [{"name": "infrastructure"}],
        **overrides,
    }


def test_marker_comment_not_pr_or_arbitrary_issue(governor: ModuleType) -> None:
    """Only the genuine status issue receives an existing-issue comment."""
    api = API()
    api.issues = [
        {**status_record(governor), "number": 1, "pull_request": {}},
        {"number": 2, "body": "unrelated"},
        status_record(governor, number=3),
    ]
    governor.status_issue(api, "fixture report")
    assert api.writes == [
        ("repos/lgtm-hq/lgtm-ci/issues/3/comments", "POST", {"body": "fixture report"})
    ]


def test_concurrent_override_stops_write(
    governor: ModuleType,
    data: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Detect a human override before proceeding toward publication."""
    api = API()
    original = api.request

    def request(path: str, method: str = "GET", body: Any = None) -> Any:
        """Record the call and serve synthetic API responses."""
        if len(api.calls) == 1:
            api.value = "human-override"
        return original(path, method, body)

    monkeypatch.setattr(api, "request", request)
    with pytest.raises(governor.GovernorError, match="concurrently"):
        governor.apply(api, API(), decision(governor, data), dry_run=False)
    assert not api.writes


def test_collect_github_resolves_visibility_once(
    governor: ModuleType,
    data: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Resolve every metered repository once, including public repos."""
    calls: list[Any] = []

    def request(path: str) -> Any:
        """Record the call and serve synthetic API responses."""
        calls.append(path)
        if path.startswith("organizations/"):
            return data["github"]
        return data["repositories"][path.removeprefix("repos/")]

    api = API()
    monkeypatch.setattr(api, "request", request)
    _, repositories = governor.collect_github(api, datetime(2026, 10, 31))
    assert calls == [
        "organizations/lgtm-hq/settings/billing/usage?year=2026&month=10",
        "repos/lgtm-hq/fixture-private",
        "repos/lgtm-hq/fixture-public",
    ]
    assert repositories == data["repositories"]


def test_stdin_auth_private_home_cleanup(
    governor: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Keep credentials off argv and delete the isolated HOME after use."""
    token = "synthetic-id|synthetic-secret"
    monkeypatch.setenv("BLACKSMITH_ORG_TOKEN", token)
    monkeypatch.setenv("BLACKSMITH_ORG", "lgtm-hq")
    monkeypatch.setenv("GH_TOKEN", "synthetic-github-token")
    calls: list[Any] = []

    def run(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        """Model the CLI without invoking a real collector."""
        assert token not in " ".join(command)
        assert "BLACKSMITH_ORG_TOKEN" not in kwargs["env"]
        assert "GH_TOKEN" not in kwargs["env"]
        assert kwargs["env"]["BLACKSMITH_DISABLE_AUTO_UPDATE"] == "1"
        assert Path(kwargs["env"]["HOME"]).is_dir()
        calls.append((command, kwargs))
        return subprocess.CompletedProcess(command, 0, stdout='{"synthetic": 1}')

    monkeypatch.setattr(governor.subprocess, "run", run)
    now = datetime(2026, 10, 31, tzinfo=timezone.utc)
    actual = governor.collect_blacksmith(governor.cycle_start(now, 1), now)
    assert actual == {"synthetic": 1}
    assert calls[0][1]["input"] == token
    assert "--api-token" in calls[0][0]
    assert calls[0][0][calls[0][0].index("--api-token") + 1] == "-"
    assert not Path(calls[0][1]["env"]["HOME"]).exists()
    assert "--start-time" in calls[1][0] and "--end-time" in calls[1][0]


def test_auth_failure_redacts_secret_and_cleans_home(
    governor: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Clean temporary credentials and omit CLI errors on auth failure."""
    monkeypatch.setenv("BLACKSMITH_ORG_TOKEN", "synthetic-id|secret")
    monkeypatch.setenv("BLACKSMITH_ORG", "lgtm-hq")
    homes: list[str] = []

    def run(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        """Model the CLI without invoking a real collector."""
        homes.append(kwargs["env"]["HOME"])
        raise subprocess.CalledProcessError(1, command, stderr="synthetic-id|secret")

    monkeypatch.setattr(governor.subprocess, "run", run)
    now = datetime.now(timezone.utc)
    with pytest.raises(governor.GovernorError, match="unavailable"):
        governor.collect_blacksmith(now, now)
    assert not Path(homes[0]).exists()
    assert "secret" not in str(capsys.readouterr())


def test_fixture_cli_and_live_rejection(tmp_path: Path) -> None:
    """Allow a standalone offline preview and reject fixture live mode."""
    env = {**os.environ, "GITHUB_STEP_SUMMARY": str(tmp_path / "summary")}
    base = [
        sys.executable,
        str(SCRIPT),
        "--fixture-dir",
        str(FIXTURES),
        "--fixture-month",
        "2026-10",
    ]
    result = subprocess.run(base, capture_output=True, text=True, env=env, check=False)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "fixture dry-run; no network or writes" in result.stdout
    assert (tmp_path / "summary").read_text() == result.stdout
    result = subprocess.run(
        base + ["--live"],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert result.returncode == 1
    assert "cannot authorize live" in result.stdout


def test_default_contract_blocks_before_network(
    governor: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """The checked-in unverified contract must block provider requests."""
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(tmp_path / "summary"))

    def forbidden(*_args: Any, **_kwargs: Any) -> Never:
        """Fail if the safety gate lets execution reach this operation."""
        raise AssertionError("unverified contract must block before any network")

    monkeypatch.setattr(governor, "GitHub", forbidden)
    monkeypatch.setattr(governor, "collect_blacksmith", forbidden)
    assert governor.main([]) == 1
    assert "unverified" in (tmp_path / "summary").read_text()


def test_source_failure_prevents_apply(
    governor: ModuleType,
    data: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Stop before apply if Blacksmith usage cannot be collected."""
    monkeypatch.setattr(governor, "read_json", lambda _: data["contract"])
    monkeypatch.setattr(governor, "GitHub", lambda _: API())

    def unavailable(*_args: Any) -> Never:
        """Model an unavailable external service without network access."""
        raise governor.GovernorError("Blacksmith usage unavailable")

    def forbidden(*_args: Any) -> Never:
        """Fail if the safety gate lets execution reach this operation."""
        raise AssertionError("source failure must leave value untouched")

    monkeypatch.setattr(governor, "collect_blacksmith", unavailable)
    monkeypatch.setattr(governor, "apply", forbidden)
    assert governor.main([]) == 1


def test_workflow_contract() -> None:
    """Pin permissions, runner, trigger and action safety invariants."""
    workflow = yaml.safe_load(
        (ROOT / ".github/workflows/runner-governor.yml").read_text(),
    )
    assert workflow["permissions"] == {}
    assert workflow["concurrency"]["group"] == "runner-governor"
    triggers = workflow.get(True, workflow.get("on"))
    assert triggers["workflow_dispatch"]["inputs"]["dry-run"]["default"] is True
    assert triggers["schedule"][0]["cron"].split()[0] != "0"
    job = workflow["jobs"]["governor"]
    assert job["runs-on"] == "ubuntu-26.04"
    assert "GOVERNOR_ENABLED" in job["if"]
    assert "github.ref == 'refs/heads/main'" in job["if"]
    steps = job["steps"]
    apply_step = next(step for step in steps if "STATUS_TOKEN" in step.get("env", {}))
    assert "inputs.dry-run" in apply_step["env"]["STATUS_TOKEN"]
    notifier = workflow["jobs"]["notify-failure"]
    assert notifier["with"]["runner-image"] == "ubuntu-26.04"
    assert "inputs.dry-run" in notifier["if"]
    assert job["permissions"] == {"contents": "read", "issues": "write"}
    assert job["steps"][0]["uses"].startswith("step-security/harden-runner@")
    assert "['runner-governor']" in job["steps"][0]["with"]["allowed-endpoints"]
    for step in job["steps"]:
        if "uses" in step:
            assert len(step["uses"].split("@")[1]) == 40
        if "run" in step:
            assert "\n" not in step["run"]


def test_github_failure_prevents_write(
    governor: ModuleType,
    data: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Stop before mutation when the GitHub billing source fails."""
    monkeypatch.setattr(governor, "read_json", lambda _: data["contract"])
    api = API()
    monkeypatch.setattr(governor, "GitHub", lambda _: api)
    monkeypatch.setattr(governor, "collect_blacksmith", lambda *_: data["blacksmith"])
    monkeypatch.setenv("LGTM_CI_RUNNER_MODE", "blacksmith")

    def unavailable(*_args: Any) -> Never:
        """Model an unavailable external service without network access."""
        raise governor.GovernorError("GitHub usage unavailable")

    monkeypatch.setattr(governor, "collect_github", unavailable)
    assert governor.main([]) == 1
    assert not api.writes


def test_failed_setup_blocks_even_verified_contract(
    governor: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Block a failed setup before any network or live mutation."""
    monkeypatch.setenv("SETUP_READY", "false")

    def forbidden(*_args: Any, **_kwargs: Any) -> Never:
        """Fail if the safety gate lets execution reach this operation."""
        raise AssertionError("failed setup must block all network and mutations")

    monkeypatch.setattr(governor, "GitHub", forbidden)
    assert governor.main(["--live"]) == 1


def test_live_enable_required_before_network(
    governor: ModuleType,
    data: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Require explicit live activation before obtaining provider data."""
    monkeypatch.delenv("LGTM_CI_RUNNER_GOVERNOR_ENABLED", raising=False)
    monkeypatch.setattr(governor, "read_json", lambda _: data["contract"])

    def forbidden(*_args: Any, **_kwargs: Any) -> Never:
        """Fail if the safety gate lets execution reach this operation."""
        raise AssertionError("disabled live mode must block all network")

    monkeypatch.setattr(governor, "GitHub", forbidden)
    assert governor.main(["--live"]) == 1


def test_missing_json_and_malformed_json_fail(
    governor: ModuleType,
    tmp_path: Path,
) -> None:
    """Reject unreadable and malformed input without dumping content."""
    path = tmp_path / "source.json"
    with pytest.raises(governor.GovernorError, match="Unreadable"):
        governor.read_json(path)
    path.write_text('{"broken":')
    with pytest.raises(governor.GovernorError, match="Unreadable"):
        governor.read_json(path)


@pytest.mark.parametrize("failure_stage", ["PATCH", "report", "interrupt"])
def test_ambiguous_failures_unreachable_until_durable_backend(
    governor: ModuleType,
    data: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
    failure_stage: str,
) -> None:
    """The safety gate prevents ambiguous writes; this is not recovery proof."""
    api, reporter = API(), API()
    original = api.request

    def request(path: str, method: str = "GET", body: Any = None) -> Any:
        """Model a server accepting PATCH before losing the response."""
        response = original(path, method, body)
        if method == "PATCH":
            if failure_stage == "PATCH":
                raise governor.GovernorError("ambiguous PATCH")
            if failure_stage == "interrupt":
                raise KeyboardInterrupt
        return response

    def unavailable(*_args: Any, **_kwargs: Any) -> Never:
        """A report failure must never follow an unjournaled value change."""
        raise governor.GovernorError("ambiguous report")

    monkeypatch.setattr(api, "request", request)
    monkeypatch.setattr(reporter, "request", unavailable)
    for _ in range(2):
        result = decision(governor, data)
        with pytest.raises(
            governor.GovernorError,
            match="durable report reconciliation",
        ):
            governor.apply(api, reporter, result, dry_run=False)
        assert result["value_changed"] == "false"
        assert result["report_completed"] == "false"
    assert not api.writes
    assert api.value == "ubuntu-26.04"


def test_status_issue_pagination(
    governor: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Scan subsequent issue pages before considering creation."""
    api = API()
    original = api.request

    def request(path: str, method: str = "GET", body: Any = None) -> Any:
        """Record the call and serve synthetic API responses."""
        if "/issues?" in path and path.endswith("&page=1"):
            api.calls.append((path, method, body))
            return [{"body": "unrelated", "number": index} for index in range(100)]
        if "/issues?" in path:
            api.issues = [status_record(governor, number=123)]
        return original(path, method, body)

    monkeypatch.setattr(api, "request", request)
    governor.status_issue(api, "fixture report")
    assert len(api.calls) == 3
    assert api.writes[0][0] == "repos/lgtm-hq/lgtm-ci/issues/123/comments"


def test_api_redacts_errors_and_refuses_redirects(
    governor: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Redact credentials and refuse forwarding tokens to redirect hosts."""
    api = governor.GitHub("synthetic-secret")

    def unavailable(*_args: Any, **_kwargs: Any) -> Never:
        """Model an unavailable external service without network access."""
        raise OSError("synthetic-secret")

    monkeypatch.setattr(api.opener, "open", unavailable)
    with pytest.raises(governor.GovernorError) as caught:
        api.request(governor.VARIABLE)
    assert "synthetic-secret" not in str(caught.value)
    redirect = governor.NoRedirect()
    assert redirect.redirect_request(None, None, 302, "", {}, "https://other") is None


def test_governor_action_pinning_offline() -> None:
    """Validate the governor action pins without tag or transitive reads."""
    env = {
        **os.environ,
        "INPUT_SCAN_PATHS": ".github/workflows/runner-governor.yml",
        "INPUT_VERIFY_TAGS": "false",
        "INPUT_AUDIT_TRANSITIVE": "false",
    }
    result = subprocess.run(
        ["bash", "scripts/ci/actions/validate-action-pinning.sh"],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_installer_rejects_wrong_bytes_without_escape_hatch(tmp_path: Path) -> None:
    """Reach checksum verification on a supported platform and reject corruption."""
    mock_bin = tmp_path / "bin"
    mock_bin.mkdir()
    uname = mock_bin / "uname"
    uname.write_text(
        '#!/bin/bash\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; esac\n',
    )
    uname.chmod(0o755)
    curl = mock_bin / "curl"
    curl.write_text(
        "#!/bin/bash\n"
        # Stop before the output path, then write corrupt bytes for verification.
        'while [[ "$1" != -o ]]; do shift; done\n'
        'printf "corrupted fixture" > "$2"\n',
    )
    curl.chmod(493)
    env = {
        **os.environ,
        "PATH": str(mock_bin) + os.pathsep + os.environ["PATH"],
        "RUNNER_TEMP": str(tmp_path),
        "GITHUB_PATH": str(tmp_path / "path"),
        "LGTM_CI_ALLOW_UNVERIFIED": "1",
    }
    result = subprocess.run(
        ["bash", "scripts/ci/runners/install-blacksmith.sh"],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0
    assert "checksum" in result.stderr.lower(), result.stderr
    assert "requires Linux x64" not in result.stderr
    assert not (tmp_path / "runner-governor-bin/blacksmith").exists()
    assert not (tmp_path / "path").exists()


@pytest.mark.parametrize(
    "overrides",
    [
        {
            "body": "## Summary\n\nReporting, modeled on the registry-health script:\n"
            "On every change, comment on a single long-lived status issue found by "
            "the hidden marker `<!-- lgtm-ci:runner-governor -->`, creating it if "
            "missing (label `infrastructure`).",
            "number": 1232,
        },
        {"body": "> <!-- lgtm-ci:runner-governor -->\nQuoted status"},
        {"body": "`<!-- lgtm-ci:runner-governor -->`"},
        {"body": "<!-- lgtm-ci:runner-governor --> incidental suffix"},
        {"state": "closed"},
        {"labels": []},
        {"title": "Feature request quoting status marker"},
    ],
)
def test_incidental_or_closed_issue_cannot_capture_reports(
    governor: ModuleType,
    overrides: dict[str, Any],
) -> None:
    """Issue-like prose, quotes and closed status issues create no false match."""
    api = API()
    api.issues = [status_record(governor, **overrides)]
    governor.status_issue(api, "value changed and reported")
    assert api.writes == [
        (
            "repos/lgtm-hq/lgtm-ci/issues",
            "POST",
            {
                "title": "Runner governor status",
                "body": governor.MARKER + "\n\nvalue changed and reported",
                "labels": ["infrastructure"],
            },
        )
    ]
    assert all("state=open" in path for path, method, _ in api.calls if method == "GET")


@pytest.mark.parametrize("prefix", ["", "\n", " \n\t"])
def test_leading_marker_controls(governor: ModuleType, prefix: str) -> None:
    """Allow leading whitespace on a genuine labeled status issue."""
    api = API()
    api.issues = [status_record(governor, body=prefix + governor.MARKER + "\nReport")]
    governor.status_issue(api, "value changed and reported")
    assert api.writes == [
        (
            "repos/lgtm-hq/lgtm-ci/issues/3/comments",
            "POST",
            {
                "body": "value changed and reported",
            },
        )
    ]


@pytest.mark.parametrize("value", [None, "", "false", "TRUE", "success"])
def test_setup_requires_exact_true(
    governor: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    value: str | None,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Fail workflow setup closed for unset, empty and unrecognized values."""
    if value is None:
        monkeypatch.delenv("SETUP_READY")
    else:
        monkeypatch.setenv("SETUP_READY", value)
    assert governor.main([]) == 1
    assert "setup failed" in capsys.readouterr().out


@pytest.mark.parametrize("ref", [None, "", "refs/heads/feature", "refs/tags/v1"])
def test_workflow_ref_requires_main(
    governor: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    ref: str | None,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Refuse credential-bearing network runs outside the main branch."""
    if ref is None:
        monkeypatch.delenv("GITHUB_REF")
    else:
        monkeypatch.setenv("GITHUB_REF", ref)
    assert governor.main([]) == 1
    assert "require refs/heads/main" in capsys.readouterr().out


def test_fixture_mode_needs_no_workflow_setup(
    governor: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Offline fixture previews remain usable outside Actions."""
    monkeypatch.delenv("SETUP_READY")
    monkeypatch.delenv("GITHUB_REF")
    assert (
        governor.main(
            [
                "--fixture-dir",
                str(FIXTURES),
                "--fixture-month",
                "2026-10",
            ],
        )
        == 0
    )
    assert "fixture dry-run; no network or writes" in capsys.readouterr().out


def test_http_exception_writes_redacted_failure_summary(
    governor: ModuleType,
    data: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """An incomplete HTTP response fails closed and still writes the summary."""
    api = governor.GitHub("synthetic-secret")

    def incomplete(*_args: Any, **_kwargs: Any) -> Never:
        """Model a truncated HTTP response without revealing its contents."""
        raise governor.http.client.IncompleteRead(b"synthetic-secret")

    monkeypatch.setattr(api.opener, "open", incomplete)
    monkeypatch.setattr(governor, "GitHub", lambda _: api)
    monkeypatch.setattr(governor, "read_json", lambda _: data["contract"])
    monkeypatch.setattr(governor, "collect_blacksmith", lambda *_: data["blacksmith"])
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(tmp_path / "summary"))
    assert governor.main([]) == 1
    report = (tmp_path / "summary").read_text()
    assert "GitHub API request failed" in report
    assert "synthetic-secret" not in report


@pytest.mark.parametrize("platform", ["Darwin/x86_64", "Linux/aarch64"])
def test_installer_platform_guard(tmp_path: Path, platform: str) -> None:
    """Unsupported platforms stop before download and checksum verification."""
    mock_bin = tmp_path / "bin"
    mock_bin.mkdir()
    system, machine = platform.split("/")
    uname = mock_bin / "uname"
    uname.write_text(
        f'#!/bin/bash\ncase "$1" in -s) echo {system};; -m) echo {machine};; esac\n',
    )
    uname.chmod(0o755)
    curl = mock_bin / "curl"
    curl.write_text('#!/bin/bash\necho "download must not run" >&2\nexit 99\n')
    curl.chmod(0o755)
    result = subprocess.run(
        ["bash", "scripts/ci/runners/install-blacksmith.sh"],
        cwd=ROOT,
        env={**os.environ, "PATH": str(mock_bin) + os.pathsep + os.environ["PATH"]},
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    assert "requires Linux x64" in result.stderr
    assert "download must not run" not in result.stderr
