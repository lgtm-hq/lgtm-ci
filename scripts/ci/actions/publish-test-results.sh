#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Publish test results and coverage to GitHub Pages
#
# Required environment variables:
#   STEP - Which step to run: prepare, pages-url, summary
#
# Optional environment variables:
#   RESULTS_PATH - Path to test results directory
#   COVERAGE_PATH - Path to coverage report directory
#   BADGE_PATH - Path to badge files
#   TARGET_DIR - Subdirectory under the Pages site root (default: .)
#   BASE_PAGE_URL - Deployed site URL from actions/deploy-pages
#   WORKING_DIRECTORY - Directory to run in

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

case "$STEP" in
prepare)
	: "${RESULTS_PATH:=}"
	: "${COVERAGE_PATH:=}"
	: "${BADGE_PATH:=}"
	: "${TARGET_DIR:=.}"
	: "${WORKING_DIRECTORY:=.}"

	if [[ -n "${TARGET_BRANCH:-}" || -n "${KEEP_HISTORY:-}" || -n "${RETENTION_DAYS:-}" ]]; then
		log_error "target-branch, keep-history, and retention-days were removed; use official Pages deploy only (see docs/pages-publishing.md)"
		exit 1
	fi

	cd "$WORKING_DIRECTORY"

	# Create staging directory
	staging_dir=$(mktemp -d)
	log_info "Preparing files in staging directory: $staging_dir"

	# Create target directory structure
	mkdir -p "$staging_dir/$TARGET_DIR"

	# Copy test results if provided
	if [[ -n "$RESULTS_PATH" ]]; then
		if [[ -d "$RESULTS_PATH" ]]; then
			# Check if directory is non-empty before copying
			if [[ -n "$(ls -A "$RESULTS_PATH" 2>/dev/null)" ]]; then
				mkdir -p "$staging_dir/$TARGET_DIR/tests"
				cp -r "$RESULTS_PATH"/* "$staging_dir/$TARGET_DIR/tests/"
				log_info "Copied test results from $RESULTS_PATH"
			else
				log_warn "Test results directory is empty: $RESULTS_PATH"
			fi
		elif [[ -f "$RESULTS_PATH" ]]; then
			mkdir -p "$staging_dir/$TARGET_DIR/tests"
			cp "$RESULTS_PATH" "$staging_dir/$TARGET_DIR/tests/"
			log_info "Copied test results file: $RESULTS_PATH"
		fi
	fi

	# Copy coverage report if provided
	if [[ -n "$COVERAGE_PATH" ]]; then
		if [[ -d "$COVERAGE_PATH" ]]; then
			# Check if directory is non-empty before copying
			if [[ -n "$(ls -A "$COVERAGE_PATH" 2>/dev/null)" ]]; then
				mkdir -p "$staging_dir/$TARGET_DIR/coverage"
				cp -r "$COVERAGE_PATH"/* "$staging_dir/$TARGET_DIR/coverage/"
				log_info "Copied coverage report from $COVERAGE_PATH"
			else
				log_warn "Coverage directory is empty: $COVERAGE_PATH"
			fi
		elif [[ -f "$COVERAGE_PATH" ]]; then
			mkdir -p "$staging_dir/$TARGET_DIR/coverage"
			cp "$COVERAGE_PATH" "$staging_dir/$TARGET_DIR/coverage/"
			log_info "Copied coverage file: $COVERAGE_PATH"
		fi
	fi

	# Copy badges if provided
	if [[ -n "$BADGE_PATH" ]]; then
		if [[ -d "$BADGE_PATH" ]]; then
			mkdir -p "$staging_dir/$TARGET_DIR/coverage"
			# shellcheck disable=SC2086
			for f in "$BADGE_PATH"/*.svg "$BADGE_PATH"/*.json; do
				[[ -f "$f" ]] && cp "$f" "$staging_dir/$TARGET_DIR/coverage/"
			done
			log_info "Copied badges from $BADGE_PATH"
		elif [[ -f "$BADGE_PATH" ]]; then
			mkdir -p "$staging_dir/$TARGET_DIR/coverage"
			cp "$BADGE_PATH" "$staging_dir/$TARGET_DIR/coverage/"
			log_info "Copied badge file: $BADGE_PATH"
		fi
	fi

	# Create index.html if coverage report exists
	if [[ -d "$staging_dir/$TARGET_DIR/coverage" ]]; then
		if [[ ! -f "$staging_dir/$TARGET_DIR/coverage/index.html" ]]; then
			cat >"$staging_dir/$TARGET_DIR/coverage/index.html" <<'EOF'
<!DOCTYPE html>
<html>
<head>
  <title>Coverage Report</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 40px; }
    h1 { color: #333; }
    .badge { margin: 20px 0; }
    .files { margin-top: 20px; }
    .files a { display: block; margin: 5px 0; }
  </style>
</head>
<body>
  <h1>Coverage Report</h1>
  <div class="badge">
    <img src="badge.svg" alt="Coverage Badge" />
  </div>
  <div class="files">
    <h2>Files</h2>
    <p>Coverage report files are available in this directory.</p>
  </div>
</body>
</html>
EOF
		fi
	fi

	set_github_output "staging-dir" "$staging_dir"
	log_success "Staging directory prepared: $staging_dir"
	;;

pages-url)
	: "${TARGET_DIR:=.}"
	: "${BASE_PAGE_URL:=}"

	# Prefer deploy-pages output when available (official Pages workflow)
	if [[ -n "$BASE_PAGE_URL" ]]; then
		base="${BASE_PAGE_URL%/}/"
		target_dir="${TARGET_DIR#.}"
		target_dir="${target_dir%/}"
		target_dir="${target_dir#/}"
		if [[ -n "$target_dir" && "$target_dir" != "." ]]; then
			pages_url="${base}${target_dir}/"
		else
			pages_url="$base"
		fi
		set_github_output "pages-url" "$pages_url"
		log_info "GitHub Pages URL: $pages_url"
		exit 0
	fi

	owner=""
	repo=""

	# Try GITHUB_REPOSITORY first (CI environment)
	if [[ -n "${GITHUB_REPOSITORY:-}" ]] && [[ "$GITHUB_REPOSITORY" == *"/"* ]]; then
		owner="${GITHUB_REPOSITORY%%/*}"
		repo="${GITHUB_REPOSITORY##*/}"
	else
		# Fallback to parsing git remote origin URL (local runs)
		repo_url=$(git config --get remote.origin.url 2>/dev/null || true)
		if [[ -n "$repo_url" ]] && [[ "$repo_url" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
			owner="${BASH_REMATCH[1]}"
			repo="${BASH_REMATCH[2]}"
		fi
	fi

	if [[ -z "$owner" ]] || [[ -z "$repo" ]]; then
		log_error "Could not determine repository owner/name from GITHUB_REPOSITORY or git remote"
		exit 1
	fi

	# Clean up target_dir
	target_dir="${TARGET_DIR#.}"
	target_dir="${target_dir#/}"

	if [[ -n "$target_dir" ]]; then
		pages_url="https://${owner}.github.io/${repo}/${target_dir}/"
	else
		pages_url="https://${owner}.github.io/${repo}/"
	fi

	set_github_output "pages-url" "$pages_url"
	log_info "GitHub Pages URL: $pages_url"
	;;

summary)
	: "${PAGES_URL:=}"

	add_github_summary "## Published Test Results"
	add_github_summary ""

	if [[ -n "$PAGES_URL" ]]; then
		add_github_summary "Results published to GitHub Pages:"
		add_github_summary ""
		add_github_summary "- **Coverage Report:** [${PAGES_URL}coverage/](${PAGES_URL}coverage/)"
		add_github_summary "- **Test Results:** [${PAGES_URL}tests/](${PAGES_URL}tests/)"
		add_github_summary "- **Coverage Badge:** [${PAGES_URL}coverage/badge.svg](${PAGES_URL}coverage/badge.svg)"
	else
		add_github_summary "Pages URL was not available from the deployment step."
	fi

	add_github_summary ""
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
