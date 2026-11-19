#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Decide whether this run is a push to the repository's default
#          branch, comparing case-sensitively (#1659)
#
# GitHub expression `==` ignores case, so
# `github.ref == format('refs/heads/{0}', ...)` also matches a push to a
# distinct branch `Main` when the default branch is `main`. Cache save steps
# that only a default-branch push may run read this step's output instead.
#
# Environment variables:
#   GITHUB_EVENT_NAME - set by the runner (the caller's event inside a composite)
#   GITHUB_REF        - set by the runner
#   DEFAULT_BRANCH    - the repository's default branch; pass it through env:
#                       from github.event.repository.default_branch, never
#                       interpolated into run:
#
# Outputs:
#   default-branch-push - `true` only when GITHUB_EVENT_NAME is exactly `push`
#                         and GITHUB_REF is exactly refs/heads/<DEFAULT_BRANCH>;
#                         `false` otherwise, an empty or unset value included.
#
# Never fails the step: any doubt is `false`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

event="${GITHUB_EVENT_NAME:-}"
ref="${GITHUB_REF:-}"
default_branch="${DEFAULT_BRANCH:-}"
result=false
reason=""

# Quoted right-hand sides: [[ == ]] compares literally, so glob characters
# in a branch name never act as a pattern.
if [[ -z "$default_branch" ]]; then
	reason="the default branch is unknown"
elif [[ "$default_branch" == *[[:cntrl:]]* ]]; then
	reason="the default branch name holds a control character"
elif [[ "$event" != "push" ]]; then
	reason="the event is '${event}', not push"
elif [[ "$ref" != "refs/heads/${default_branch}" ]]; then
	reason="the ref is '${ref}', not refs/heads/${default_branch}"
else
	result=true
fi

set_github_output "default-branch-push" "$result"
if [[ "$result" == "true" ]]; then
	log_info "This run is a push to the default branch (${ref})"
else
	log_info "Not a push to the default branch: ${reason}"
fi
