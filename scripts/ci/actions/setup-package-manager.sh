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
	if [[ -f "bun.lockb" && "$FROZEN_LOCKFILE" == "true" ]]; then
		bun install --frozen-lockfile
	elif [[ -f "package.json" ]]; then
		bun install
	else
		echo "No package.json found, skipping bun install"
	fi
	;;
npm)
	if [[ -f "package-lock.json" ]]; then
		npm ci
	elif [[ -f "package.json" ]]; then
		npm install
	else
		echo "No package.json found, skipping npm install"
	fi
	;;
pnpm)
	if [[ -f "pnpm-lock.yaml" && "$FROZEN_LOCKFILE" == "true" ]]; then
		pnpm install --frozen-lockfile
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
