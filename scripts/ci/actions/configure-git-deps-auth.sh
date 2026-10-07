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
# Optional environment variables:
#   GIT_DEPS_USERNAME  - Username for the rewritten URL (default x-access-token)
#   GIT_DEPS_TOKEN     - Token embedded in the rewritten URL (configure only)
#
# The rewrite is a single global git config entry:
#   url.https://<user>:<token>@<host>/.insteadOf = https://<host>/
# so every clone or fetch uv performs against that host authenticates and
# every other host is untouched. The entry lives in the runner's global git
# config between the configure and cleanup steps (the install step only);
# STEP=cleanup removes exactly the entries for this user@host and nothing
# else. The token is never printed.

set -euo pipefail

: "${STEP:?STEP is required}"
: "${GIT_DEPS_HOST:?GIT_DEPS_HOST is required}"
: "${GIT_DEPS_USERNAME:=x-access-token}"

# insteadOf matching is a case-sensitive prefix match and lockfile URLs are
# lowercase: normalise the host so a mixed-case input still matches.
GIT_DEPS_HOST="${GIT_DEPS_HOST,,}"
host_re='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:[0-9]+)?$'
if [[ ! "$GIT_DEPS_HOST" =~ $host_re ]]; then
	echo "::error title=git-deps-host::not a bare host[:port] - '${GIT_DEPS_HOST}'"
	exit 1
fi
user_re='^[A-Za-z0-9._-]+$'
if [[ ! "$GIT_DEPS_USERNAME" =~ $user_re ]]; then
	echo "::error title=git-deps-username::not a plain username - '${GIT_DEPS_USERNAME}'"
	exit 1
fi

# Remove every insteadOf entry of the form
#   url.https://<GIT_DEPS_USERNAME>:<anything>@<GIT_DEPS_HOST>/.insteadof
# --name-only keeps the token out of the listing's values, but the key
# itself embeds it: iterate silently and never echo a key. A key with
# several values is listed once per value; sort -u so --unset-all runs once
# per key (a second run would exit 5 for the now-absent key).
cleanup_host_rewrites() {
	local key prefix suffix
	prefix="url.https://${GIT_DEPS_USERNAME}:"
	suffix="@${GIT_DEPS_HOST}/.insteadof"
	while IFS= read -r key; do
		[[ -z "$key" ]] && continue
		if [[ "$key" == "${prefix}"*"${suffix}" ]]; then
			git config --global --unset-all "$key"
		fi
	done < <(git config --global --name-only --get-regexp '^url\..*\.insteadof$' 2>/dev/null | sort -u || true)
}

case "$STEP" in
configure)
	: "${GIT_DEPS_TOKEN:=}"
	if [[ -z "$GIT_DEPS_TOKEN" ]]; then
		echo "GIT_DEPS_TOKEN not provided; private git dependency auth not configured"
		exit 0
	fi
	# Allowlist rather than denylist: anything outside the unreserved URL
	# characters would either change which host the rewrite targets or be
	# decoded as an escape, and no supported token format needs more.
	token_re='^[A-Za-z0-9._~-]+$'
	if [[ ! "$GIT_DEPS_TOKEN" =~ $token_re ]]; then
		echo "::error title=GIT_DEPS_TOKEN::token contains characters outside [A-Za-z0-9._~-]"
		exit 1
	fi
	# Replace any stale entry for this user@host before adding ours.
	cleanup_host_rewrites
	git config --global \
		"url.https://${GIT_DEPS_USERNAME}:${GIT_DEPS_TOKEN}@${GIT_DEPS_HOST}/.insteadOf" \
		"https://${GIT_DEPS_HOST}/"
	echo "Configured git auth for https://${GIT_DEPS_HOST}/ (user ${GIT_DEPS_USERNAME}, token masked)"
	;;

cleanup)
	cleanup_host_rewrites
	echo "Removed git auth rewrite for https://${GIT_DEPS_HOST}/ (user ${GIT_DEPS_USERNAME})"
	;;

*)
	echo "Unknown step: $STEP"
	exit 1
	;;
esac
