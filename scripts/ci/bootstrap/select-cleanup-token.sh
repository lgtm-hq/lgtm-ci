#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Choose which token opens the vuln-suppression cleanup PR (#1687)
#
# Source of truth for the inline "Check cleanup token credential" step in
# reusable-vuln-suppression-check.yml. It stays inline because it runs before
# the repository checkout, which needs the token it chooses, and before the
# tooling checkout. scripts/ci/bootstrap/sync_inline_blocks.py copies the
# lines between the markers below into the workflow and fails CI on drift.
# Keep the body self-contained: the inline copy runs with nothing else on disk.
#
# App mode is an explicit choice (the cleanup-app-token input), never the mere
# presence of the App secrets: a `secrets: inherit` caller with organisation
# RELEASE_APP_* secrets keeps GH_TOKEN until it sets the input (#1691).
#
#   APP_MODE  App ID  key  GH_TOKEN  Result
#   true      set     set  any       mode=app (GH_TOKEN is never used)
#   true      any other combination  fail: incomplete App credential
#   false     any     any  set       mode=github-token (App secrets ignored)
#   false     any     any  unset     fail: no cleanup token
#   anything that is not true or false: fail
#
# Every variable is a boolean the workflow renders from an input or from a
# `secrets.X != ''` comparison; no secret value reaches this step.
#
# Environment variables (the workflow step always defines all four):
#   APP_MODE      - inputs.cleanup-app-token
#   APP_ID_SET    - RELEASE_APP_CLIENT_ID or RELEASE_APP_ID is set
#   APP_KEY_SET   - RELEASE_APP_PRIVATE_KEY is set
#   GH_TOKEN_SET  - GH_TOKEN is set
#   GITHUB_OUTPUT - Step output file; receives mode=app or mode=github-token
#
# After editing, run: uv run python scripts/ci/bootstrap/sync_inline_blocks.py

set -euo pipefail

# lgtm-ci-inline:begin select-cleanup-token
for flag in "${APP_MODE:-}" "${APP_ID_SET:-}" "${APP_KEY_SET:-}" "${GH_TOKEN_SET:-}"; do
	if [[ "${flag}" != true && "${flag}" != false ]]; then
		echo "::error title=unexpected cleanup token state::a credential flag is not true or false"
		exit 1
	fi
done
case "${APP_MODE}/${APP_ID_SET}/${APP_KEY_SET}/${GH_TOKEN_SET}" in
true/true/true/*)
	echo "mode=app" >>"${GITHUB_OUTPUT}"
	;;
true/*)
	echo "::error title=incomplete App credential::cleanup-app-token is true: pass" \
		"RELEASE_APP_PRIVATE_KEY with RELEASE_APP_CLIENT_ID or RELEASE_APP_ID" \
		"(GH_TOKEN is not used in this mode)"
	exit 1
	;;
false/*/*/true)
	echo "mode=github-token" >>"${GITHUB_OUTPUT}"
	;;
false/*/*/false)
	echo "::error title=missing cleanup token::pass GH_TOKEN, or set the" \
		"cleanup-app-token input to true and pass RELEASE_APP_CLIENT_ID or" \
		"RELEASE_APP_ID with RELEASE_APP_PRIVATE_KEY"
	exit 1
	;;
*)
	echo "::error title=unexpected cleanup token state::no rule matches the credential flags"
	exit 1
	;;
esac
# lgtm-ci-inline:end select-cleanup-token
