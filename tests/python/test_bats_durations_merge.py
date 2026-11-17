# SPDX-License-Identifier: MIT
"""Tests for ``scripts/ci/actions/bats-durations.py merge`` and its workflow steps.

Every test merges a two-shard run: commit ``abc123``, run 42, attempt 3.
"""

from __future__ import annotations

import json
import os
from collections.abc import Callable, Sequence
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
import yaml
from assertpy import assert_that

SCRIPT_PATH = "scripts/ci/actions/bats-durations.py"
WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
MAIN_ONLY = (
    "github.event_name == 'push' && github.ref == "
    "format('refs/heads/{0}', github.event.repository.default_branch) "
    "&& !github.event.repository.fork"
)


@pytest.fixture(name="mod")
def fixture_mod(load_script: Callable[[str], ModuleType]) -> ModuleType:
    """Load the hyphenated script as a module."""
    return load_script(SCRIPT_PATH)


def _shard_doc(
    index: int,
    durations: dict[str, Any],
    missing: Sequence[str] = (),
    **fields: Any,
) -> dict[str, Any]:
    """Build a shard document as the shard command writes it.

    Args:
        index: Shard index.
        durations: Seconds per path.
        missing: Paths without a duration.
        **fields: Fields to override.

    Returns:
        The document; each file has one test.
    """
    document = {
        "schema_version": 1,
        "sha": "abc123",
        "run_id": 42,
        "run_attempt": 3,
        "shard_index": index,
        "shard_total": 2,
        "bats_version": "1.14.0",
        "wall_seconds": 10.0 + index,
        "test_counts": dict.fromkeys([*durations, *missing], 1),
        "durations": durations,
        "missing": list(missing),
    }
    document.update(fields)
    return document


def _put(root: Path, name: str, content: object) -> Path:
    """Write a shard file under ``root/<name>/`` (raw text or JSON)."""
    target = root / name / "bats-durations-shard.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    text = content if isinstance(content, str) else json.dumps(content)
    target.write_text(text, encoding="utf-8")
    return target


def _merge_argv(shard_dir: Path, output: Path, **extra: str) -> list[str]:
    """Build a ``merge`` command line for run 42, attempt 3, two shards."""
    argv = ["merge", "--dir", str(shard_dir), "--shard-total", "2"]
    argv += ["--sha", "abc123", "--run-id", "42", "--run-attempt", "3"]
    argv += ["--output", str(output)]
    for key, value in extra.items():
        argv += [f"--{key.replace('_', '-')}", value]
    return argv


def _test_tree(root: Path, names: Sequence[str]) -> None:
    """Create empty .bats files (plus a non-.bats file) under root/tests."""
    for name in names:
        target = root / "tests" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("", encoding="utf-8")
    (root / "tests" / "helper.bash").write_text("", encoding="utf-8")


def _repo(root: Path, *names: str) -> dict[str, str]:
    """Create the run's test files under ``root/repo/tests``.

    Returns:
        The ``merge`` arguments that point at them.
    """
    _test_tree(root / "repo", names)
    return {"root": str(root / "repo"), "test_path": "tests"}


def _read(path: Path) -> dict[str, Any]:
    """Read a JSON document."""
    document: dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))
    return document


def _indexes(document: dict[str, Any]) -> list[int]:
    """Return the shard indexes a merged document kept."""
    return [shard["index"] for shard in document["shards"]]


def test_merge_writes_sorted_deterministic_output(
    mod: ModuleType,
    tmp_path: Path,
) -> None:
    """Two shards merge into one sorted document, byte-identical on re-run."""
    _test_tree(tmp_path / "repo", ["a.bats", "sub/b.bats", "c.bats"])
    shards = tmp_path / "shards"
    _put(shards, "p-test-results-m-shard-1", _shard_doc(1, {"tests/sub/b.bats": 2.5}))
    _put(
        shards,
        "p-test-results-m-shard-0",
        _shard_doc(0, {"tests/c.bats": 1, "tests/a.bats": 0.25}),
    )
    first = tmp_path / "first.json"
    second = tmp_path / "second.json"
    extra = {"root": str(tmp_path / "repo"), "test_path": "tests"}

    assert_that(mod.main(_merge_argv(shards, first, **extra))).is_equal_to(0)
    assert_that(mod.main(_merge_argv(shards, second, **extra))).is_equal_to(0)

    text = first.read_text(encoding="utf-8")
    assert_that(second.read_text(encoding="utf-8")).is_equal_to(text)
    assert_that(json.loads(text)).is_equal_to(
        {
            "schema_version": 1,
            "sha": "abc123",
            "run_id": 42,
            "run_attempt": 3,
            "shard_total": 2,
            "bats_version": "1.14.0",
            "shards": [
                {
                    "index": 0,
                    "run_attempt": 3,
                    "wall_seconds": 10.0,
                    "files": ["tests/a.bats", "tests/c.bats"],
                    "tests": 2,
                },
                {
                    "index": 1,
                    "run_attempt": 3,
                    "wall_seconds": 11.0,
                    "files": ["tests/sub/b.bats"],
                    "tests": 1,
                },
            ],
            "test_counts": {
                "tests/a.bats": 1,
                "tests/c.bats": 1,
                "tests/sub/b.bats": 1,
            },
            "durations": {
                "tests/a.bats": 0.25,
                "tests/c.bats": 1.0,
                "tests/sub/b.bats": 2.5,
            },
            "missing": [],
        },
    )
    canonical = json.dumps(json.loads(text), indent=2, sort_keys=True) + "\n"
    assert_that(text).is_equal_to(canonical)


def test_merge_reports_files_no_shard_ran(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Unreported and shard-reported files are listed missing, never invented."""
    _test_tree(tmp_path / "repo", ["a.bats", "b.bats", "c.bats"])
    shards = tmp_path / "shards"
    _put(shards, "s0", _shard_doc(0, {"tests/a.bats": 1.5}, ["tests/b.bats"]))
    output = tmp_path / "merged.json"
    extra = {"root": str(tmp_path / "repo"), "test_path": "tests"}

    mod.main(_merge_argv(shards, output, **extra))

    document = _read(output)
    assert_that(document["durations"]).is_equal_to({"tests/a.bats": 1.5})
    assert_that(document["missing"]).is_equal_to(["tests/b.bats", "tests/c.bats"])
    assert_that(_indexes(document)).is_equal_to([0])
    printed = capsys.readouterr().out
    assert_that(printed).contains(
        "::warning::bats-durations: no durations from shard(s) 1",
    )
    assert_that(printed).contains(
        "2 file(s) without a duration: tests/b.bats, tests/c.bats",
    )


def test_merge_with_a_working_directory_prefix(
    mod: ModuleType,
    tmp_path: Path,
) -> None:
    """Keys and the expected list are both relative to the repo root."""
    _test_tree(tmp_path / "pkg", ["a.bats"])
    shards = tmp_path / "shards"
    _put(shards, "s0", _shard_doc(0, {"pkg/tests/a.bats": 1}))
    _put(shards, "s1", _shard_doc(1, {}))
    output = tmp_path / "merged.json"
    extra = {
        "root": str(tmp_path / "pkg"),
        "test_path": "tests",
        "path_prefix": "pkg",
    }

    mod.main(_merge_argv(shards, output, **extra))

    document = _read(output)
    assert_that(document["durations"]).is_equal_to({"pkg/tests/a.bats": 1.0})
    assert_that(document["missing"]).is_empty()


_BAD_A = {"tests/a.bats": 1}
_OVERFLOW_DURATIONS = {"tests/a.bats": "OVERFLOW"}


def _bad(**fields: Any) -> dict[str, Any]:
    """Return a shard 0 document for tests/a.bats with fields overridden."""
    return _shard_doc(0, _BAD_A) | fields


_OVERFLOW_DOC = _shard_doc(0, _OVERFLOW_DURATIONS)


@pytest.mark.parametrize(
    ("content", "reason"),
    [
        pytest.param("", "Expecting value", id="empty"),
        pytest.param('{"schema_version": 1, "shard_ind', "Unterminated", id="cut"),
        pytest.param("not json", "Expecting value", id="malformed"),
        pytest.param([], "not a JSON object", id="not-an-object"),
        pytest.param(
            _shard_doc(0, _BAD_A, schema_version=2),
            "schema_version is not 1",
            id="schema",
        ),
        pytest.param(_bad(schema_version=True), "schema_version is not", id="true"),
        pytest.param(
            json.dumps(_OVERFLOW_DOC).replace('"OVERFLOW"', "1" + "0" * 400),
            "durations",
            id="overflow",
        ),
        pytest.param(
            json.dumps(_OVERFLOW_DOC).replace('"OVERFLOW"', "1e400"),
            "durations",
            id="float-overflow",
        ),
        pytest.param(
            json.dumps(_OVERFLOW_DOC).replace('"OVERFLOW"', "NaN"),
            "durations",
            id="nan",
        ),
        pytest.param("[" * 100_000, "while decoding", id="deep"),
        pytest.param(_shard_doc(0, {"tests/a.bats": True}), "durations", id="bool"),
        pytest.param(_shard_doc(0, {"tests/a.bats": -1}), "durations", id="negative"),
        pytest.param(_shard_doc(0, {"tests/a.bats": "1"}), "durations", id="text"),
        pytest.param(_bad(shard_index="0"), "shard_index", id="index"),
        pytest.param(_bad(run_id="42"), "run_id is not", id="run-id"),
        pytest.param(_bad(missing="x"), "missing is not", id="miss"),
        pytest.param(_bad(test_counts={"tests/a.bats": 1.5}), "test_counts is", id="t"),
        pytest.param(_bad(test_counts={}), "do not split", id="untested"),
        pytest.param(_bad(wall_seconds="9"), "wall_seconds", id="wall"),
        pytest.param(_bad(bats_version=1), "bats_version", id="ver"),
        pytest.param(_bad(sha=None), "sha is not", id="sha-type"),
        pytest.param(_bad(sha="def456"), "sha is 'def456'", id="sha"),
        pytest.param(_bad(run_id=41), "run_id is 41", id="run"),
        pytest.param(_bad(run_attempt=4), "run_attempt 4 is not between", id="later"),
        pytest.param(_bad(run_attempt=0), "run_attempt 0 is not between", id="zero"),
        pytest.param(_bad(shard_total=4), "shard_total is 4", id="n"),
        pytest.param(_bad(shard_index=2), "shard_index 2 is out of range", id="range"),
    ],
)
def test_merge_drops_a_bad_shard_document(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    content: object,
    reason: str,
) -> None:
    """A bad or foreign shard file is dropped; the run's other files are missing."""
    shards = tmp_path / "shards"
    bad = _put(shards, "bad", content)
    _put(shards, "good", _shard_doc(1, {"tests/b.bats": 2}))
    output = tmp_path / "merged.json"

    extra = _repo(tmp_path, "a.bats", "b.bats")

    code = mod.main(_merge_argv(shards, output, **extra))

    assert_that(code).is_equal_to(0)
    assert_that(capsys.readouterr().out).contains(
        f"::warning::bats-durations: dropped shard durations {bad}: ",
    ).contains(reason)
    document = _read(output)
    assert_that(document["durations"]).is_equal_to({"tests/b.bats": 2.0})
    assert_that(_indexes(document)).is_equal_to([1])
    assert_that(document["missing"]).is_equal_to(["tests/a.bats"])


def test_merge_drops_both_copies_of_a_shard_index(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Two documents for shard 0: neither is trusted, never the larger kept."""
    shards = tmp_path / "shards"
    _put(shards, "a", _shard_doc(0, {"tests/a.bats": 1.0}))
    _put(shards, "b", _shard_doc(0, {"tests/a.bats": 3.0}))
    _put(shards, "c", _shard_doc(1, {"tests/c.bats": 2.0}))
    output = tmp_path / "merged.json"

    mod.main(_merge_argv(shards, output, **_repo(tmp_path, "a.bats", "c.bats")))

    document = _read(output)
    assert_that(document["durations"]).is_equal_to({"tests/c.bats": 2.0})
    assert_that(document["missing"]).is_equal_to(["tests/a.bats"])
    assert_that(_indexes(document)).is_equal_to([1])
    printed = capsys.readouterr().out
    assert_that(printed.count("appears twice in attempt 3")).is_equal_to(2)


def test_merge_drops_shards_that_share_a_file(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A file in two shards: both documents are dropped, their files missing."""
    shards = tmp_path / "shards"
    _put(shards, "a", _shard_doc(0, {"tests/a.bats": 1.0, "tests/x.bats": 1.0}))
    _put(shards, "b", _shard_doc(1, {"tests/a.bats": 3.0}, ["tests/y.bats"]))
    output = tmp_path / "merged.json"
    extra = _repo(tmp_path, "a.bats", "x.bats", "y.bats")

    mod.main(_merge_argv(shards, output, **extra))

    assert_that(output.exists()).is_false()
    printed = capsys.readouterr().out
    shared = "tests/a.bats is reported by more than one shard"
    assert_that(printed.count(shared)).is_equal_to(2)
    assert_that(printed).contains("nothing to publish")


def test_merge_keeps_no_bats_version_when_shards_disagree(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Two bats versions in one run: null and a warning."""
    shards = tmp_path / "shards"
    _put(shards, "a", _shard_doc(0, {"tests/a.bats": 1.0}))
    _put(shards, "b", _shard_doc(1, {"tests/b.bats": 1.0}, bats_version="1.13.0"))
    output = tmp_path / "merged.json"

    mod.main(_merge_argv(shards, output, **_repo(tmp_path, "a.bats", "b.bats")))

    assert_that(_read(output)["bats_version"]).is_none()
    assert_that(capsys.readouterr().out).contains(
        "shards ran different bats versions: 1.13.0, 1.14.0",
    )


def test_merge_without_data_writes_nothing(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """No shard file (lost artifacts): warning, exit 0, an old output removed."""
    output = tmp_path / "merged.json"
    output.write_text('{"stale": true}', encoding="utf-8")

    extra = _repo(tmp_path, "a.bats")

    code = mod.main(_merge_argv(tmp_path / "absent", output, **extra))

    assert_that(code).is_equal_to(0)
    assert_that(output.exists()).is_false()
    printed = capsys.readouterr().out
    assert_that(printed).contains("no durations from shard(s) 0, 1")
    assert_that(printed).contains("nothing to publish")


def test_merge_survives_an_output_it_cannot_remove(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """An output path that is a directory: warning and exit 0."""
    output = tmp_path / "merged.json"
    output.mkdir()

    assert_that(mod.main(_merge_argv(tmp_path, output))).is_equal_to(0)

    assert_that(capsys.readouterr().out).contains(
        "::warning::bats-durations: merge failed: ",
    )


def test_expected_files_single_file_and_absent_path(
    mod: ModuleType,
    tmp_path: Path,
) -> None:
    """A test-path that is one file lists it; an absent one is an error."""
    _test_tree(tmp_path, ["a.bats"])

    single = mod.expected_files(tmp_path, ".", "tests/a.bats")

    assert_that(single).is_equal_to({"tests/a.bats"})
    with pytest.raises(mod.DurationsError, match="not found"):
        mod.expected_files(tmp_path, ".", "nope")


def test_merge_with_an_absent_test_path_publishes_nothing(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Without the run's files no shard path can be checked: no file, and why."""
    summary = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    shards = tmp_path / "shards"
    _put(shards, "s0", _shard_doc(0, {"tests/a.bats": 1}))
    _put(shards, "s1", _shard_doc(1, {}))
    output = tmp_path / "merged.json"

    code = mod.main(_merge_argv(shards, output, root=str(tmp_path), test_path="nope"))

    assert_that(code).is_equal_to(0)
    assert_that(output.exists()).is_false()
    assert_that(capsys.readouterr().out).contains(
        f"::warning::bats-durations: test path nope not found under {tmp_path}; "
        "nothing to publish",
    )
    assert_that(summary.read_text(encoding="utf-8")).is_equal_to(
        "### BATS durations\n\n"
        "- Nothing was published: test path nope not found under "
        f"{str(tmp_path).replace('_', chr(92) + '_')}.\n\n",
    )


@pytest.mark.parametrize(
    "argv",
    [
        pytest.param(["--run-id", "local"], id="text-run-id"),
        pytest.param(["--run-attempt", "x"], id="text-attempt"),
        pytest.param(["--shard-total", "0"], id="zero-shards"),
    ],
)
def test_merge_rejects_bad_arguments(
    mod: ModuleType,
    tmp_path: Path,
    argv: list[str],
) -> None:
    """run_id and run_attempt are integers: anything else is a usage error."""
    with pytest.raises(SystemExit) as exit_info:
        mod.main(_merge_argv(tmp_path, tmp_path / "m.json") + argv)

    assert_that(exit_info.value.code).is_equal_to(2)


# --- re-runs -----------------------------------------------------------------


def test_merge_keeps_shards_an_earlier_attempt_measured(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """After "Re-run failed jobs": shard 0 from attempt 1, shard 1 re-run in 3."""
    shards = tmp_path / "shards"
    _put(shards, "s0", _shard_doc(0, {"tests/a.bats": 1.0}, run_attempt=1))
    _put(shards, "s1", _shard_doc(1, {"tests/b.bats": 2.0}))
    output = tmp_path / "merged.json"

    mod.main(_merge_argv(shards, output, **_repo(tmp_path, "a.bats", "b.bats")))

    document = _read(output)
    assert_that(document["run_attempt"]).is_equal_to(3)
    assert_that(document["durations"]).is_equal_to(
        {"tests/a.bats": 1.0, "tests/b.bats": 2.0},
    )
    assert_that(document["missing"]).is_empty()
    attempts = [(s["index"], s["run_attempt"]) for s in document["shards"]]
    assert_that(attempts).is_equal_to([(0, 1), (1, 3)])
    assert_that(capsys.readouterr().out).does_not_contain("dropped")


def test_merge_drops_a_later_attempt_than_its_own(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A document from attempt 4 cannot belong to a merge of attempt 3."""
    shards = tmp_path / "shards"
    future = _put(shards, "s0", _shard_doc(0, {"tests/a.bats": 1.0}, run_attempt=4))
    _put(shards, "s1", _shard_doc(1, {"tests/b.bats": 2.0}))
    output = tmp_path / "merged.json"

    mod.main(_merge_argv(shards, output, **_repo(tmp_path, "a.bats", "b.bats")))

    document = _read(output)
    assert_that(document["durations"]).is_equal_to({"tests/b.bats": 2.0})
    assert_that(document["missing"]).is_equal_to(["tests/a.bats"])
    assert_that(capsys.readouterr().out).contains(
        f"::warning::bats-durations: dropped shard durations {future}: "
        "run_attempt 4 is not between 1 and 3",
    )


def test_merge_takes_the_latest_attempt_of_a_shard(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Shard 0 in attempts 1 and 2: attempt 2 wins, attempt 1 gets a notice."""
    shards = tmp_path / "shards"
    old = _put(shards, "a", _shard_doc(0, {"tests/a.bats": 9.0}, run_attempt=1))
    _put(shards, "b", _shard_doc(0, {"tests/a.bats": 1.0}, run_attempt=2))
    _put(shards, "c", _shard_doc(1, {"tests/b.bats": 2.0}))
    output = tmp_path / "merged.json"

    mod.main(_merge_argv(shards, output, **_repo(tmp_path, "a.bats", "b.bats")))

    document = _read(output)
    assert_that(document["durations"]).is_equal_to(
        {"tests/a.bats": 1.0, "tests/b.bats": 2.0},
    )
    assert_that(document["missing"]).is_empty()
    attempts = [(s["index"], s["run_attempt"]) for s in document["shards"]]
    assert_that(attempts).is_equal_to([(0, 2), (1, 3)])
    printed = capsys.readouterr().out
    assert_that(printed).contains(
        f"::notice::bats-durations: dropped shard durations {old}: attempt 1 "
        "of shard 0 is superseded by attempt 2",
    )
    assert_that(printed).does_not_contain("::warning::bats-durations: dropped")


# --- paths and inputs --------------------------------------------------------


@pytest.mark.parametrize(
    ("path", "reason"),
    [
        pytest.param("/etc/a.bats", "'/etc/a.bats' is not a test file", id="abs"),
        pytest.param("../a.bats", "'../a.bats' is not a test file", id="up"),
        pytest.param("tests/../a.bats", "is not a test file", id="mid-up"),
        pytest.param("./tests/a.bats", "is not a test file", id="dot"),
        pytest.param("tests//a.bats", "is not a test file", id="double"),
        pytest.param("tests/a.bats\x00", "'tests/a.bats\\x00' is not", id="nul"),
        pytest.param("tests/z.bats", "is not a test file of this run", id="foreign"),
    ],
)
def test_merge_drops_a_document_with_a_bad_path(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    path: str,
    reason: str,
) -> None:
    """Only the run's own test files, exactly as listed, may appear."""
    _test_tree(tmp_path / "repo", ["a.bats", "b.bats"])
    shards = tmp_path / "shards"
    bad = _put(shards, "s0", _shard_doc(0, {path: 1.0}))
    _put(shards, "s1", _shard_doc(1, {"tests/b.bats": 2.0}))
    output = tmp_path / "merged.json"
    extra = {"root": str(tmp_path / "repo"), "test_path": "tests"}

    mod.main(_merge_argv(shards, output, **extra))

    assert_that(capsys.readouterr().out).contains(
        f"dropped shard durations {bad}: ",
    ).contains(reason)
    document = _read(output)
    assert_that(document["durations"]).is_equal_to({"tests/b.bats": 2.0})
    assert_that(document["missing"]).is_equal_to(["tests/a.bats"])


def test_merge_drops_a_document_over_the_size_bound(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A shard document comes from another job: a huge one is dropped unread."""
    monkeypatch.setattr(mod, "MAX_SHARD_DOCUMENT_BYTES", 64)
    shards = tmp_path / "shards"
    big = _put(shards, "s0", _shard_doc(0, {"tests/a.bats": 1.0}))
    small = _put(shards, "s1", "{}")
    output = tmp_path / "merged.json"

    mod.main(_merge_argv(shards, output, **_repo(tmp_path, "a.bats")))

    printed = capsys.readouterr().out
    assert_that(printed).contains(
        f"dropped shard durations {big}: the document is too large to read",
    )
    assert_that(printed).contains(f"dropped shard durations {small}: ")
    assert_that(output.exists()).is_false()


def test_merge_drops_an_unreadable_document(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A directory named like a shard document is dropped, not fatal."""
    shards = tmp_path / "shards"
    odd = shards / "s0" / "bats-durations-shard.json"
    odd.mkdir(parents=True)
    _put(shards, "s1", _shard_doc(1, {"tests/b.bats": 2.0}))
    output = tmp_path / "merged.json"

    mod.main(_merge_argv(shards, output, **_repo(tmp_path, "a.bats", "b.bats")))

    assert_that(capsys.readouterr().out).contains(f"dropped shard durations {odd}: ")
    assert_that(_read(output)["durations"]).is_equal_to({"tests/b.bats": 2.0})


def test_expected_files_skip_symlinks_like_the_runner(
    mod: ModuleType,
    tmp_path: Path,
) -> None:
    """A symlinked .bats file or directory is not expected: bats never runs it.

    ``run-coverage`` lists files with ``find -type f``, which skips both.
    """
    _test_tree(tmp_path, ["a.bats", "real/b.bats"])
    tests = tmp_path / "tests"
    (tests / "link.bats").symlink_to(tests / "a.bats")
    (tests / "linked-dir").symlink_to(tests / "real", target_is_directory=True)
    (tests / "dangling.bats").symlink_to(tests / "gone.bats")

    found = mod.expected_files(tmp_path, ".", "tests")

    assert_that(found).is_equal_to({"tests/a.bats", "tests/real/b.bats"})


def test_merge_never_lists_a_symlinked_file_as_missing(
    mod: ModuleType,
    tmp_path: Path,
) -> None:
    """Every shard reported: a symlinked file does not stay missing forever."""
    extra = _repo(tmp_path, "a.bats", "b.bats")
    repo_tests = tmp_path / "repo" / "tests"
    (repo_tests / "alias.bats").symlink_to(repo_tests / "a.bats")
    shards = tmp_path / "shards"
    _put(shards, "s0", _shard_doc(0, {"tests/a.bats": 1.0}))
    _put(shards, "s1", _shard_doc(1, {"tests/b.bats": 2.0}))
    output = tmp_path / "merged.json"

    mod.main(_merge_argv(shards, output, **extra))

    assert_that(_read(output)["missing"]).is_empty()


# --- job summary -------------------------------------------------------------


def test_merge_summary_names_each_refused_shard(
    mod: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A refused document and a shard that sent nothing each get a line."""
    summary = tmp_path / "summary.md"
    summary.write_text("earlier step\n", encoding="utf-8")
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    shards = tmp_path / "shards"
    stale = _shard_doc(0, {"tests/a.bats": 1.0}, sha="def456", shard_total=3)
    _put(shards, "s0", stale)
    _put(shards, "junk", "not json")
    output = tmp_path / "merged.json"
    argv = _merge_argv(shards, output, **_repo(tmp_path, "a.bats", "b.bats"))
    argv[argv.index("--shard-total") + 1] = "3"
    _put(shards, "s2", _shard_doc(2, {"tests/b.bats": 2.0}, shard_total=3))

    assert_that(mod.main(argv)).is_equal_to(0)

    assert_that(_read(output)["durations"]).is_equal_to({"tests/b.bats": 2.0})
    assert_that(summary.read_text(encoding="utf-8")).is_equal_to(
        "earlier step\n"
        "### BATS durations\n\n"
        "- A durations file in junk was refused: Expecting value: line 1 "
        "column 1 (char 0).\n"
        "- A durations file in s0 (it claims shard 0/3) was refused: sha is "
        "'def456', expected 'abc123'.\n"
        '- Shard 1/3 sent no durations: its step "Record shard BATS durations" '
        "refused the data or did not run, and that step's warning says why.\n\n",
    )


def test_merge_summary_names_duplicate_and_overlapping_shards(
    mod: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Shards dropped for a copy or a shared file are named, and no file left."""
    summary = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    shards = tmp_path / "shards"
    _put(shards, "a", _shard_doc(0, {"tests/a.bats": 1.0}))
    _put(shards, "b", _shard_doc(0, {"tests/a.bats": 3.0}))
    output = tmp_path / "merged.json"
    mod.main(_merge_argv(shards, output, **_repo(tmp_path, "a.bats")))

    text = summary.read_text(encoding="utf-8")

    assert_that(text).contains("- Shard 1/2 sent no durations")
    assert_that(text).ends_with(
        "- Nothing was published: no shard recorded a duration.\n\n",
    )
    line = "- Shard 0/2 was refused: it appears twice in attempt 3.\n"
    assert_that(text.count(line)).is_equal_to(2)


def test_merge_writes_no_summary_when_every_shard_counts(
    mod: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A clean merge adds nothing to the job summary."""
    summary = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    shards = tmp_path / "shards"
    _put(shards, "s0", _shard_doc(0, {"tests/a.bats": 1.0}))
    _put(shards, "s1", _shard_doc(1, {"tests/b.bats": 2.0}))
    output = tmp_path / "merged.json"

    mod.main(_merge_argv(shards, output, **_repo(tmp_path, "a.bats", "b.bats")))

    assert_that(output.exists()).is_true()
    assert_that(summary.exists()).is_false()


def test_merge_keeps_its_output_when_the_summary_cannot_be_written(
    mod: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The summary is extra: a failure to write it leaves the file published."""
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(tmp_path / "no-dir" / "s.md"))
    shards = tmp_path / "shards"
    _put(shards, "s0", _shard_doc(0, {"tests/a.bats": 1.0}))
    output = tmp_path / "merged.json"

    mod.main(_merge_argv(shards, output, **_repo(tmp_path, "a.bats", "b.bats")))

    assert_that(_read(output)["durations"]).is_equal_to({"tests/a.bats": 1.0})
    assert_that(capsys.readouterr().out).does_not_contain("merge failed")


@pytest.mark.parametrize(
    ("reason", "shown"),
    [
        pytest.param("plain words", "plain words", id="plain"),
        pytest.param("two\nlines\r", "two lines ", id="control"),
        pytest.param("<img src=x>", "&lt;img src=x&gt;", id="html"),
        pytest.param(
            "[x](http://e) `c` *b*",
            r"\[x\](http&#58;//e) \`c\` \*b\*",
            id="md",
        ),
        pytest.param("x" * 400, "x" * 297 + "...", id="long"),
        pytest.param(
            "see https://e.example/x www.e.example @octocat",
            "see https&#58;//e.example/x www&#46;e.example &#64;octocat",
            id="autolink",
        ),
    ],
)
def test_summary_reason_is_shown_as_plain_text(
    mod: ModuleType,
    reason: str,
    shown: str,
) -> None:
    """A reason may quote another job's document: it renders as plain text."""
    refusal = mod.Refusal(1, "s1", reason)

    lines = mod.summary_lines([refusal], [], 2)

    assert_that(lines).is_equal_to([f"Shard 1/2 was refused: {shown}."])


def test_summary_lists_a_bounded_number_of_refusals(mod: ModuleType) -> None:
    """Many refused files cannot push the summary past GitHub's size limit."""
    refusals = [mod.Refusal(None, f"junk{n}", "not json") for n in range(53)]

    lines = mod.summary_lines(refusals, [], 2)

    assert_that(lines).is_length(51)
    assert_that(lines[-1]).is_equal_to(
        "3 more refused file(s) are not listed; see the warnings.",
    )


def test_a_refused_file_that_claims_a_merged_shard_is_not_called_that_shard(
    mod: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Shard 0's real data is merged; a bad file claiming index 0 says so."""
    summary = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    shards = tmp_path / "shards"
    _put(shards, "s0", _shard_doc(0, {"tests/a.bats": 1.0}))
    _put(shards, "fake", _shard_doc(0, {"tests/a.bats": 9.0}, sha="def456"))
    _put(shards, "s1", _shard_doc(1, {"tests/b.bats": 2.0}))
    output = tmp_path / "merged.json"

    mod.main(_merge_argv(shards, output, **_repo(tmp_path, "a.bats", "b.bats")))

    assert_that(_read(output)["durations"]).is_equal_to(
        {"tests/a.bats": 1.0, "tests/b.bats": 2.0},
    )
    text = summary.read_text(encoding="utf-8")
    assert_that(text).contains("A durations file in fake (it claims shard 0/2)")
    assert_that(text).does_not_contain("- Shard 0/2 was refused")


def test_merge_drops_a_fifo_named_like_a_shard_document(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A FIFO would block the read: it is refused unopened, the rest merges."""
    shards = tmp_path / "shards"
    fifo = shards / "s0" / "bats-durations-shard.json"
    fifo.parent.mkdir(parents=True)
    os.mkfifo(fifo)
    _put(shards, "s1", _shard_doc(1, {"tests/b.bats": 2.0}))
    output = tmp_path / "merged.json"

    mod.main(_merge_argv(shards, output, **_repo(tmp_path, "a.bats", "b.bats")))

    assert_that(capsys.readouterr().out).contains(
        f"dropped shard durations {fifo}: the document is not a regular file",
    )
    assert_that(_read(output)["durations"]).is_equal_to({"tests/b.bats": 2.0})


def test_merge_drops_a_symlinked_shard_document(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A symlink in a downloaded artifact is never followed."""
    shards = tmp_path / "shards"
    real = tmp_path / "elsewhere.json"
    real.write_text(json.dumps(_shard_doc(0, {"tests/a.bats": 1.0})), encoding="utf-8")
    link = shards / "s0" / "bats-durations-shard.json"
    link.parent.mkdir(parents=True)
    link.symlink_to(real)
    _put(shards, "s1", _shard_doc(1, {"tests/b.bats": 2.0}))
    output = tmp_path / "merged.json"

    mod.main(_merge_argv(shards, output, **_repo(tmp_path, "a.bats", "b.bats")))

    assert_that(capsys.readouterr().out).contains(
        f"dropped shard durations {link}: the document is not a regular file",
    )
    assert_that(_read(output)["durations"]).is_equal_to({"tests/b.bats": 2.0})


@pytest.mark.parametrize(
    ("prefix", "test_path"),
    [
        pytest.param(".", "ABSOLUTE", id="absolute-test-path"),
        pytest.param("../outside", "tests", id="prefix-leaves-the-repo"),
        pytest.param("/abs/prefix", "tests", id="absolute-prefix"),
    ],
)
def test_expected_files_refuse_paths_outside_the_repository(
    mod: ModuleType,
    tmp_path: Path,
    prefix: str,
    test_path: str,
) -> None:
    """The expected set decides which shard paths count: it stays repo-relative.

    An absolute ``test-path`` or prefix would put absolute names in the set,
    and a shard document naming the same file would then be published.
    """
    _test_tree(tmp_path, ["a.bats"])
    if test_path == "ABSOLUTE":
        test_path = str(tmp_path / "tests" / "a.bats")

    with pytest.raises(mod.DurationsError, match="not inside the repository"):
        mod.expected_files(tmp_path, prefix, test_path)


def test_merge_with_an_absolute_test_path_publishes_nothing(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A shard document whose paths match an absolute test path is not used."""
    extra = _repo(tmp_path, "a.bats")
    absolute = str(Path(extra["root"]) / "tests" / "a.bats")
    extra["test_path"] = absolute
    shards = tmp_path / "shards"
    _put(shards, "s0", _shard_doc(0, {absolute: 1.0}))
    output = tmp_path / "merged.json"

    mod.main(_merge_argv(shards, output, **extra))

    assert_that(capsys.readouterr().out).contains("is not inside the repository")
    assert_that(output.exists()).is_false()


# --- workflow contract -------------------------------------------------------


def _steps(workflow: str, job: str) -> list[dict[str, Any]]:
    """Return one job's steps of a workflow file."""
    text = (WORKFLOWS / workflow).read_text(encoding="utf-8")
    document = yaml.safe_load(text)
    steps: list[dict[str, Any]] = document["jobs"][job]["steps"]
    return steps


def _by_name(steps: list[dict[str, Any]], name: str) -> tuple[int, dict[str, Any]]:
    """Return a step and its position."""
    for index, step in enumerate(steps):
        if step.get("name") == name:
            return index, step
    raise AssertionError(f"no step {name!r}")


def _condition(step: dict[str, Any]) -> str:
    """Return a step's if: with whitespace collapsed."""
    return " ".join(str(step["if"]).split())


@pytest.mark.parametrize(
    "workflow",
    ["reusable-test-shell.yml", "reusable-test-shell-run.yml"],
)
def test_shard_step_is_best_effort_and_main_only(workflow: str) -> None:
    """The shard step runs on default-branch pushes and cannot fail the shard."""
    steps = _steps(workflow, "test-sharded")
    record_at, record = _by_name(steps, "Record shard BATS durations")
    upload_at, upload = _by_name(steps, "Upload test results")
    recheck_at, _recheck = _by_name(steps, "Recheck harden-runner agent")

    assert_that(_condition(record)).contains(MAIN_ONLY).contains("!cancelled()")
    assert_that(record["continue-on-error"]).is_true()
    assert_that(record["run"]).contains("bats-durations.py").contains(" shard ")
    for argument in (
        '--run-attempt "$GITHUB_RUN_ATTEMPT"',
        '--sha "$GITHUB_SHA"',
        "--filter-marker bats-filter-used.txt",
        "--wall-ms-file bats-duration-ms.txt",
        "--bats-version-file bats-version.txt",
    ):
        assert_that(record["run"]).contains(argument)
    assert_that(record["run"]).does_not_contain("${{")
    assert_that(record["env"]).does_not_contain_key("TEST_FILTER")
    assert_that(record_at).is_less_than(upload_at)
    assert_that(recheck_at).is_equal_to(len(steps) - 1)
    assert_that(upload["with"]["path"]).contains("/bats-durations-shard.json")


@pytest.mark.parametrize(
    "workflow",
    ["reusable-test-shell.yml", "reusable-test-shell-run.yml"],
)
def test_aggregate_publishes_durations_on_main_only(workflow: str) -> None:
    """Merge and upload: main only, best effort, stable name, 90 days."""
    steps = _steps(workflow, "aggregate")
    merge_at, merge = _by_name(steps, "Merge shard BATS durations")
    upload_at, upload = _by_name(steps, "Upload BATS durations")
    warn_at, warn = _by_name(steps, "Warn on failed BATS durations upload")
    download_at, _download = _by_name(steps, "Finalize shard TAP download")
    recheck_at, _recheck = _by_name(steps, "Recheck harden-runner agent")

    assert_that(_condition(merge)).contains(MAIN_ONLY)
    assert_that(merge["continue-on-error"]).is_true()
    assert_that(merge["run"]).contains('--run-attempt "$GITHUB_RUN_ATTEMPT"')
    assert_that(merge["run"]).does_not_contain("${{")
    assert_that(upload["continue-on-error"]).is_true()
    assert_that(upload["if"]).contains("steps.durations.outcome == 'success'")
    assert_that(upload["with"]["name"]).is_equal_to(
        "${{ inputs.artifact-prefix }}-bats-durations",
    )
    assert_that(upload["with"]["retention-days"]).is_equal_to(90)
    assert_that(upload["with"]["path"]).ends_with("/bats-durations.json")
    assert_that(warn["if"]).contains("steps.upload-durations.outcome == 'failure'")
    assert_that([download_at, merge_at, upload_at, warn_at, recheck_at]).is_sorted()
    assert_that(recheck_at).is_equal_to(len(steps) - 1)
