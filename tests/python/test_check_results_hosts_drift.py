# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/maintenance/check-results-hosts-drift.py`` (#1498).

The fixture is a trimmed copy of a real ``GET /meta`` response. Its
``.domains.actions`` additionally carries a package registry blob host and a
look-alike results host, both of which the check must ignore.
"""

from __future__ import annotations

import io
import json
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/maintenance/check-results-hosts-drift.py"
FIXTURE = Path("results-hosts-drift/meta.json")


@pytest.fixture(name="drift")
def fixture_drift(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the drift check without running it."""
    return load_script(SCRIPT_PATH)


@pytest.fixture(name="meta")
def fixture_meta(fixtures_dir: Path) -> dict[str, Any]:
    """Return a fresh copy of the ``/meta`` fixture."""
    result: dict[str, Any] = json.loads((fixtures_dir / FIXTURE).read_text("utf-8"))
    return result


def _host(shard: int) -> str:
    """Return the results storage host for one shard number."""
    return f"productionresultssa{shard}.blob.core.windows.net"


def _run(
    drift: ModuleType,
    meta: Any,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> tuple[int, str, str, Path]:
    """Run the CLI on a /meta document written to a file.

    Returns:
        Exit code, stdout, stderr and the issue-body path.
    """
    meta_file = tmp_path / "meta.json"
    meta_file.write_text(json.dumps(meta), encoding="utf-8")
    body = tmp_path / "body.md"
    code = drift.main(argv=["--meta", str(meta_file), "--issue-body", str(body)])
    captured = capsys.readouterr()
    return code, captured.out, captured.err, body


def test_fixture_matches_preset(
    drift: ModuleType,
    meta: dict[str, Any],
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The fixture lists exactly the preset hosts: exit 0, no issue body."""
    code, out, err, body = _run(drift, meta, tmp_path, capsys)

    assert_that(code).is_equal_to(0)
    assert_that(out).is_empty()
    assert_that(err).contains("match")
    assert_that(body.exists()).is_false()


def test_expected_list_comes_from_the_preset_function(drift: ModuleType) -> None:
    """The expected hosts are the function's output, without the port."""
    completed = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1" && egress_github_results_storage_endpoints',
            "_",
            str(drift.PRESETS),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    lines = completed.stdout.splitlines()
    function_hosts = {line.removesuffix(":443") for line in lines}

    assert_that(drift.expected_results_hosts()).is_equal_to(function_hosts)


def test_added_shard_is_reported(
    drift: ModuleType,
    meta: dict[str, Any],
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A shard /meta lists but the preset lacks is reported as added."""
    meta["domains"]["actions"].append(_host(200))

    code, out, err, body = _run(drift, meta, tmp_path, capsys)

    assert_that(code).is_equal_to(1)
    assert_that(out.splitlines()).is_equal_to([f"+ {_host(200)}"])
    assert_that(err).contains("1 added, 0 removed")
    text = body.read_text("utf-8")
    assert_that(text).starts_with(drift.ISSUE_MARKER)
    assert_that(text).contains(f"- `{_host(200)}`")
    for target in (
        "egress_github_results_storage_endpoints",
        "examples/publish-python-release.yml",
        "docs/workflow-contract.md",
        "sync-workflow-presets.sh",
    ):
        assert_that(text).contains(target)


def test_removed_shard_is_reported(
    drift: ModuleType,
    meta: dict[str, Any],
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A shard the preset allows but /meta dropped is reported as removed."""
    meta["domains"]["actions"].remove(_host(13))

    code, out, _, body = _run(drift, meta, tmp_path, capsys)

    assert_that(code).is_equal_to(1)
    assert_that(out.splitlines()).is_equal_to([f"- {_host(13)}"])
    text = body.read_text("utf-8")
    added = text.split("## Added in /meta")[1].split("## Removed")[0]
    assert_that(added).contains("- none")
    assert_that(text.split("## Removed from /meta")[1]).contains(f"- `{_host(13)}`")


def test_added_and_removed_are_in_shard_order(drift: ModuleType) -> None:
    """Hosts sort numerically, as /meta lists them, not lexically."""
    result = drift.compare({_host(2), _host(100), _host(30)}, {_host(1)})

    assert_that(result.added).is_equal_to((_host(2), _host(30), _host(100)))
    assert_that(result.removed).is_equal_to((_host(1),))


def test_other_blob_hosts_are_ignored(drift: ModuleType, meta: dict[str, Any]) -> None:
    """Registry blob hosts and look-alike names are not results shards."""
    actions = meta["domains"]["actions"]
    assert_that(actions).contains(
        "npmregistryv2prod.blob.core.windows.net",
        "productionresultssa7.blob.core.windows.net.example.com",
    )
    assert_that(meta["domains"]["packages"]).contains(
        "npmregistryv2prod.blob.core.windows.net",
    )
    meta["domains"]["actions"].append("productionresultssa999.blob.core.windows.net:443")

    hosts = drift.meta_results_hosts(meta)

    assert_that(hosts).is_equal_to(drift.expected_results_hosts())


@pytest.mark.parametrize(
    ("document", "message"),
    [
        ([], "not a JSON object"),
        ({}, "no `domains` object"),
        ({"domains": []}, "no `domains` object"),
        ({"domains": {}}, "`domains.actions` is missing"),
        ({"domains": {"actions": "github.com"}}, "`domains.actions` is missing"),
        ({"domains": {"actions": ["github.com", 7]}}, "non-string entry"),
        ({"domains": {"actions": ["github.com"]}}, "no productionresultssa"),
    ],
)
def test_unrecognised_shape_fails_closed(
    drift: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    document: Any,
    message: str,
) -> None:
    """An unrecognised /meta shape is an error (2), never a match or a diff."""
    code, out, err, body = _run(drift, document, tmp_path, capsys)

    assert_that(code).is_equal_to(2)
    assert_that(out).is_empty()
    assert_that(err).contains(message)
    assert_that(body.exists()).is_false()


def test_invalid_json_fails_closed(
    drift: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Input that is not JSON is an error, read here from stdin."""
    monkeypatch.setattr(sys, "stdin", io.StringIO("<html>rate limited</html>"))

    code = drift.main(argv=["--meta", "-"])

    assert_that(code).is_equal_to(2)
    assert_that(capsys.readouterr().err).contains("not valid JSON")


def test_preset_failure_fails_closed(
    drift: ModuleType,
    meta: dict[str, Any],
    tmp_path: Path,
) -> None:
    """A presets file whose function fails or prints junk is an error."""
    broken = tmp_path / "presets.sh"
    broken.write_text(
        "egress_github_results_storage_endpoints() {\n"
        "  echo '*.blob.core.windows.net:443'\n"
        "}\n",
        encoding="utf-8",
    )

    with pytest.raises(drift.DriftCheckError, match="printed"):
        drift.expected_results_hosts(broken)
    with pytest.raises(drift.DriftCheckError, match="failed"):
        drift.expected_results_hosts(tmp_path / "missing.sh")
    assert_that(drift.meta_results_hosts(meta)).is_not_empty()


def test_cli_reads_stdin(
    meta: dict[str, Any],
) -> None:
    """The script runs as a CLI with /meta on stdin."""
    script = Path(__file__).resolve().parents[2] / SCRIPT_PATH
    completed = subprocess.run(
        [sys.executable, str(script), "--meta", "-"],
        input=json.dumps(meta),
        capture_output=True,
        text=True,
        check=False,
    )

    assert_that(completed.returncode).is_equal_to(0)


def test_undecodable_meta_fails_closed(
    drift: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A /meta file that is not UTF-8 is an error (2), never a difference (1)."""
    meta_file = tmp_path / "meta.json"
    meta_file.write_bytes(b"\xff\xfe{not utf-8")
    body = tmp_path / "body.md"

    code = drift.main(argv=["--meta", str(meta_file), "--issue-body", str(body)])

    assert_that(code).is_equal_to(2)
    assert_that(capsys.readouterr().err).contains("could not read /meta")
    assert_that(body.exists()).is_false()


def test_unexpected_exception_exits_two(
    drift: ModuleType,
    meta: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Any unexpected exception exits 2, never Python's default 1 ("drift")."""

    def _boom(*_args: object) -> None:
        raise RuntimeError("boom")

    monkeypatch.setattr(drift, "compare", _boom)

    code, _, err, body = _run(drift, meta, tmp_path, capsys)

    assert_that(code).is_equal_to(2)
    assert_that(err).contains("drift check failed").contains("boom")
    assert_that(body.exists()).is_false()
