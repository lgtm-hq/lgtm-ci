#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Setup Node.js environment with bun
#
# Required environment variables:
#   STEP - Which step to run: node-version, bun-version, bun-cache, or deps
#   FROZEN_LOCKFILE - Whether to use --frozen-lockfile (for deps step)

set -euo pipefail

: "${STEP:?STEP is required}"

case "$STEP" in
node-version)
	version=$(node --version | sed 's/^v//')
	echo "version=$version" >>"$GITHUB_OUTPUT"
	echo "Node.js version: $version"
	;;

bun-version)
	version=$(bun --version)
	echo "version=$version" >>"$GITHUB_OUTPUT"
	echo "Bun version: $version"
	;;

bun-cache)
	cache_dir=$(bun pm cache)
	echo "dir=$cache_dir" >>"$GITHUB_OUTPUT"
	;;

deps)
	: "${FROZEN_LOCKFILE:=true}"
	if [[ -f "bun.lockb" ]] || [[ -f "package.json" ]]; then
		echo "Installing dependencies with bun..."
		if [[ "$FROZEN_LOCKFILE" == "true" ]] && [[ -f "bun.lockb" ]]; then
			bun install --frozen-lockfile
		else
			bun install
		fi
	else
		echo "No package.json found, skipping install"
	fi
	;;

*)
	echo "Unknown step: $STEP"
	exit 1
	;;
esac
