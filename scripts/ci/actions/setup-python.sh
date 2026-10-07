#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Setup Python environment with uv
#
# Required environment variables:
#   STEP - Which step to run: uv-version, python-install, python-version, or deps
#   PYTHON_VERSION - Python version to install (required for python-install step)
#
# Optional environment variables (deps step):
#   EXTRAS - Comma-separated uv extras to install (e.g. "dev,full")
#
# The deps step always installs with `uv sync --frozen` (#1021). A plain
# `uv sync` validates the lockfile against pyproject.toml first and, when it
# finds the lock out of date (a version bump that skipped `uv lock`, for
# example), re-resolves the whole project. That re-resolution fetches EVERY
# locked git source, including dependency groups the job never installs, and
# on a cold uv cache a private host without credentials fails the job with
# "could not read Username for 'https://github.com'". `--frozen` installs the
# committed lockfile verbatim, so only the groups being installed are ever
# fetched. Keeping the lockfile current is the consumer's job (`uv lock
# --check` in its own CI).

set -euo pipefail

: "${STEP:?STEP is required}"

case "$STEP" in
uv-version)
	version=$(uv --version | awk '{print $2}')
	echo "version=$version" >>"$GITHUB_OUTPUT"
	echo "uv version: $version"
	;;

python-install)
	: "${PYTHON_VERSION:?PYTHON_VERSION is required}"
	uv python install "$PYTHON_VERSION"
	echo "Python $PYTHON_VERSION installed"
	;;

python-version)
	# `uv run` locks and syncs the project first, which on a cold cache
	# re-resolves a stale lock (the #1021 failure) before any install step.
	# Ask uv for the interpreter instead and query it directly.
	version=$("$(uv python find)" --version | awk '{print $2}')
	echo "version=$version" >>"$GITHUB_OUTPUT"
	echo "Python version: $version"
	;;

deps)
	: "${EXTRAS:=}"
	if [[ -f "pyproject.toml" ]] || [[ -f "uv.lock" ]]; then
		# In a uv workspace the lockfile lives at the workspace root, which
		# may be an ancestor of working-directory; look upwards before
		# deciding there is no lock.
		lockfile_found=false
		dir="$PWD"
		while :; do
			if [[ -f "$dir/uv.lock" ]]; then
				lockfile_found=true
				break
			fi
			[[ "$dir" == "/" ]] && break
			dir="$(dirname "$dir")"
		done
		if [[ "$lockfile_found" != "true" ]]; then
			# No committed lockfile: resolve once so --frozen has something
			# to install from. This is the only path that resolves in CI;
			# commit uv.lock to make installs reproducible and offline-safe.
			echo "::warning title=uv.lock missing::No uv.lock found; resolving dependencies in CI. Commit uv.lock for frozen installs."
			uv lock
		fi
		echo "Installing dependencies with uv sync --frozen..."
		if [[ -n "$EXTRAS" ]]; then
			# Convert comma-separated extras to multiple --extra flags
			UV_ARGS=()
			IFS=',' read -ra EXTRA_ARRAY <<<"$EXTRAS"
			for extra in "${EXTRA_ARRAY[@]}"; do
				# Trim whitespace and skip empty values
				trimmed="${extra// /}"
				if [[ -n "$trimmed" ]]; then
					UV_ARGS+=("--extra" "$trimmed")
				fi
			done
			uv sync --frozen "${UV_ARGS[@]}"
		else
			uv sync --frozen
		fi
	elif [[ -f "requirements.txt" ]]; then
		echo "Installing from requirements.txt..."
		uv pip install -r requirements.txt
	else
		echo "No dependency file found, skipping install"
	fi
	;;

*)
	echo "Unknown step: $STEP"
	exit 1
	;;
esac
