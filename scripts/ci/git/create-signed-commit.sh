#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Create a GitHub-signed commit on a branch via GraphQL createCommitOnBranch
#
# Commits created through createCommitOnBranch are authored by the token
# identity and signed by GitHub (verified=true), which satisfies rulesets
# that enforce required_signatures. Nothing is pushed with the git CLI:
# file contents are read from the working tree and uploaded as base64
# additions, and the branch ref is only touched server-side (reset mode).
#
# Usage:
#   create-signed-commit.sh --branch <name> --message <headline>
#     [--mode append|reset] [--expected-head <sha>] [--base <sha>]
#     [--body <text>] [--repository <owner/repo>]
#     [--file <path>]... [--delete <path>]...
#
# Modes:
#   append (default) - Add one commit on top of an existing branch. The ref is
#                      never created or moved; expectedHeadOid is set to
#                      --expected-head, so the mutation fails if the branch
#                      head moved in the meantime.
#   reset            - Create refs/heads/<branch> at --base, or force-reset it
#                      to --base when it already exists, then commit on top.
#                      expectedHeadOid is set to --base.
#
# Environment variables:
#   GH_TOKEN             - Token with contents:write (a GitHub App token for
#                          commits that trigger workflows)
#   GITHUB_REPOSITORY    - Target repository (owner/repo) when --repository
#                          and COMMIT_REPOSITORY are unset
#   GITHUB_OUTPUT        - When set, commit-sha and commit-url are written to it
#
# Optional environment fallbacks (used by the composite action; flags win,
# and --file/--delete flags are appended to the env lists):
#   COMMIT_REPOSITORY, COMMIT_BRANCH, COMMIT_MODE, COMMIT_EXPECTED_HEAD,
#   COMMIT_BASE, COMMIT_MESSAGE, COMMIT_BODY,
#   COMMIT_FILES  - newline-separated repo-relative paths to add or update
#   COMMIT_DELETE - newline-separated repo-relative paths to delete
#
# Outputs (stdout and GITHUB_OUTPUT):
#   commit-sha - OID of the created commit
#   commit-url - URL of the created commit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=../lib/github.sh
source "$LIB_DIR/github.sh"

usage() {
	cat >&2 <<'USAGE'
Usage: create-signed-commit.sh --branch <name> --message <headline>
         [--mode append|reset] [--expected-head <sha>] [--base <sha>]
         [--body <text>] [--repository <owner/repo>]
         [--file <path>]... [--delete <path>]...

  --branch         Branch to commit on
  --mode           append (default): commit on top of an existing branch
                   reset: create or force-reset the branch to --base first
  --expected-head  append: SHA the branch head must equal
  --base           reset: SHA to create or force-reset the branch at
  --message        Commit message headline (single line)
  --body           Optional commit message body
  --repository     Target repository (default: $GITHUB_REPOSITORY)
  --file           Repo-relative path to add or update (repeatable);
                   contents are read from the current working directory
  --delete         Repo-relative path to delete (repeatable)
USAGE
}

# Print each non-blank, whitespace-trimmed line of $1.
trimmed_lines() {
	local line
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		[[ -n "$line" ]] && printf '%s\n' "$line"
	done <<<"$1"
}

# Validate a repo-relative path (no absolute paths, no .. components).
validate_repo_path() {
	local path="$1"
	if [[ "$path" == /* ]]; then
		log_error "Path must be repo-relative, not absolute: $path"
		return 1
	fi
	if [[ "/${path}/" == */../* ]]; then
		log_error "Path must not contain '..' components: $path"
		return 1
	fi
}

# createCommitOnBranch can only write regular file contents.
validate_addition() {
	local path="$1"
	validate_repo_path "$path" || return 1
	if [[ -L "$path" ]]; then
		log_error "Refusing symlink (createCommitOnBranch cannot write symlinks): $path"
		return 1
	fi
	if [[ -d "$path" ]]; then
		log_error "Refusing directory (list individual files instead): $path"
		return 1
	fi
	if [[ ! -e "$path" ]]; then
		log_error "File not found: $path"
		return 1
	fi
	if [[ ! -f "$path" ]]; then
		log_error "Refusing non-regular file: $path"
		return 1
	fi
}

validate_oid() {
	local name="$1"
	local oid="$2"
	if [[ ! "$oid" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
		log_error "${name} must be a full lowercase commit SHA: ${oid}"
		return 1
	fi
}

# append mode: require the branch to exist and still point at expected-head.
require_branch_head() {
	local repo="$1"
	local branch="$2"
	local expected="$3"
	local err_file="$4"
	local head
	if ! head="$(gh api "repos/${repo}/branches/${branch}" --jq '.commit.sha' 2>"$err_file")"; then
		if grep -qiE 'not found|HTTP 404' "$err_file"; then
			log_error "Branch ${branch} does not exist in ${repo}; append mode requires an existing branch (use mode reset to create it)"
		else
			log_error "Failed to look up branch ${branch} in ${repo}: $(cat "$err_file")"
		fi
		return 1
	fi
	if [[ "$head" != "$expected" ]]; then
		log_error "Branch ${branch} head moved: expected ${expected}, found ${head}"
		return 1
	fi
	log_info "Branch ${branch} is at expected head ${expected}"
}

# reset mode: create refs/heads/<branch> at base, or force-reset it.
ensure_branch_at() {
	local repo="$1"
	local branch="$2"
	local oid="$3"
	if gh api "repos/${repo}/git/refs" \
		-f ref="refs/heads/${branch}" -f sha="$oid" >/dev/null 2>&1; then
		log_info "Created branch ${branch} at ${oid}"
		return 0
	fi
	gh api -X PATCH "repos/${repo}/git/refs/heads/${branch}" \
		-f sha="$oid" -F force=true >/dev/null
	log_info "Reset existing branch ${branch} to ${oid}"
}

# Write one JSON object per line ({path, contents}, base64 contents).
# Contents travel through files (--rawfile), never argv or shell quoting.
write_additions() {
	local out="$1"
	local b64="$2"
	shift 2
	local path
	: >"$out"
	for path in "$@"; do
		base64 <"$path" | tr -d '\n' >"$b64"
		jq -c -n --arg path "$path" --rawfile contents "$b64" \
			'{path: $path, contents: $contents}' >>"$out"
	done
}

write_deletions() {
	local out="$1"
	shift
	local path
	: >"$out"
	for path in "$@"; do
		jq -c -n --arg path "$path" '{path: $path}' >>"$out"
	done
}

build_commit_payload() {
	local repo="$1"
	local branch="$2"
	local expected_head_oid="$3"
	local headline="$4"
	local body="$5"
	local additions_file="$6"
	local deletions_file="$7"
	# shellcheck disable=SC2016 # $input is a GraphQL variable, not shell
	local mutation='mutation ($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid url } } }'
	jq -n \
		--arg query "$mutation" \
		--arg repo "$repo" \
		--arg branch "$branch" \
		--arg oid "$expected_head_oid" \
		--arg headline "$headline" \
		--arg body "$body" \
		--slurpfile additions "$additions_file" \
		--slurpfile deletions "$deletions_file" \
		'{
			query: $query,
			variables: {input: {
				branch: {repositoryNameWithOwner: $repo, branchName: $branch},
				expectedHeadOid: $oid,
				message: ({headline: $headline} + (if $body == "" then {} else {body: $body} end)),
				fileChanges: (
					(if ($additions | length) > 0 then {additions: $additions} else {} end)
					+ (if ($deletions | length) > 0 then {deletions: $deletions} else {} end)
				)
			}}
		}'
}

main() {
	local repo="${COMMIT_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
	local branch="${COMMIT_BRANCH:-}"
	local mode="${COMMIT_MODE:-append}"
	local expected_head="${COMMIT_EXPECTED_HEAD:-}"
	local base="${COMMIT_BASE:-}"
	local message="${COMMIT_MESSAGE:-}"
	local body="${COMMIT_BODY:-}"
	local files=()
	local deletes=()
	local line
	while IFS= read -r line; do
		files+=("$line")
	done < <(trimmed_lines "${COMMIT_FILES:-}")
	while IFS= read -r line; do
		deletes+=("$line")
	done < <(trimmed_lines "${COMMIT_DELETE:-}")

	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			usage
			return 0
			;;
		--repository | --branch | --mode | --expected-head | --base | --message | --body | --file | --delete)
			if [[ $# -lt 2 ]]; then
				log_error "$1 requires a value"
				return 1
			fi
			case "$1" in
			--repository) repo="$2" ;;
			--branch) branch="$2" ;;
			--mode) mode="$2" ;;
			--expected-head) expected_head="$2" ;;
			--base) base="$2" ;;
			--message) message="$2" ;;
			--body) body="$2" ;;
			--file) files+=("$2") ;;
			--delete) deletes+=("$2") ;;
			esac
			shift 2
			;;
		*)
			log_error "Unknown argument: $1"
			usage
			return 1
			;;
		esac
	done

	: "${GH_TOKEN:?GH_TOKEN is required}"
	if [[ -z "$repo" ]]; then
		log_error "Repository is required (--repository or GITHUB_REPOSITORY)"
		return 1
	fi
	if [[ -z "$branch" ]]; then
		log_error "--branch is required"
		return 1
	fi
	if [[ -z "$message" ]]; then
		log_error "--message is required"
		return 1
	fi
	if [[ "$message" == *$'\n'* ]]; then
		log_error "--message must be a single-line headline; put details in --body"
		return 1
	fi

	case "$mode" in
	append)
		if [[ -z "$expected_head" ]]; then
			log_error "append mode requires --expected-head"
			return 1
		fi
		if [[ -n "$base" ]]; then
			log_error "--base is only valid with --mode reset"
			return 1
		fi
		validate_oid "--expected-head" "$expected_head" || return 1
		;;
	reset)
		if [[ -z "$base" ]]; then
			log_error "reset mode requires --base"
			return 1
		fi
		if [[ -n "$expected_head" ]]; then
			log_error "--expected-head is only valid with --mode append"
			return 1
		fi
		validate_oid "--base" "$base" || return 1
		;;
	*)
		log_error "Invalid --mode: ${mode} (expected append or reset)"
		return 1
		;;
	esac

	if [[ ${#files[@]} -eq 0 && ${#deletes[@]} -eq 0 ]]; then
		log_error "Nothing to commit: pass at least one --file or --delete"
		return 1
	fi

	local path
	for path in "${files[@]+"${files[@]}"}"; do
		validate_addition "$path" || return 1
	done
	for path in "${deletes[@]+"${deletes[@]}"}"; do
		validate_repo_path "$path" || return 1
	done

	WORK_DIR="$(mktemp -d)"
	trap 'rm -rf "$WORK_DIR"' EXIT

	local expected_head_oid
	if [[ "$mode" == "append" ]]; then
		require_branch_head "$repo" "$branch" "$expected_head" "$WORK_DIR/branch.err" || return 1
		expected_head_oid="$expected_head"
	else
		ensure_branch_at "$repo" "$branch" "$base"
		expected_head_oid="$base"
	fi

	write_additions "$WORK_DIR/additions.jsonl" "$WORK_DIR/contents.b64" "${files[@]+"${files[@]}"}"
	write_deletions "$WORK_DIR/deletions.jsonl" "${deletes[@]+"${deletes[@]}"}"

	local response_file="$WORK_DIR/response.json"
	local error_file="$WORK_DIR/response.err"
	build_commit_payload "$repo" "$branch" "$expected_head_oid" "$message" "$body" \
		"$WORK_DIR/additions.jsonl" "$WORK_DIR/deletions.jsonl" |
		gh api graphql --input - >"$response_file" 2>"$error_file" || true

	local commit_oid commit_url
	commit_oid="$(jq -r '.data.createCommitOnBranch.commit.oid // empty' "$response_file" 2>/dev/null || true)"
	commit_url="$(jq -r '.data.createCommitOnBranch.commit.url // empty' "$response_file" 2>/dev/null || true)"
	if [[ -z "$commit_oid" ]]; then
		local details
		details="$(jq -r '[.errors[]?.message] | join("; ")' "$response_file" 2>/dev/null || true)"
		if [[ -z "$details" ]]; then
			details="$(cat "$response_file" "$error_file" 2>/dev/null | tr '\n' ' ')"
		fi
		log_error "createCommitOnBranch returned no commit: ${details:-empty response}"
		if [[ "$mode" == "append" ]]; then
			log_error "If the error mentions expectedHeadOid, ${branch} moved after ${expected_head_oid} was captured"
		fi
		return 1
	fi

	log_success "Created signed commit ${commit_oid} on ${branch}"
	echo "commit-sha=${commit_oid}"
	echo "commit-url=${commit_url}"
	set_github_output "commit-sha" "$commit_oid"
	set_github_output "commit-url" "$commit_url"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
