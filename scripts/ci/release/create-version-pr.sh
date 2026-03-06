#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Create a version PR with CHANGELOG updates
#
# Calculates the next version from conventional commits, updates
# CHANGELOG.md, creates a release branch, and opens a pull request.
# This is the Stage 1 script in the two-stage release workflow.
#
# Optional environment variables:
#   MAX_BUMP          - Maximum bump type: major, minor, patch (default: major)
#   TAG_PREFIX        - Prefix for version tags (default: v)
#   PR_LABELS         - Comma-separated PR labels (default: release)
#   LINTRO_DOCKER_USER - UID[:GID] for Docker container (default: $(id -u):$(id -g))
#
# Required: GH_TOKEN must be set for gh CLI authentication
#
# Outputs:
#   pr-created - true if a PR was created
#   pr-url     - URL of the created PR
#   version    - Version number (e.g., 1.2.3)
#   branch     - Branch name (e.g., release/v1.2.3)

set -euo pipefail

# Source libraries
# Save RELEASE_SCRIPT_DIR before sourcing (sourced libs may overwrite SCRIPT_DIR)
RELEASE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$RELEASE_SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"
# shellcheck source=../lib/release.sh
source "$LIB_DIR/release.sh"

: "${MAX_BUMP:=major}"
: "${TAG_PREFIX:=v}"
: "${PR_LABELS:=release}"

# Detect default branch
if [[ -n "${DEFAULT_BRANCH:-}" ]]; then
	: # already set
elif DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null); then
	DEFAULT_BRANCH="${DEFAULT_BRANCH#refs/remotes/origin/}"
else
	DEFAULT_BRANCH="main"
fi

# =============================================================================
# Calculate next version
# =============================================================================

log_info "Calculating next version (max-bump: $MAX_BUMP)..."

NEXT_VERSION=$(determine_next_version "$MAX_BUMP") || {
	log_info "No releasable commits found, nothing to do"
	set_github_output "pr-created" "false"
	set_github_output "pr-url" ""
	set_github_output "version" ""
	set_github_output "branch" ""
	echo "pr-created=false"
	exit 0
}

CLEAN_VERSION="${NEXT_VERSION#v}"
TAG_NAME="${TAG_PREFIX}${CLEAN_VERSION}"
BRANCH_NAME="release/v${CLEAN_VERSION}"

log_info "Next version: $CLEAN_VERSION (tag: $TAG_NAME)"

# =============================================================================
# Generate changelog
# =============================================================================

log_info "Generating changelog..."

FROM_REF=$(git tag --merged HEAD --sort=-v:refname |
	grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+' |
	head -n1) || true
FROM_REF="${FROM_REF:-}"

# Generate changelog body (without version header — update-changelog.sh adds it)
CHANGELOG_BODY=$(generate_changelog "$FROM_REF" "HEAD" "" "full")
# Strip the "## Unreleased" header line that generate_changelog emits when
# no version is provided, keeping only the section content.
CHANGELOG_BODY=$(echo "$CHANGELOG_BODY" | sed '1{/^## Unreleased$/d;}' | sed '1{/^$/d;}')

# =============================================================================
# Create release branch and update CHANGELOG
# =============================================================================

configure_git_ci_user

# Clean up stale local/remote branch if it exists
if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME" 2>/dev/null; then
	log_info "Removing stale local branch: $BRANCH_NAME"
	git branch -D "$BRANCH_NAME"
fi

if git ls-remote --exit-code --heads origin "$BRANCH_NAME" >/dev/null 2>&1; then
	log_info "Removing stale remote branch: $BRANCH_NAME"
	git push origin --delete "$BRANCH_NAME" 2>/dev/null || true
fi

log_info "Creating branch: $BRANCH_NAME"
git checkout -b "$BRANCH_NAME"

log_info "Updating CHANGELOG.md..."
export VERSION="$CLEAN_VERSION"
export CHANGELOG_BODY
export TAG_PREFIX
export PUSH="false"
"$RELEASE_SCRIPT_DIR/update-changelog.sh"

# Format and verify CHANGELOG passes lint checks (mirrors py-lintro pattern)
: "${LINTRO_DOCKER_USER:=$(id -u):$(id -g)}"
if [[ -n "${LINTRO_IMAGE:-}" ]]; then
	mkdir -p .lintro
	log_info "Formatting CHANGELOG.md with lintro (Docker)..."
	docker run --rm --user "$LINTRO_DOCKER_USER" -v "$PWD:/workspace" -w /workspace \
		"$LINTRO_IMAGE" lintro fmt
	log_info "Verifying CHANGELOG.md passes lint checks..."
	docker run --rm --user "$LINTRO_DOCKER_USER" -v "$PWD:/workspace" -w /workspace \
		"$LINTRO_IMAGE" lintro chk
	log_success "CHANGELOG.md passes all lint checks"
elif command -v lintro >/dev/null 2>&1; then
	log_info "Formatting CHANGELOG.md with lintro (native)..."
	lintro fmt
	lintro chk
	log_success "CHANGELOG.md passes all lint checks"
else
	log_warn "Skipping CHANGELOG lint: set LINTRO_IMAGE or install lintro"
fi

git add CHANGELOG.md
git commit -m "chore(release): version ${CLEAN_VERSION}"

log_info "Pushing branch: $BRANCH_NAME"
git push origin "$BRANCH_NAME"

# =============================================================================
# Create pull request
# =============================================================================

log_info "Creating pull request..."

# Build PR body
PR_BODY="## Release v${CLEAN_VERSION}

This PR was automatically created by the release workflow.

### Changelog

${CHANGELOG_BODY}

### What happens when this PR is merged?

1. An annotated tag \`${TAG_NAME}\` will be created
2. A GitHub release will be published with the changelog
3. The floating major version tag will be updated

---

> **Note**: Do not modify this PR manually. If changes are needed,
> close it and let the workflow create a new one after those changes
> land on main."

# Write body to temp file to avoid shell escaping issues
BODY_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE"' EXIT
printf '%s' "$PR_BODY" >"$BODY_FILE"

PR_URL=$(gh pr create \
	--title "chore(release): version ${CLEAN_VERSION}" \
	--body-file "$BODY_FILE" \
	--base "$DEFAULT_BRANCH" \
	--head "$BRANCH_NAME" \
	--label "$PR_LABELS")

rm -f "$BODY_FILE"
trap - EXIT

log_success "Created version PR: $PR_URL"

# =============================================================================
# Outputs
# =============================================================================

set_github_output "pr-created" "true"
set_github_output "pr-url" "$PR_URL"
set_github_output "version" "$CLEAN_VERSION"
set_github_output "branch" "$BRANCH_NAME"

echo "pr-created=true"
echo "pr-url=$PR_URL"
echo "version=$CLEAN_VERSION"
echo "branch=$BRANCH_NAME"
