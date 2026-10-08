# SPDX-License-Identifier: MIT
"""Tests for the removal gate in ``scripts/ci/catalog/deprecations.py`` (#1082).

Each case starts from the fixture repository in ``conftest.py`` (a stable
workflow with one deprecated input, a preview workflow and a deprecated
workflow on ``main``) and edits the work tree the way a removal PR would.
"""

# pytest injects fixtures by parameter name; the shadowing is the mechanism.
# pylint: disable=redefined-outer-name
from __future__ import annotations

import textwrap
from pathlib import Path
from types import ModuleType

from assertpy import assert_that
from governance_helpers import (  # pylint: disable=import-error
    TODAY,
    commit_consumers,
    drop_old_input,
    edit,
    git,
    remove_demo_input,
    run_gate,
    set_consumers,
)


def test_gate_passes_when_nothing_is_removed(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """An unchanged tree has nothing to gate."""
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_empty()
    assert_that(verdict.notices[-1]).starts_with("0 removal(s)")


def test_gate_allows_removal_when_no_consumer_uses_it(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """Fresh evidence without users lets a deprecated input go."""
    drop_old_input(repo)
    set_consumers(repo, [{"repository": "o/a", "uses": ["reusable-demo"]}])
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_empty()
    assert_that(verdict.notices).contains(
        "reusable-demo:input:old: removal allowed; no known consumer uses it",
    )


def test_gate_blocks_removal_while_a_consumer_still_passes_it(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """A consumer listing the key blocks the removal and is named."""
    drop_old_input(repo)
    set_consumers(
        repo,
        [{"repository": "o/a", "deprecated-in-use": ["reusable-demo:input:old"]}],
    )
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_length(1)
    assert_that(verdict.errors[0]).contains("reusable-demo:input:old", "o/a")


def test_gate_blocks_removal_on_stale_evidence(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """Age of the deprecation never counts; age of the evidence does."""
    drop_old_input(repo)
    set_consumers(repo, [{"repository": "o/a", "last-verified": "2026-09-01"}])
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_length(1)
    assert_that(verdict.errors[0]).contains("stale", "o/a")


def test_gate_accepts_an_exception_naming_the_issue(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """An exception lets a removal through despite a consumer."""
    drop_old_input(repo)
    set_consumers(
        repo,
        [{"repository": "o/a", "deprecated-in-use": ["reusable-demo:input:old"]}],
    )
    (repo / "catalog" / "deprecation-exceptions.yml").write_text(
        textwrap.dedent(
            """\
            ---
            schema-version: 1
            exceptions:
              - removal: reusable-demo:input:old
                issue: 42
                reason: "Owner accepted the break"
            """,
        ),
        encoding="utf-8",
    )
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_empty()
    assert_that(verdict.notices[0]).contains("exception (#42)")


def test_gate_rejects_removing_a_never_deprecated_stable_input(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """Stable items must go through a deprecation release first."""
    remove_demo_input(repo, "keep")
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_length(1)
    assert_that(verdict.errors[0]).contains(
        "reusable-demo:input:keep",
        "without a deprecation release",
    )


def test_gate_rejects_removing_a_never_deprecated_stable_output(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """Outputs are part of the stable contract too."""
    edit(
        repo,
        ".github/workflows/reusable-demo.yml",
        """    outputs:
      out:
        description: "Result"
        value: ${{ jobs.demo.outputs.out }}
""",
        "",
    )
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors[0]).starts_with("reusable-demo:output:out:")


def test_gate_only_notes_preview_removals(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """Preview may change without a migration; consumers are listed."""
    edit(
        repo,
        ".github/workflows/reusable-preview.yml",
        """      knob:
        description: "Experimental knob"
        type: string
        default: ""
""",
        "",
    )
    set_consumers(repo, [{"repository": "o/a", "uses": ["reusable-preview"]}])
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_empty()
    assert_that(verdict.notices[0]).contains("reusable-preview:input:knob", "o/a")


def test_gate_blocks_deleting_a_deprecated_entry_still_called(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """A deprecated entry point is in use when any consumer calls it."""
    (repo / ".github" / "workflows" / "reusable-legacy.yml").unlink()
    set_consumers(repo, [{"repository": "o/a", "uses": ["reusable-legacy"]}])
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_length(1)
    assert_that(verdict.errors[0]).starts_with("reusable-legacy:entry:")


def test_gate_ignores_a_registry_edit_that_erases_a_consumer(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """Evidence on the base cannot be dropped by the change being judged."""
    commit_consumers(
        repo,
        [{"repository": "o/a", "deprecated-in-use": ["reusable-demo:input:old"]}],
    )
    drop_old_input(repo)
    set_consumers(repo, [{"repository": "o/a"}])
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_length(1)
    assert_that(verdict.errors[0]).contains("o/a")


def test_gate_ignores_a_deleted_registry_row(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """Deleting a consumer's row does not delete the consumer."""
    commit_consumers(
        repo,
        [{"repository": "o/a", "deprecated-in-use": ["reusable-demo:input:old"]}],
    )
    drop_old_input(repo)
    set_consumers(repo, [])
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors[0]).contains("o/a")


def test_gate_keeps_the_base_verification_date(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """A change cannot freshen evidence by editing `last-verified`."""
    commit_consumers(repo, [{"repository": "o/a", "last-verified": "2026-09-01"}])
    drop_old_input(repo)
    set_consumers(repo, [{"repository": "o/a"}])
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors[0]).contains("stale", "o/a")


def test_gate_treats_a_future_date_as_stale(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """`last-verified` after today is not evidence."""
    drop_old_input(repo)
    set_consumers(repo, [{"repository": "o/a", "last-verified": "2027-01-01"}])
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors[0]).contains("stale", "o/a")


def test_gate_ignores_exceptions_already_on_the_base(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """An old exception is audit trail, not approval for a new removal."""
    (repo / "catalog" / "deprecation-exceptions.yml").write_text(
        textwrap.dedent(
            """\
            ---
            schema-version: 1
            exceptions:
              - removal: reusable-demo:input:keep
                issue: 42
                reason: "Approved long ago"
            """,
        ),
        encoding="utf-8",
    )
    git(repo, "commit", "-qam", "old exception")
    remove_demo_input(repo, "keep")
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_length(1)
    assert_that(verdict.errors[0]).contains("reusable-demo:input:keep")


def test_gate_fails_when_the_catalog_is_deleted(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """Deleting the catalog must not read as "nothing to gate"."""
    (repo / "catalog" / "catalog.yml").unlink()
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors[0]).contains("deleted")


def test_gate_rejects_making_a_stable_input_required(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """A new required input fails every caller that does not pass it."""
    edit(
        repo,
        ".github/workflows/reusable-demo.yml",
        """      keep:
        description: "Still supported"
        type: string
        default: ""
""",
        """      keep:
        description: "Still supported"
        type: string
        required: true
""",
    )
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_length(1)
    assert_that(verdict.errors[0]).starts_with("reusable-demo:required:keep:")


def test_gate_rejects_removing_a_stable_secret(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """Callers passing a removed secret fail at startup, so secrets count."""
    edit(
        repo,
        ".github/workflows/reusable-demo.yml",
        "    outputs:\n",
        "    secrets:\n      TOKEN:\n        required: false\n    outputs:\n",
    )
    git(repo, "commit", "-qam", "secret")
    edit(
        repo,
        ".github/workflows/reusable-demo.yml",
        "    secrets:\n      TOKEN:\n        required: false\n",
        "",
    )
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors[0]).starts_with("reusable-demo:secret:TOKEN:")


def test_gate_fails_on_an_unknown_base_ref(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """A missing base must not read as "nothing removed"."""
    verdict = deprecations.gate(
        repo_root=repo,
        base_ref="origin/nope",
        max_age_days=14,
        today=TODAY,
    )
    assert_that(verdict.errors[0]).contains("origin/nope")


def test_gate_blocks_removal_recorded_after_its_record_was_dropped(
    deprecations: ModuleType,
    repo: Path,
    consumer_scan: ModuleType,
) -> None:
    """The refreshed row of a removal PR still names the removed input."""
    drop_old_input(repo)
    usage = consumer_scan.Usage(
        entries={"reusable-demo"},
        keys={"reusable-demo:entry", "reusable-demo:input:old"},
    )
    head = consumer_scan.snapshot(repo_root=repo, ref=None)
    row = consumer_scan.refreshed_row(
        row={"repository": "o/a"},
        usage=usage,
        deprecated=head.deprecated,
        live=head.keys,
        today=TODAY,
    )
    set_consumers(repo, [row])
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_length(1)
    assert_that(verdict.errors[0]).contains("reusable-demo:input:old", "o/a")


def test_gate_blocks_partial_removal_from_a_deprecated_entry_in_use(
    deprecations: ModuleType,
    repo: Path,
) -> None:
    """A wholly deprecated entry's inputs stay while anyone calls the entry."""
    edit(
        repo,
        ".github/workflows/reusable-legacy.yml",
        "on:\n  workflow_call:\n",
        "on:\n  workflow_call:\n    inputs:\n      dir:\n        type: string\n",
    )
    git(repo, "commit", "-qam", "legacy input")
    edit(
        repo,
        ".github/workflows/reusable-legacy.yml",
        "    inputs:\n      dir:\n        type: string\n",
        "",
    )
    set_consumers(
        repo,
        [{"repository": "o/a", "uses": ["reusable-legacy"]}],
    )
    verdict = run_gate(deprecations, repo)
    assert_that(verdict.errors).is_length(1)
    assert_that(verdict.errors[0]).starts_with("reusable-legacy:input:dir:")
