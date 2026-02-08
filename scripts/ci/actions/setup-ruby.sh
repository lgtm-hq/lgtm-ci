#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Setup Ruby environment with bundler
#
# Required environment variables:
#   STEP - Which step to run: ruby-version, bundler-version, bundle-config, or deps

set -euo pipefail

: "${STEP:?STEP is required}"

case "$STEP" in
ruby-version)
	version=$(ruby --version | awk '{print $2}')
	echo "version=$version" >>"$GITHUB_OUTPUT"
	echo "Ruby version: $version"
	;;

bundler-version)
	version=$(bundle --version | awk '{print $3}')
	echo "version=$version" >>"$GITHUB_OUTPUT"
	echo "Bundler version: $version"
	;;

bundle-config)
	# Install gems locally in vendor/bundle for caching
	bundle config set --local path 'vendor/bundle'
	# Use parallel jobs for faster installs
	bundle config set --local jobs 4
	# Retry failed network requests
	bundle config set --local retry 3
	echo "Bundler configured: path=vendor/bundle, jobs=4, retry=3"
	;;

deps)
	if [[ -f "Gemfile" ]] || [[ -f "Gemfile.lock" ]] || [[ -f "gems.rb" ]]; then
		echo "Installing dependencies with bundle install..."
		bundle install
	else
		echo "No Gemfile found, skipping install"
	fi
	;;

*)
	echo "Unknown step: $STEP"
	exit 1
	;;
esac
