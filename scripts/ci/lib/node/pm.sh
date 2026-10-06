#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Package-manager dispatch for the Node runner scripts (#1077)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/node/pm.sh"
#   PACKAGE_MANAGER=npm pm_run test
#   pm_exec playwright install --with-deps chromium
#   pm_has vitest || die "install vitest as a devDependency"
#
# Every helper dispatches on $PACKAGE_MANAGER, which must be one of
# bun | npm | pnpm. The manager is never inferred from lockfiles (#181): an
# empty value fails with "package-manager is required for execution actions"
# and an unknown value fails naming it; both exit 2 so callers can tell a
# contract violation apart from a tool failure.
#
# Per-manager command table (run / exec / add-dev / has):
#
#   bun   bun run <script>   bun run <bin>          bun add -d        bun pm ls
#   npm   npm run <script>   npx --no-install <bin> npm install -D    npm ls --json
#   pnpm  pnpm run <script>  pnpm exec <bin>        pnpm add -D       pnpm ls --json
#
# pm_exec resolves binaries from the installed tree only: `npx --no-install`
# and `pnpm exec` never reach the registry, and `bun run <bin>` resolves
# node_modules/.bin without the registry fallback that `bunx` has. That is
# what keeps a missing devDependency an actionable failure (pm_has) instead
# of a silent install into the consumer's project.

[[ -n "${_LGTM_CI_NODE_PM_LOADED:-}" ]] && return 0
readonly _LGTM_CI_NODE_PM_LOADED=1

# Validate $PACKAGE_MANAGER and print the normalised name.
# Usage: manager=$(pm_require) || exit $?
pm_require() {
	local manager="${PACKAGE_MANAGER:-}"
	case "$manager" in
	bun | npm | pnpm)
		printf '%s\n' "$manager"
		;;
	"")
		echo "package-manager is required for execution actions (bun, npm, pnpm)" >&2
		return 2
		;;
	*)
		echo "Unsupported package manager: $manager (expected bun, npm, pnpm)" >&2
		return 2
		;;
	esac
}

# Run a package.json script through the selected manager.
# Usage: pm_run <script> [args...]
pm_run() {
	local script="${1:?pm_run: script name required}"
	shift
	local manager
	manager=$(pm_require) || return $?

	case "$manager" in
	bun) bun run "$script" "$@" ;;
	npm) npm run "$script" -- "$@" ;;
	pnpm) pnpm run "$script" "$@" ;;
	esac
}

# Execute a locally installed binary through the selected manager.
# Usage: pm_exec <bin> [args...]
pm_exec() {
	local bin="${1:?pm_exec: binary name required}"
	shift
	local manager
	manager=$(pm_require) || return $?

	case "$manager" in
	bun) bun run "$bin" "$@" ;;
	npm) npx --no-install "$bin" "$@" ;;
	pnpm) pnpm exec "$bin" "$@" ;;
	esac
}

# Add one or more devDependencies through the selected manager. The runner
# scripts do not call this (test tooling is a consumer prerequisite); it is
# here so a caller that wants to mutate a project does so with the manager it
# declared, never with a hard-coded one.
# Usage: pm_add_dev <pkg> [pkg...]
pm_add_dev() {
	[[ $# -gt 0 ]] || {
		echo "pm_add_dev: at least one package required" >&2
		return 2
	}
	local manager
	manager=$(pm_require) || return $?

	case "$manager" in
	bun) bun add -d "$@" ;;
	npm) npm install --save-dev "$@" ;;
	pnpm) pnpm add -D "$@" ;;
	esac
}

# Check whether a package is installed in the project tree, as reported by
# the selected manager. Returns 0 when present, 1 when absent, 2 on a
# contract violation.
# Usage: pm_has <pkg>
pm_has() {
	local pkg="${1:?pm_has: package name required}"
	local manager
	manager=$(pm_require) || return $?

	case "$manager" in
	bun)
		# `bun pm ls` prints one tree line per top-level package, e.g.
		# "├── vitest@3.2.4"; the leading space keeps "vitest@" from matching
		# inside a scoped name such as "@vitest/coverage-v8@3.2.4".
		bun pm ls 2>/dev/null | grep -qF -- " ${pkg}@"
		;;
	npm)
		# `npm ls <pkg>` exits non-zero for any tree problem, not only an
		# absent package, so read the JSON and ignore the exit code.
		npm ls --json --depth=0 "$pkg" 2>/dev/null |
			jq -e --arg pkg "$pkg" '(.dependencies // {}) | has($pkg)' >/dev/null
		;;
	pnpm)
		# `pnpm ls --json` returns one object per project; a hit in either
		# dependency map counts.
		pnpm ls --json --depth 0 "$pkg" 2>/dev/null |
			jq -e --arg pkg "$pkg" '
				any(.[]?;
					((.dependencies // {}) | has($pkg))
					or ((.devDependencies // {}) | has($pkg)))' >/dev/null
		;;
	esac
}
