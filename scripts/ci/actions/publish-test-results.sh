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
#   MERGE_EXISTING_SITE - When true, merge live or base-site content before upload
#   BASE_SITE_PATH - Optional local tree to use instead of HTTP mirror
#   BASE_PAGE_URL - Deployed site URL from actions/deploy-pages
#   WORKING_DIRECTORY - Directory to run in

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

_publish_test_results_normalize_target_dir() {
	local target_dir="${1#.}"
	target_dir="${target_dir%/}"
	target_dir="${target_dir#/}"
	if [[ -z "$target_dir" ]]; then
		echo "."
	else
		echo "$target_dir"
	fi
}

_publish_test_results_build_content() {
	local content_root="$1"
	local target_dir="$2"

	mkdir -p "$content_root/$target_dir"

	if [[ -n "${RESULTS_PATH:-}" ]]; then
		if [[ -d "$RESULTS_PATH" ]]; then
			if [[ -n "$(ls -A "$RESULTS_PATH" 2>/dev/null)" ]]; then
				mkdir -p "$content_root/$target_dir/tests"
				cp -r "$RESULTS_PATH"/* "$content_root/$target_dir/tests/"
				log_info "Copied test results from $RESULTS_PATH"
			else
				log_warn "Test results directory is empty: $RESULTS_PATH"
			fi
		elif [[ -f "$RESULTS_PATH" ]]; then
			mkdir -p "$content_root/$target_dir/tests"
			cp "$RESULTS_PATH" "$content_root/$target_dir/tests/"
			log_info "Copied test results file: $RESULTS_PATH"
		fi
	fi

	if [[ -n "${COVERAGE_PATH:-}" ]]; then
		if [[ -d "$COVERAGE_PATH" ]]; then
			if [[ -n "$(ls -A "$COVERAGE_PATH" 2>/dev/null)" ]]; then
				mkdir -p "$content_root/$target_dir/coverage"
				cp -r "$COVERAGE_PATH"/* "$content_root/$target_dir/coverage/"
				log_info "Copied coverage report from $COVERAGE_PATH"
			else
				log_warn "Coverage directory is empty: $COVERAGE_PATH"
			fi
		elif [[ -f "$COVERAGE_PATH" ]]; then
			mkdir -p "$content_root/$target_dir/coverage"
			cp "$COVERAGE_PATH" "$content_root/$target_dir/coverage/"
			log_info "Copied coverage file: $COVERAGE_PATH"
		fi
	fi

	if [[ -n "${BADGE_PATH:-}" ]]; then
		if [[ -d "$BADGE_PATH" ]]; then
			mkdir -p "$content_root/$target_dir/coverage"
			# shellcheck disable=SC2086
			for f in "$BADGE_PATH"/*.svg "$BADGE_PATH"/*.json; do
				[[ -f "$f" ]] && cp "$f" "$content_root/$target_dir/coverage/"
			done
			log_info "Copied badges from $BADGE_PATH"
		elif [[ -f "$BADGE_PATH" ]]; then
			mkdir -p "$content_root/$target_dir/coverage"
			cp "$BADGE_PATH" "$content_root/$target_dir/coverage/"
			log_info "Copied badge file: $BADGE_PATH"
		fi
	fi

	if [[ -d "$content_root/$target_dir/coverage" ]]; then
		if [[ ! -f "$content_root/$target_dir/coverage/index.html" ]]; then
			cat >"$content_root/$target_dir/coverage/index.html" <<'EOF'
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
}

_publish_test_results_copy_existing_site() {
	local staging_dir="$1"

	if [[ -n "${BASE_SITE_PATH:-}" ]]; then
		if [[ ! -d "$BASE_SITE_PATH" ]]; then
			log_error "base-site-path is not a directory: ${BASE_SITE_PATH}"
			return 1
		fi
		log_info "Merging existing site from base-site-path: ${BASE_SITE_PATH}"
		cp -a "${BASE_SITE_PATH}/." "$staging_dir/"
		return 0
	fi

	local site_url=""
	site_url=$(get_github_pages_url "") || site_url=""

	if [[ -z "$site_url" ]]; then
		log_error "merge-existing-site requires base-site-path or GITHUB_REPOSITORY for live site mirror"
		return 1
	fi

	if ! command -v wget >/dev/null 2>&1; then
		log_error "wget is required to mirror live GitHub Pages when base-site-path is unset"
		return 1
	fi

	local cut_dirs=""
	cut_dirs=$(get_github_pages_wget_cut_dirs "$site_url") || {
		log_error "Could not derive wget cut-dirs from site URL: ${site_url}"
		return 1
	}

	log_warn "Mirroring live site from ${site_url} (CDN/cache may serve stale content)"
	local wget_root="${staging_dir}/.lgtm-wget-root"
	mkdir -p "$wget_root"
	if ! wget -q -e robots=off -r -l 10 -np -nH --cut-dirs="$cut_dirs" -P "$wget_root" "$site_url"; then
		log_error "Live site mirror failed; merge-existing-site cannot preserve sibling trees"
		echo "::warning::Live site mirror failed for ${site_url}; existing Pages content was not merged"
		rm -rf "$wget_root"
		return 1
	fi

	if [[ -d "$wget_root" ]] && [[ -n "$(ls -A "$wget_root" 2>/dev/null)" ]]; then
		cp -a "$wget_root"/. "$staging_dir/"
	fi
	rm -rf "$wget_root"
}

_publish_test_results_overlay_content() {
	local staging_dir="$1"
	local content_root="$2"
	local target_dir="$3"

	if [[ "$target_dir" == "." ]]; then
		cp -a "$content_root"/. "$staging_dir/"
		return 0
	fi

	mkdir -p "$staging_dir/$target_dir"
	if [[ -d "$content_root/$target_dir" ]]; then
		cp -a "$content_root/$target_dir"/. "$staging_dir/$target_dir/"
	fi
}

case "$STEP" in
prepare)
	: "${RESULTS_PATH:=}"
	: "${COVERAGE_PATH:=}"
	: "${BADGE_PATH:=}"
	: "${TARGET_DIR:=.}"
	: "${WORKING_DIRECTORY:=.}"
	: "${MERGE_EXISTING_SITE:=false}"
	: "${BASE_SITE_PATH:=}"

	if [[ -n "${TARGET_BRANCH:-}" || -n "${KEEP_HISTORY:-}" || -n "${RETENTION_DAYS:-}" ]]; then
		log_error "target-branch, keep-history, and retention-days were removed; use official Pages deploy only (see docs/pages-publishing.md)"
		exit 1
	fi

	cd "$WORKING_DIRECTORY"

	normalized_target_dir=$(_publish_test_results_normalize_target_dir "$TARGET_DIR")

	staging_dir=$(mktemp -d)
	overlay_root=""
	log_info "Preparing files in staging directory: $staging_dir"

	if [[ "$MERGE_EXISTING_SITE" == "true" ]]; then
		overlay_root=$(mktemp -d)
		trap 'rm -rf "${overlay_root:-}"' EXIT
		_publish_test_results_build_content "$overlay_root" "$normalized_target_dir"
		_publish_test_results_copy_existing_site "$staging_dir"
		_publish_test_results_overlay_content "$staging_dir" "$overlay_root" "$normalized_target_dir"
		rm -rf "$overlay_root"
		trap - EXIT
	else
		_publish_test_results_build_content "$staging_dir" "$normalized_target_dir"
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
