#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Warn a caller that a reusable-workflow input it set is deprecated and
#          no longer does anything (#770).
#
# #770 moved the publishing jobs out of reusable-coverage.yml,
# reusable-test-e2e-matrix.yml and reusable-sbom.yml so that callers which never
# publish stop granting publish-only scopes. The inputs that used to switch those
# jobs on are kept ACCEPTED but INERT for a release or two, because a reusable
# workflow rejects an unknown input with a hard `startup_failure`: deleting them
# outright would break every pinned caller at parse time instead of letting them
# migrate. Accepting them silently would be worse still, so every set value is
# announced here — in the annotations, in the job summary, and in the log.
#
# Only a value that differs from the workflow default is warned about: a caller
# cannot distinguish "unset" from "explicitly set to the default" in a reusable
# workflow, and warning on the default would fire on every run of every caller.
#
# Environment:
#   INPUT_NAME    (required) Input as the caller spells it
#   INPUT_VALUE   (required, may be empty) Value the caller passed
#   DEFAULT_VALUE (required, may be empty) Workflow default for that input
#   REPLACEMENT   (required) Migration instruction shown to the caller
#   NOTICE_KIND   (optional) 'deprecated' (default) when the input is now inert,
#                 or 'behavior-change' when it still works but does less than it
#                 used to. Calling a still-functional input "deprecated" would be
#                 a lie the caller has no way to check.

set -euo pipefail

: "${INPUT_NAME:?INPUT_NAME is required}"
: "${REPLACEMENT:?REPLACEMENT is required}"
: "${INPUT_VALUE:=}"
: "${DEFAULT_VALUE:=}"
: "${NOTICE_KIND:=deprecated}"

case "$NOTICE_KIND" in
deprecated)
	title="Deprecated input"
	lede="'${INPUT_NAME}' is deprecated and no longer has any effect (#770)."
	summary_lede="This input is accepted for backwards compatibility but **no longer has any effect** (#770)."
	;;
behavior-change)
	title="Behavior change"
	lede="'${INPUT_NAME}: ${INPUT_VALUE}' does less than it used to (#770)."
	summary_lede="This input still works, but **part of what it used to do has moved** (#770)."
	;;
*)
	echo "::error::NOTICE_KIND must be 'deprecated' or 'behavior-change' (got '${NOTICE_KIND}')" >&2
	exit 1
	;;
esac

if [[ "$INPUT_VALUE" == "$DEFAULT_VALUE" ]]; then
	echo "${INPUT_NAME}: left at its default; nothing to warn about"
	exit 0
fi

echo "::warning title=${title}::${lede} ${REPLACEMENT}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
	{
		echo "### ${title}: \`${INPUT_NAME}\`"
		echo
		echo "${summary_lede}"
		echo
		echo "${REPLACEMENT}"
		echo
	} >>"$GITHUB_STEP_SUMMARY"
fi
