#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Re-send the cross-repo Homebrew tap dispatch for a recovered
#          release (#966). Only reached when the detection probe proved the
#          tap lacks the version.
#
# Environment:
#   REPO      Repository whose workflow is dispatched (owner/repo) (required)
#   WORKFLOW  Workflow file name, e.g. dispatch-homebrew.yml (required)
#   REF       Git ref to dispatch on (required)
#   TAG       Release tag passed as the `tag` input (required)
#   GH_CMD    gh binary override (default gh)

set -euo pipefail

: "${REPO:?REPO is required}"
: "${WORKFLOW:?WORKFLOW is required}"
: "${REF:?REF is required}"
: "${TAG:?TAG is required}"
GH="${GH_CMD:-gh}"

"$GH" workflow run "$WORKFLOW" --repo "$REPO" --ref "$REF" -f "tag=$TAG"
echo "Dispatched $WORKFLOW@$REF on $REPO for $TAG"
