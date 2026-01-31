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
#   TARGET_BRANCH - Branch to deploy to (default: gh-pages)
#   TARGET_DIR - Directory on target branch (default: .)
#   KEEP_HISTORY - Keep historical reports (true/false, default: false)
#   RETENTION_DAYS - Days to keep historical reports (default: 30)
#   WORKING_DIRECTORY - Directory to run in

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

case "$STEP" in
prepare)
	: "${RESULTS_PATH:=}"
	: "${COVERAGE_PATH:=}"
	: "${BADGE_PATH:=}"
	: "${TARGET_DIR:=.}"
	: "${KEEP_HISTORY:=false}"
	: "${WORKING_DIRECTORY:=.}"

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
			if ls -A "$RESULTS_PATH" >/dev/null 2>&1 && [[ -n "$(ls -A "$RESULTS_PATH" 2>/dev/null)" ]]; then
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
			if ls -A "$COVERAGE_PATH" >/dev/null 2>&1 && [[ -n "$(ls -A "$COVERAGE_PATH" 2>/dev/null)" ]]; then
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

	# Add history directory if keeping history
	if [[ "$KEEP_HISTORY" == "true" ]]; then
		history_dir="$staging_dir/$TARGET_DIR/history/$(date +%Y-%m-%d)"
		mkdir -p "$history_dir"

		# Copy current results to history
		if [[ -d "$staging_dir/$TARGET_DIR/tests" ]]; then
			cp -r "$staging_dir/$TARGET_DIR/tests" "$history_dir/"
		fi
		if [[ -d "$staging_dir/$TARGET_DIR/coverage" ]]; then
			cp -r "$staging_dir/$TARGET_DIR/coverage" "$history_dir/"
		fi

		log_info "Created history snapshot: $history_dir"
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

deploy)
	: "${STAGING_DIR:=}"
	: "${TARGET_BRANCH:=gh-pages}"

	if [[ -z "$STAGING_DIR" ]] || [[ ! -d "$STAGING_DIR" ]]; then
		log_error "Staging directory not found: $STAGING_DIR"
		exit 1
	fi

	log_info "Deploying to $TARGET_BRANCH branch..."

	# Get repository info
	repo_url=$(git config --get remote.origin.url)

	# Configure git
	configure_git_ci_user

	# Create a new orphan branch or checkout existing
	if git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
		# Branch exists
		git fetch origin "$TARGET_BRANCH"
		git checkout "$TARGET_BRANCH"
		git reset --hard "origin/$TARGET_BRANCH"
	else
		# Create orphan branch
		git checkout --orphan "$TARGET_BRANCH"
		git reset --hard
	fi

	# Clean working tree (remove all except .git) to avoid stale files
	find . -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} + 2>/dev/null || true

	# Copy staging content (use /. to include dotfiles and handle empty dirs)
	if [[ -n "$(ls -A "$STAGING_DIR" 2>/dev/null)" ]]; then
		cp -r "$STAGING_DIR"/. .
	fi

	# Add and commit
	git add -A
	if git diff --staged --quiet; then
		log_info "No changes to deploy"
	else
		git commit -m "Deploy test results and coverage [skip ci]"
		git push origin "$TARGET_BRANCH" --force
		log_success "Deployed to $TARGET_BRANCH"
	fi

	# Generate pages URL (respect TARGET_DIR if set)
	: "${TARGET_DIR:=.}"
	# Extract owner/repo from remote URL
	if [[ "$repo_url" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
		owner="${BASH_REMATCH[1]}"
		repo="${BASH_REMATCH[2]}"
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
	fi

	# Cleanup staging directory
	rm -rf "$STAGING_DIR"
	;;

pages-url)
	: "${TARGET_DIR:=.}"

	# Extract owner/repo from GITHUB_REPOSITORY
	owner="${GITHUB_REPOSITORY%%/*}"
	repo="${GITHUB_REPOSITORY##*/}"

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
	: "${TARGET_BRANCH:=gh-pages}"

	add_github_summary "## Published Test Results"
	add_github_summary ""

	if [[ -n "$PAGES_URL" ]]; then
		add_github_summary "Results published to GitHub Pages:"
		add_github_summary ""
		add_github_summary "- **Coverage Report:** [${PAGES_URL}coverage/](${PAGES_URL}coverage/)"
		add_github_summary "- **Test Results:** [${PAGES_URL}tests/](${PAGES_URL}tests/)"
		add_github_summary "- **Coverage Badge:** [${PAGES_URL}coverage/badge.svg](${PAGES_URL}coverage/badge.svg)"
	else
		add_github_summary "Results deployed to \`$TARGET_BRANCH\` branch."
	fi

	add_github_summary ""
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
