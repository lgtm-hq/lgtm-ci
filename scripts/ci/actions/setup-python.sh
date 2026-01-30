#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Setup Python environment with uv
#
# Required environment variables:
#   STEP - Which step to run: uv-version, python-install, python-version, or deps
#   PYTHON_VERSION - Python version to install (required for python-install step)

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
	version=$(uv run python --version | awk '{print $2}')
	echo "version=$version" >>"$GITHUB_OUTPUT"
	echo "Python version: $version"
	;;

deps)
	: "${EXTRAS:=}"
	if [[ -f "pyproject.toml" ]] || [[ -f "uv.lock" ]]; then
		echo "Installing dependencies with uv sync..."
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
			uv sync "${UV_ARGS[@]}"
		else
			uv sync
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
