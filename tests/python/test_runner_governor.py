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


@pytest.fixture
def governor(load_script: Callable[[str], ModuleType]) -> ModuleType:
    return load_script("scripts/ci/runners/runner_governor.py")


@pytest.fixture
def data() -> dict[str, Any]:
    return {
        name: json.loads((FIXTURES / f"{name}.json").read_text())
        for name in ("blacksmith", "github", "repositories", "contract")
    }


def decision(
    governor: ModuleType, data: dict[str, Any], bs: int = 0, gh: int = 0, **knobs: Any
) -> dict[str, str]:
    data = copy.deepcopy(data)
    data["blacksmith"]["synthetic_aggregate"]["fixture_vcpu_minutes"] = bs * 2
    data["github"]["usageItems"] = [data["github"]["usageItems"][0]]
    data["github"]["usageItems"][0]["quantity"] = gh
    return cast(
        dict[str, str],
        governor.decide(
            data["blacksmith"],
            data["github"],
            data["repositories"],
            governor.Knobs(**knobs),
            data["contract"],
            "2026-10",
        ),
    )


@pytest.mark.parametrize(
    "bs,gh,knobs,expected",
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
    bs: int,
    gh: int,
    knobs: dict[str, Any],
    expected: str,
) -> None:
    result = decision(governor, data, bs, gh, **knobs)
    assert result["desired"] == expected
    assert result["reason"]


def test_private_skus_and_public_storage_exclusion(
    governor: ModuleType, data: dict[str, Any]
) -> None:
    result = governor.decide(
        data["blacksmith"],
        data["github"],
        data["repositories"],
        governor.Knobs(),
        data["contract"],
        "2026-10",
    )
    assert Decimal(result["github_minutes"]) == 220
    assert Decimal(result["blacksmith_minutes"]) == 100


@pytest.mark.parametrize(
    "value", [None, True, False, -1, "NaN", "Infinity", "-Infinity", "bad", [], {}, "-0.01"]
)
def test_invalid_usage_never_becomes_zero(
    governor: ModuleType, data: dict[str, Any], value: Any
) -> None:
    data["blacksmith"]["synthetic_aggregate"]["fixture_vcpu_minutes"] = value
    with pytest.raises(governor.GovernorError):
        governor.decide(
            data["blacksmith"],
            data["github"],
            data["repositories"],
            governor.Knobs(mode="github"),
            data["contract"],
            "2026-10",
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
    governor: ModuleType, data: dict[str, Any], key: str, value: Any
) -> None:
    data["github"]["usageItems"][0][key] = value
    with pytest.raises(governor.GovernorError):
        governor.decide(
            data["blacksmith"],
            data["github"],
            data["repositories"],
            governor.Knobs(),
            data["contract"],
            "2026-10",
        )


@pytest.mark.parametrize(
    "metadata",
    [
        None,
        {},
        {"private": False},
        {"private": True, "visibility": "public", "full_name": "lgtm-hq/fixture-private"},
        {"private": "true", "visibility": "private", "full_name": "lgtm-hq/fixture-private"},
    ],
)
def test_unknown_visibility_fail_closed(
    governor: ModuleType, data: dict[str, Any], metadata: Any
) -> None:
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
    governor: ModuleType, data: dict[str, Any], source: str, value: Any
) -> None:
    data[source] = value
    for mode in ("auto", "github", "blacksmith"):
        with pytest.raises(governor.GovernorError):
            governor.decide(
                data["blacksmith"],
                data["github"],
                data["repositories"],
                governor.Knobs(mode=mode),
                data["contract"],
                "2026-10",
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
    governor: ModuleType, data: dict[str, Any], key: str, value: Any
) -> None:
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
    with pytest.raises((governor.GovernorError, ValueError)):
        governor.Knobs.from_env({"LGTM_CI_RUNNER_" + key: value})


def test_empty_knobs_use_defaults(governor: ModuleType) -> None:
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
def test_calendar_cycle(governor: ModuleType, timestamp: str, day: int, expected: str) -> None:
    assert governor.cycle_start(datetime.fromisoformat(timestamp), day).isoformat() == expected


class API:

    def __init__(self, value: Any = "ubuntu-26.04", visibility: str | None = "selected") -> None:
        self.value = value
        self.visibility = visibility
        self.calls: list[tuple[str, str, Any]] = []
        self.issues: list[dict[str, Any]] = []

    def request(self, path: str, method: str = "GET", body: Any = None) -> Any:
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
        return [call for call in self.calls if call[1] != "GET"]


def test_apply_value_only_and_idempotence(governor: ModuleType, data: dict[str, Any]) -> None:
    api = API()
    reporter = API()
    result = decision(governor, data)
    assert governor.apply(api, reporter, result, False) == "value changed and reported"
    assert api.writes == [(governor.VARIABLE, "PATCH", {"value": result["desired"]})]
    assert reporter.writes[0][0] == "repos/lgtm-hq/lgtm-ci/issues"
    assert governor.MARKER in reporter.writes[0][2]["body"]
    reporter.calls.clear()
    assert governor.apply(api, reporter, result, False) == "unchanged"
    assert len(api.writes) == 1
    assert not reporter.calls


def test_dry_run_no_writes(governor: ModuleType, data: dict[str, Any]) -> None:
    api = API()
    result = decision(governor, data)
    assert governor.apply(api, None, result, True) == "dry-run; no writes"
    assert not api.writes
    assert api.value == "ubuntu-26.04"


@pytest.mark.parametrize("visibility", ["all", "private", None])
def test_visibility_not_mutated(
    governor: ModuleType, data: dict[str, Any], visibility: str | None
) -> None:
    api = API(visibility=visibility)
    with pytest.raises(governor.GovernorError):
        governor.apply(api, API(), decision(governor, data), False)
    assert not api.writes


def test_marker_comment_not_pr_or_arbitrary_issue(governor: ModuleType) -> None:
    api = API()
    api.issues = [
        {"number": 1, "body": governor.MARKER, "pull_request": {}},
        {"number": 2, "body": "unrelated"},
        {"number": 3, "body": governor.MARKER},
    ]
    governor.status_issue(api, "fixture report")
    assert api.writes == [
        ("repos/lgtm-hq/lgtm-ci/issues/3/comments", "POST", {"body": "fixture report"})
    ]


def test_concurrent_override_stops_write(
    governor: ModuleType, data: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    api = API()
    original = api.request

    def request(path: str, method: str = "GET", body: Any = None) -> Any:
        if len(api.calls) == 1:
            api.value = "human-override"
        return original(path, method, body)

    monkeypatch.setattr(api, "request", request)
    with pytest.raises(governor.GovernorError, match="concurrently"):
        governor.apply(api, API(), decision(governor, data), False)
    assert not api.writes


def test_collect_github_resolves_visibility_once(
    governor: ModuleType, data: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    calls: list[Any] = []

    def request(path: str) -> Any:
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
    governor: ModuleType, monkeypatch: pytest.MonkeyPatch
) -> None:
    token = "synthetic-id|synthetic-secret"
    monkeypatch.setenv("BLACKSMITH_ORG_TOKEN", token)
    monkeypatch.setenv("BLACKSMITH_ORG", "lgtm-hq")
    monkeypatch.setenv("GH_TOKEN", "synthetic-github-token")
    calls: list[Any] = []

    def run(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        assert token not in " ".join(command)
        assert "BLACKSMITH_ORG_TOKEN" not in kwargs["env"]
        assert "GH_TOKEN" not in kwargs["env"]
        assert kwargs["env"]["BLACKSMITH_DISABLE_AUTO_UPDATE"] == "1"
        assert Path(kwargs["env"]["HOME"]).is_dir()
        calls.append((command, kwargs))
        return subprocess.CompletedProcess(command, 0, stdout='{"synthetic": 1}')

    monkeypatch.setattr(governor.subprocess, "run", run)
    now = datetime(2026, 10, 31, tzinfo=timezone.utc)
    assert governor.collect_blacksmith(governor.cycle_start(now, 1), now) == {"synthetic": 1}
    assert calls[0][1]["input"] == token
    assert "--api-token" in calls[0][0]
    assert calls[0][0][calls[0][0].index("--api-token") + 1] == "-"
    assert not Path(calls[0][1]["env"]["HOME"]).exists()
    assert "--start-time" in calls[1][0] and "--end-time" in calls[1][0]


def test_auth_failure_redacts_secret_and_cleans_home(
    governor: ModuleType, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("BLACKSMITH_ORG_TOKEN", "synthetic-id|secret")
    monkeypatch.setenv("BLACKSMITH_ORG", "lgtm-hq")
    homes: list[str] = []

    def run(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        homes.append(kwargs["env"]["HOME"])
        raise subprocess.CalledProcessError(1, command, stderr="synthetic-id|secret")

    monkeypatch.setattr(governor.subprocess, "run", run)
    now = datetime.now(timezone.utc)
    with pytest.raises(governor.GovernorError, match="unavailable"):
        governor.collect_blacksmith(now, now)
    assert not Path(homes[0]).exists()
    assert "secret" not in str(capsys.readouterr())


def test_fixture_cli_and_live_rejection(tmp_path: Path) -> None:
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
    result = subprocess.run(base + ["--live"], capture_output=True, text=True, env=env, check=False)
    assert result.returncode == 1
    assert "cannot authorize live" in result.stdout


def test_default_contract_blocks_before_network(
    governor: ModuleType, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(tmp_path / "summary"))

    def forbidden(*_args: Any, **_kwargs: Any) -> Never:
        raise AssertionError("unverified contract must block before any network")

    monkeypatch.setattr(governor, "GitHub", forbidden)
    monkeypatch.setattr(governor, "collect_blacksmith", forbidden)
    assert governor.main([]) == 1
    assert "unverified" in (tmp_path / "summary").read_text()


def test_source_failure_prevents_apply(
    governor: ModuleType, data: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(governor, "read_json", lambda _: data["contract"])
    monkeypatch.setattr(governor, "GitHub", lambda _: API())

    def unavailable(*_args: Any) -> Never:
        raise governor.GovernorError("Blacksmith usage unavailable")

    def forbidden(*_args: Any) -> Never:
        raise AssertionError("source failure must leave value untouched")

    monkeypatch.setattr(governor, "collect_blacksmith", unavailable)
    monkeypatch.setattr(governor, "apply", forbidden)
    assert governor.main([]) == 1


def test_workflow_contract() -> None:
    workflow = yaml.safe_load((ROOT / ".github/workflows/runner-governor.yml").read_text())
    assert workflow["permissions"] == {}
    assert workflow["concurrency"]["group"] == "runner-governor"
    assert workflow["on"]["workflow_dispatch"]["inputs"]["dry-run"]["default"] is True
    assert workflow["on"]["schedule"][0]["cron"].split()[0] != "0"
    job = workflow["jobs"]["governor"]
    assert job["runs-on"] == "ubuntu-26.04"
    assert "GOVERNOR_ENABLED" in job["if"]
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
    governor: ModuleType, data: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(governor, "read_json", lambda _: data["contract"])
    api = API()
    monkeypatch.setattr(governor, "GitHub", lambda _: api)
    monkeypatch.setattr(governor, "collect_blacksmith", lambda *_: data["blacksmith"])
    monkeypatch.setenv("LGTM_CI_RUNNER_MODE", "blacksmith")

    def unavailable(*_args: Any) -> Never:
        raise governor.GovernorError("GitHub usage unavailable")

    monkeypatch.setattr(governor, "collect_github", unavailable)
    assert governor.main([]) == 1
    assert not api.writes


def test_failed_setup_blocks_even_verified_contract(
    governor: ModuleType, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SETUP_READY", "false")

    def forbidden(*_args: Any, **_kwargs: Any) -> Never:
        raise AssertionError("failed setup must block all network and mutations")

    monkeypatch.setattr(governor, "GitHub", forbidden)
    assert governor.main(["--live"]) == 1


def test_live_enable_required_before_network(
    governor: ModuleType, data: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.delenv("LGTM_CI_RUNNER_GOVERNOR_ENABLED", raising=False)
    monkeypatch.setattr(governor, "read_json", lambda _: data["contract"])

    def forbidden(*_args: Any, **_kwargs: Any) -> Never:
        raise AssertionError("disabled live mode must block all network")

    monkeypatch.setattr(governor, "GitHub", forbidden)
    assert governor.main(["--live"]) == 1


def test_missing_json_and_malformed_json_fail(governor: ModuleType, tmp_path: Path) -> None:
    path = tmp_path / "source.json"
    with pytest.raises(governor.GovernorError, match="Unreadable"):
        governor.read_json(path)
    path.write_text('{"broken":')
    with pytest.raises(governor.GovernorError, match="Unreadable"):
        governor.read_json(path)


def test_status_failure_records_completed_write(
    governor: ModuleType, data: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    api = API()
    reporter = API()

    def unavailable(*_args: Any, **_kwargs: Any) -> Never:
        raise governor.GovernorError("GitHub API request failed")

    monkeypatch.setattr(reporter, "request", unavailable)
    result = decision(governor, data)
    with pytest.raises(governor.GovernorError):
        governor.apply(api, reporter, result, False)
    assert api.value == result["desired"]
    assert result["write_completed"].startswith("true")


def test_status_issue_pagination(governor: ModuleType, monkeypatch: pytest.MonkeyPatch) -> None:
    api = API()
    original = api.request

    def request(path: str, method: str = "GET", body: Any = None) -> Any:
        if "/issues?" in path and path.endswith("&page=1"):
            api.calls.append((path, method, body))
            return [{"body": "unrelated", "number": index} for index in range(100)]
        if "/issues?" in path:
            api.issues = [{"body": governor.MARKER, "number": 123}]
        return original(path, method, body)

    monkeypatch.setattr(api, "request", request)
    governor.status_issue(api, "fixture report")
    assert len(api.calls) == 3
    assert api.writes[0][0] == "repos/lgtm-hq/lgtm-ci/issues/123/comments"


def test_api_redacts_errors_and_refuses_redirects(
    governor: ModuleType, monkeypatch: pytest.MonkeyPatch
) -> None:
    api = governor.GitHub("synthetic-secret")

    def unavailable(*_args: Any, **_kwargs: Any) -> Never:
        raise OSError("synthetic-secret")

    monkeypatch.setattr(api.opener, "open", unavailable)
    with pytest.raises(governor.GovernorError) as caught:
        api.request(governor.VARIABLE)
    assert "synthetic-secret" not in str(caught.value)
    redirect = governor.NoRedirect()
    assert redirect.redirect_request(None, None, 302, "", {}, "https://other") is None


def test_governor_action_pinning_offline() -> None:
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
    mock_bin = tmp_path / "bin"
    mock_bin.mkdir()
    curl = mock_bin / "curl"
    curl.write_text(
        '#!/bin/bash\nwhile [[ "$1" != -o ]]; do shift; done\nprintf "corrupted fixture" > "$2"\n'
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
    assert not (tmp_path / "runner-governor-bin/blacksmith").exists()
    assert not (tmp_path / "path").exists()
