#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Setup Python environment with uv
#
# Required environment variables:
#   PYTHON_VERSION - Python version to install
#   INSTALL_DEPS - Whether to install dependencies (true/false)
#   STEP - Which step to run: version, install, or deps

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
	if [[ -f "pyproject.toml" ]] || [[ -f "uv.lock" ]]; then
		echo "Installing dependencies with uv sync..."
		uv sync
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
