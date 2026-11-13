#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Choose the release GitHub App credential and write it to step outputs
#
# Source of truth for the inline "Select GitHub App credential" steps in the
# release reusables (#1367, #1450). Those steps stay inline because they run
# before the tooling checkout (the minted token is what checks the tooling out)
# and they read secrets, so they are workflow-owned.
# scripts/ci/bootstrap/sync_inline_blocks.py copies the lines between the
# markers below into each workflow and fails CI on drift. Keep the body
# self-contained: the inline copy runs with nothing else on disk.
#
# At least one of RELEASE_APP_CLIENT_ID / RELEASE_APP_ID must be set; the
# client ID wins when both are (e.g. `secrets: inherit` callers), with a
# notice. The choice goes to step outputs so the mint step never needs
# `secrets.*` in an `if:`.
#
# Environment variables (the workflow step always defines both, possibly empty):
#   APP_ID        - secrets.RELEASE_APP_ID
#   APP_CLIENT_ID - secrets.RELEASE_APP_CLIENT_ID
#   GITHUB_OUTPUT - Step output file; receives app-id= and client-id=
#
# After editing, run: uv run python scripts/ci/bootstrap/sync_inline_blocks.py

set -euo pipefail

# lgtm-ci-inline:begin select-app-credential
if [[ -z "${APP_ID}" && -z "${APP_CLIENT_ID}" ]]; then
  echo "::error title=missing App credential::set RELEASE_APP_CLIENT_ID or RELEASE_APP_ID"
  exit 1
fi
if [[ -n "${APP_CLIENT_ID}" ]]; then
  if [[ -n "${APP_ID}" ]]; then
    echo "::notice title=RELEASE_APP_ID ignored::both are set; using RELEASE_APP_CLIENT_ID"
  fi
  APP_ID=""
fi
{
  echo "app-id=${APP_ID}"
  echo "client-id=${APP_CLIENT_ID}"
} >> "${GITHUB_OUTPUT}"
# lgtm-ci-inline:end select-app-credential
