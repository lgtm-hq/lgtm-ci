#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Build and publish Ruby gems to RubyGems
#
# Environment variables:
#   STEP: validate | build | publish | summary
#   WORKING_DIRECTORY: Directory containing the gem (default: .)
#   GEMSPEC: Path to gemspec file (auto-detected if empty)
#   GEM_FILE: Path to built gem file (for publish step)
set -euo pipefail

: "${STEP:?STEP is required}"
: "${WORKING_DIRECTORY:=.}"
: "${GEMSPEC:=}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/actions.sh"
source "$SCRIPT_DIR/../lib/publish.sh"

# Change to working directory
cd "$WORKING_DIRECTORY"

# Auto-detect gemspec if not specified
find_gemspec() {
	# If GEMSPEC is explicitly set, require it to exist (fail fast)
	if [[ -n "$GEMSPEC" ]]; then
		if [[ -f "$GEMSPEC" ]]; then
			echo "$GEMSPEC"
			return 0
		fi
		log_error "Specified gemspec not found: $GEMSPEC"
		return 1
	fi

	# Auto-detect when not specified
	local found
	found=$(find . -maxdepth 1 -name "*.gemspec" -print -quit 2>/dev/null)
	if [[ -n "$found" ]]; then
		echo "$found"
		return 0
	fi

	return 1
}

case "$STEP" in
validate)
	log_info "Validating gemspec..."

	gemspec=$(find_gemspec) || die "No gemspec found"
	log_info "Using gemspec: $gemspec"

	if ! validate_gem_package "$gemspec"; then
		die "Gemspec validation failed"
	fi

	# Extract metadata
	name=$(grep -E '\.(name)\s*=' "$gemspec" | head -1 | sed 's/.*=\s*["\x27]\([^"\x27]*\)["\x27].*/\1/')
	version=$(extract_gem_version "$gemspec") || die "Could not extract version"

	log_success "Gemspec valid: $name@$version"
	;;

build)
	log_info "Building gem..."

	gemspec=$(find_gemspec) || die "No gemspec found"

	# Clean previous builds
	rm -f ./*.gem

	# Build the gem
	log_info "Running: gem build $gemspec"
	gem build "$gemspec"

	# Find the built gem
	gem_file=$(find . -maxdepth 1 -name "*.gem" -print -quit 2>/dev/null)
	if [[ -z "$gem_file" ]] || [[ ! -f "$gem_file" ]]; then
		die "Gem build failed: no .gem file created"
	fi

	# Extract metadata from gemspec
	name=$(grep -E '\.(name)\s*=' "$gemspec" | head -1 | sed 's/.*=\s*["\x27]\([^"\x27]*\)["\x27].*/\1/')
	version=$(extract_gem_version "$gemspec") || die "Could not extract version"

	log_success "Built: $gem_file"

	set_github_output "name" "$name"
	set_github_output "version" "$version"
	set_github_output "gem-file" "$gem_file"
	;;

publish)
	: "${GEM_FILE:?GEM_FILE is required for publish step}"

	log_info "Publishing to RubyGems..."

	if [[ ! -f "$GEM_FILE" ]]; then
		die "Gem file not found: $GEM_FILE"
	fi

	# Push to RubyGems
	# Note: OIDC credentials should be configured by rubygems/configure-rubygems-credentials
	log_info "Running: gem push $GEM_FILE"
	gem push "$GEM_FILE"

	log_success "Published successfully"
	set_github_output "published" "true"
	;;

summary)
	: "${GEM_NAME:=unknown}"
	: "${GEM_VERSION:=unknown}"
	: "${GEM_FILE:=}"
	: "${DRY_RUN:=false}"
	: "${PUBLISHED:=false}"

	add_github_summary "## RubyGems Publishing"
	add_github_summary ""
	add_github_summary "| Property | Value |"
	add_github_summary "| -------- | ----- |"
	add_github_summary "| Gem | $GEM_NAME |"
	add_github_summary "| Version | $GEM_VERSION |"

	if [[ -n "$GEM_FILE" ]]; then
		add_github_summary "| File | $GEM_FILE |"
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		add_github_summary "| Status | :construction: Dry Run (not published) |"
	elif [[ "$PUBLISHED" == "true" ]]; then
		add_github_summary "| Status | :white_check_mark: Published |"
		add_github_summary "| URL | https://rubygems.org/gems/$GEM_NAME/versions/$GEM_VERSION |"
	else
		add_github_summary "| Status | :x: Not Published |"
	fi
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
