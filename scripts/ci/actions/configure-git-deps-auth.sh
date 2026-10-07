#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Opt-in, host-scoped git authentication for private git
#          dependencies installed by `uv sync --frozen` (#1021).
#
# The reusable Python test workflow runs STEP=configure only when the caller
# passed the optional GIT_DEPS_TOKEN secret, immediately before the install
# step, and STEP=cleanup right after it. Nothing here is inherited from the
# caller's secret store: the secret is named, optional and explicit.
#
# Required environment variables:
#   STEP            - configure or cleanup
#   GIT_DEPS_HOST   - Host the rewrite is scoped to (e.g. github.com)
#
# configure only:
#   GIT_DEPS_TOKEN     - Token embedded in the rewritten URL
#   GIT_DEPS_USERNAME  - Username for the rewritten URL (default x-access-token)
#
# The rewrite is a single global git config entry:
#   url.https://<user>:<token>@<host>/.insteadOf = https://<host>/
# so every clone or fetch uv performs against that host authenticates and
# every other host is untouched. The entry is removed by STEP=cleanup; the
# token is never printed.

set -euo pipefail

: "${STEP:?STEP is required}"
: "${GIT_DEPS_HOST:?GIT_DEPS_HOST is required}"

host_re='^[A-Za-z0-9.-]+(:[0-9]+)?$'
if [[ ! "$GIT_DEPS_HOST" =~ $host_re ]]; then
	echo "::error title=git-deps-host::not a bare host[:port] - '${GIT_DEPS_HOST}'"
	exit 1
fi

cleanup_host_rewrites() {
	local key
	# --name-only keeps the token out of this listing's values, but the key
	# itself embeds it: iterate silently and never echo a key.
	while IFS= read -r key; do
		[[ -z "$key" ]] && continue
		if [[ "$key" == *"@${GIT_DEPS_HOST}/.insteadof" ]]; then
			git config --global --unset-all "$key"
		fi
	done < <(git config --global --name-only --get-regexp '^url\..*\.insteadof$' 2>/dev/null || true)
}

case "$STEP" in
configure)
	: "${GIT_DEPS_TOKEN:=}"
	: "${GIT_DEPS_USERNAME:=x-access-token}"
	if [[ -z "$GIT_DEPS_TOKEN" ]]; then
		echo "GIT_DEPS_TOKEN not provided; private git dependency auth not configured"
		exit 0
	fi
	# A token containing URL delimiters would change which host the rewrite
	# targets; refuse rather than build a URL from it.
	if [[ "$GIT_DEPS_TOKEN" == *[@/:?#\[\][:space:]]* ]]; then
		echo "::error title=GIT_DEPS_TOKEN::token contains URL delimiters or whitespace"
		exit 1
	fi
	user_re='^[A-Za-z0-9._-]+$'
	if [[ ! "$GIT_DEPS_USERNAME" =~ $user_re ]]; then
		echo "::error title=git-deps-username::not a plain username - '${GIT_DEPS_USERNAME}'"
		exit 1
	fi
	# Replace any stale entry for this host before adding ours.
	cleanup_host_rewrites
	git config --global \
		"url.https://${GIT_DEPS_USERNAME}:${GIT_DEPS_TOKEN}@${GIT_DEPS_HOST}/.insteadOf" \
		"https://${GIT_DEPS_HOST}/"
	echo "Configured git auth for https://${GIT_DEPS_HOST}/ (user ${GIT_DEPS_USERNAME}, token masked)"
	;;

cleanup)
	cleanup_host_rewrites
	echo "Removed git auth rewrite for https://${GIT_DEPS_HOST}/"
	;;

*)
	echo "Unknown step: $STEP"
	exit 1
	;;
esac
