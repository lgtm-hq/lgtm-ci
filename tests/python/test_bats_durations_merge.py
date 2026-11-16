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
    """A bad or foreign shard file is dropped; its files become missing."""
    shards = tmp_path / "shards"
    bad = _put(shards, "bad", content)
    _put(shards, "good", _shard_doc(1, {"tests/b.bats": 2}))
    output = tmp_path / "merged.json"

    code = mod.main(_merge_argv(shards, output, root=str(tmp_path)))

    assert_that(code).is_equal_to(0)
    assert_that(capsys.readouterr().out).contains(
        f"::warning::bats-durations: dropped shard durations {bad}: ",
    ).contains(reason)
    document = _read(output)
    assert_that(document["durations"]).is_equal_to({"tests/b.bats": 2.0})
    assert_that(_indexes(document)).is_equal_to([1])
    is_doc = isinstance(content, dict) and isinstance(content.get("durations"), dict)
    is_text_doc = isinstance(content, str) and '"tests/a.bats"' in content
    named = is_doc or is_text_doc
    expected_missing = ["tests/a.bats"] if named else []
    assert_that(document["missing"]).is_equal_to(expected_missing)


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

    mod.main(_merge_argv(shards, output, root=str(tmp_path)))

    document = _read(output)
    assert_that(document["durations"]).is_equal_to({"tests/c.bats": 2.0})
    assert_that(document["missing"]).is_equal_to(["tests/a.bats"])
    assert_that(_indexes(document)).is_equal_to([1])
    printed = capsys.readouterr().out
    assert_that(printed.count("shard_index 0 appears twice")).is_equal_to(2)


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

    mod.main(_merge_argv(shards, output, root=str(tmp_path)))

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

    mod.main(_merge_argv(shards, output, root=str(tmp_path)))

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

    code = mod.main(_merge_argv(tmp_path / "absent", output, root=str(tmp_path)))

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


def test_merge_with_an_absent_test_path_still_publishes(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Listing the test files is best effort too."""
    shards = tmp_path / "shards"
    _put(shards, "s0", _shard_doc(0, {"tests/a.bats": 1}))
    _put(shards, "s1", _shard_doc(1, {}))
    output = tmp_path / "merged.json"

    mod.main(_merge_argv(shards, output, root=str(tmp_path), test_path="nope"))

    printed = capsys.readouterr().out
    assert_that(printed).contains("files no shard ran are not listed")
    assert_that(_read(output)["missing"]).is_empty()


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

    mod.main(_merge_argv(shards, output, root=str(tmp_path)))

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

    mod.main(_merge_argv(shards, output, root=str(tmp_path)))

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

    mod.main(_merge_argv(shards, output, root=str(tmp_path)))

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
        pytest.param("/etc/a.bats", "is not a repository-relative path", id="abs"),
        pytest.param("../a.bats", "is not a repository-relative path", id="up"),
        pytest.param("tests/../a.bats", "is not a repository-relative", id="mid-up"),
        pytest.param("./tests/a.bats", "is not a repository-relative", id="dot"),
        pytest.param("tests//a.bats", "is not a repository-relative", id="double"),
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
    """Only the run's own repo-relative test files may appear."""
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


def test_merge_never_lists_an_invalid_path_as_missing(
    mod: ModuleType,
    tmp_path: Path,
) -> None:
    """Without a known file set, a dropped document's bad paths are not echoed."""
    shards = tmp_path / "shards"
    _put(shards, "s0", _shard_doc(0, {"/etc/a.bats": 1.0}, ["../b.bats"]))
    _put(shards, "s1", _shard_doc(1, {"tests/b.bats": 2.0}))
    output = tmp_path / "merged.json"

    mod.main(_merge_argv(shards, output, root=str(tmp_path)))

    assert_that(_read(output)["missing"]).is_empty()


def test_merge_never_reads_a_fifo(
    mod: ModuleType,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A FIFO named like a shard document is dropped without blocking."""
    shards = tmp_path / "shards"
    (shards / "s0").mkdir(parents=True)
    fifo = shards / "s0" / "bats-durations-shard.json"
    os.mkfifo(fifo)
    _put(shards, "s1", _shard_doc(1, {"tests/b.bats": 2.0}))
    output = tmp_path / "merged.json"

    mod.main(_merge_argv(shards, output, root=str(tmp_path)))

    assert_that(capsys.readouterr().out).contains(
        f"dropped shard durations {fifo}: shard document {fifo} is not a regular file",
    )
    assert_that(_read(output)["durations"]).is_equal_to({"tests/b.bats": 2.0})


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
