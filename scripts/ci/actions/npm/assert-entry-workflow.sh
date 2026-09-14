#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Guard for npm trusted publishing: verify the run was triggered by
#          an entry workflow the consumer explicitly allowlisted.
#
# npm trusted publishing validates the ENTRY workflow file of the run — the
# consumer's top-level workflow, not this reusable — so an unexpected entry
# (a workflow_dispatch from the wrong file, a fork's copy, a renamed
# workflow) would fail the registry's provenance check only AFTER an
# irreversible publish attempt. This guard makes that a fast, readable
# pre-publish failure instead.
#
# Fail-closed when configured: a non-empty ALLOWED_ENTRY_WORKFLOWS that does
# not contain the current entry file fails the run. An EMPTY allowlist is
# refused for a LIVE publish (the guard is part of the publish contract) and
# skipped with a warning for a dry-run — the reusable cannot know the
# consumer's entry file, so each consumer must name it to get the guard.
#
# Environment:
#   ALLOWED_ENTRY_WORKFLOWS  Comma/newline-separated workflow paths, e.g.
#                            ".github/workflows/publish-npm.yml". Empty: skip
#                            on a dry-run, fail on a live publish.
#   LIVE                     1 for a live publish (default 0)
#   ENTRY_WORKFLOW_REF       The run's entry workflow ref; defaults to
#                            GITHUB_WORKFLOW_REF, which GitHub supplies as
#                            owner/repo/.github/workflows/publish.yml@refs/tags/v1.2.3

set -euo pipefail

ALLOWED_ENTRY_WORKFLOWS="${ALLOWED_ENTRY_WORKFLOWS:-}"
ENTRY_WORKFLOW_REF="${ENTRY_WORKFLOW_REF:-${GITHUB_WORKFLOW_REF:-}}"
LIVE="${LIVE:-0}"

if [[ -z "$ALLOWED_ENTRY_WORKFLOWS" ]]; then
	if [[ "$LIVE" == "1" ]]; then
		echo "ERROR: a live npm publish requires the 'entry-workflows' input: name the consumer's top-level publish workflow (the file registered as the npm trusted publisher) so the entry-workflow guard can enforce it. Nothing was published." >&2
		exit 1
	fi
	echo "WARNING: no ALLOWED_ENTRY_WORKFLOWS configured; skipping the npm entry-workflow guard for this dry-run. Set the 'entry-workflows' input to the consumer's top-level publish workflow; a live publish refuses to run without it." >&2
	exit 0
fi
if [[ -z "$ENTRY_WORKFLOW_REF" ]]; then
	echo "ERROR: cannot determine the entry workflow (ENTRY_WORKFLOW_REF/GITHUB_WORKFLOW_REF unset)" >&2
	exit 1
fi

# Normalize the GITHUB_WORKFLOW_REF shape GitHub documents —
#   owner/repo/.github/workflows/publish.yml@refs/tags/v1.2.3
#   owner/repo/.github/workflows/publish.yml@refs/heads/main
# — plus a bare .github/workflows/publish.yml, to the workflow path starting
# at .github/workflows/. The owner/repo prefix precedes the path and the @ref
# follows it, and both may contain slashes, so anchor on the fixed
# .github/workflows/ marker rather than parsing segments.
entry_path="${ENTRY_WORKFLOW_REF%%@*}"
if [[ "$entry_path" == *".github/workflows/"* ]]; then
	entry_path=".github/workflows/${entry_path#*".github/workflows/"}"
fi

allowed=0
while IFS= read -r candidate; do
	candidate="${candidate//$'\r'/}"
	candidate="${candidate#"${candidate%%[![:space:]]*}"}"
	candidate="${candidate%"${candidate##*[![:space:]]}"}"
	[[ -n "$candidate" ]] || continue
	if [[ "$candidate" == "$entry_path" ]]; then
		allowed=1
		break
	fi
done < <(printf '%s\n' "$ALLOWED_ENTRY_WORKFLOWS" | tr ',' '\n')

if [[ "$allowed" -ne 1 ]]; then
	echo "ERROR: entry workflow '$entry_path' is not in the npm trusted-publishing allowlist." >&2
	echo "ERROR: npm trusted publishing validates the ENTRY workflow file of the run; add '$entry_path' to the reusable's 'entry-workflows' input (or fix the trigger) and keep the consumer's npm trusted-publisher registration pointing at that file." >&2
	exit 1
fi

echo "Entry workflow '$entry_path' is allowlisted for npm trusted publishing."
