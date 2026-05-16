#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Install JavaScript dependencies for reusable workflows.

set -euo pipefail

: "${PACKAGE_MANAGER:=npm}"
: "${WORKING_DIRECTORY:=.}"
: "${FROZEN_LOCKFILE:=true}"

if [[ ! -d "$WORKING_DIRECTORY" ]]; then
	echo "Working directory does not exist: $WORKING_DIRECTORY" >&2
	exit 1
fi

cd "$WORKING_DIRECTORY"

case "$PACKAGE_MANAGER" in
bun)
	if [[ "$FROZEN_LOCKFILE" == "true" && (-f "bun.lock" || -f "bun.lockb") ]]; then
		bun install --frozen-lockfile
	elif [[ "$FROZEN_LOCKFILE" == "true" ]]; then
		echo "FROZEN_LOCKFILE=true requires bun.lock or bun.lockb for bun install" >&2
		exit 1
	elif [[ -f "package.json" ]]; then
		bun install
	else
		echo "No package.json found, skipping bun install"
	fi
	;;
npm)
	if [[ "$FROZEN_LOCKFILE" == "true" && -f "package-lock.json" ]]; then
		npm ci
	elif [[ "$FROZEN_LOCKFILE" == "true" ]]; then
		echo "FROZEN_LOCKFILE=true requires package-lock.json for npm install" >&2
		exit 1
	elif [[ -f "package.json" ]]; then
		npm install
	else
		echo "No package.json found, skipping npm install"
	fi
	;;
pnpm)
	if [[ "$FROZEN_LOCKFILE" == "true" && -f "pnpm-lock.yaml" ]]; then
		pnpm install --frozen-lockfile
	elif [[ "$FROZEN_LOCKFILE" == "true" ]]; then
		echo "FROZEN_LOCKFILE=true requires pnpm-lock.yaml for pnpm install" >&2
		exit 1
	elif [[ -f "package.json" ]]; then
		pnpm install
	else
		echo "No package.json found, skipping pnpm install"
	fi
	;;
"")
	echo "Dependency installation disabled"
	;;
*)
	echo "Unsupported package manager: $PACKAGE_MANAGER" >&2
	exit 1
	;;
esac
