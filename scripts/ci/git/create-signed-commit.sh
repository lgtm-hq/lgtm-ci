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
#   reset            - Make <branch> exactly <base> plus this commit, creating
#                      it if needed. The commit is made on a temporary branch
#                      created at --base (expectedHeadOid = --base); only then
#                      is <branch> moved, in one step, to the new commit, and
#                      the temporary branch is deleted. <branch> is never
#                      parked at --base, and a failed commit leaves it
#                      untouched. The repository's default branch is never
#                      reset.
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
                   reset: make the branch exactly --base plus this commit
                   (committed on a temporary branch, then moved in one step)
  --expected-head  append: SHA the branch head must equal
  --base           reset: SHA the branch is rebuilt on
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
	if [[ "/${path}/" == */./* || "$path" == *//* || "$path" == */ ]]; then
		log_error "Path must not contain '.' or empty components: $path"
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
	# A symlinked parent directory could point outside the checkout; resolve
	# the parent physically and require it to stay under the working directory.
	local root parent
	root="$(pwd -P)"
	if ! parent="$(cd -- "$(dirname -- "$path")" && pwd -P)"; then
		log_error "Cannot resolve parent directory of: $path"
		return 1
	fi
	case "${parent}/" in
	"${root}"/*) ;;
	*)
		log_error "Refusing path that resolves outside the working directory: $path"
		return 1
		;;
	esac
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

# reset mode: print the branch's current head, or nothing if it does not exist.
# Any lookup failure other than "not found" is fatal, so a restore can never
# delete a branch that already existed.
current_branch_head() {
	local repo="$1"
	local branch="$2"
	local err_file="$3"
	local head
	if head="$(gh api "repos/${repo}/branches/${branch}" --jq '.commit.sha' 2>"$err_file")"; then
		printf '%s\n' "$head"
		return 0
	fi
	if grep -qiE 'not found|HTTP 404' "$err_file"; then
		return 0
	fi
	log_error "Failed to look up branch ${branch} in ${repo}: $(cat "$err_file")"
	return 1
}

# reset mode: refuse to force-reset the repository's default branch.
refuse_default_branch() {
	local repo="$1"
	local branch="$2"
	local default_branch
	if ! default_branch="$(gh api "repos/${repo}" --jq '.default_branch')"; then
		log_error "Failed to read the default branch of ${repo}; refusing to reset ${branch}"
		return 1
	fi
	if [[ "$branch" == "$default_branch" ]]; then
		log_error "Refusing to reset ${branch}: it is the default branch of ${repo}"
		return 1
	fi
}

# reset mode: create a temporary branch at base to commit on.
create_temp_branch() {
	local repo="$1"
	local temp="$2"
	local oid="$3"
	gh api "repos/${repo}/git/refs" \
		-f ref="refs/heads/${temp}" -f sha="$oid" >/dev/null || return 1
	log_info "Created temporary branch ${temp} at ${oid}"
}

delete_temp_branch() {
	local repo="$1"
	local temp="$2"
	if gh api -X DELETE "repos/${repo}/git/refs/heads/${temp}" >/dev/null; then
		log_info "Deleted temporary branch ${temp}"
	else
		log_warn "Could not delete temporary branch ${temp}; delete it manually"
	fi
}

# reset mode: point the target branch at the new commit in one move, creating
# it if it does not exist yet. The branch is never parked at base, so an open
# pull request on it never sees an empty diff.
point_branch_at() {
	local repo="$1"
	local branch="$2"
	local oid="$3"
	local previous="$4"
	if [[ -z "$previous" ]]; then
		gh api "repos/${repo}/git/refs" \
			-f ref="refs/heads/${branch}" -f sha="$oid" >/dev/null || return 1
		log_info "Created branch ${branch} at ${oid}"
		return 0
	fi
	gh api -X PATCH "repos/${repo}/git/refs/heads/${branch}" \
		-f sha="$oid" -F force=true >/dev/null || return 1
	log_info "Moved branch ${branch} from ${previous} to ${oid}"
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

# Remove the work dir and, if still set, a temporary branch this run created
# (for example when the job is cancelled between creating and deleting it).
cleanup_on_exit() {
	if [[ -n "${CLEANUP_TEMP_BRANCH:-}" ]]; then
		delete_temp_branch "$CLEANUP_REPO" "$CLEANUP_TEMP_BRANCH" || true
	fi
	if [[ -n "${WORK_DIR:-}" ]]; then
		rm -rf "$WORK_DIR"
	fi
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
	CLEANUP_REPO=""
	CLEANUP_TEMP_BRANCH=""
	trap 'cleanup_on_exit' EXIT

	local expected_head_oid commit_branch temp_branch=""
	if [[ "$mode" == "append" ]]; then
		expected_head_oid="$expected_head"
		commit_branch="$branch"
	else
		expected_head_oid="$base"
		temp_branch="signed-commit-tmp/${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-${RANDOM}${RANDOM}"
		commit_branch="$temp_branch"
	fi

	# Build the whole payload before touching any ref.
	local payload_file="$WORK_DIR/payload.json"
	write_additions "$WORK_DIR/additions.jsonl" "$WORK_DIR/contents.b64" "${files[@]+"${files[@]}"}"
	write_deletions "$WORK_DIR/deletions.jsonl" "${deletes[@]+"${deletes[@]}"}"
	build_commit_payload "$repo" "$commit_branch" "$expected_head_oid" "$message" "$body" \
		"$WORK_DIR/additions.jsonl" "$WORK_DIR/deletions.jsonl" >"$payload_file"

	local previous_head=""
	if [[ "$mode" == "append" ]]; then
		require_branch_head "$repo" "$branch" "$expected_head" "$WORK_DIR/branch.err" || return 1
	else
		refuse_default_branch "$repo" "$branch" || return 1
		previous_head="$(current_branch_head "$repo" "$branch" "$WORK_DIR/branch.err")" || return 1
		create_temp_branch "$repo" "$temp_branch" "$base" || {
			log_error "Could not create temporary branch ${temp_branch}; ${branch} was not changed"
			return 1
		}
		CLEANUP_REPO="$repo"
		CLEANUP_TEMP_BRANCH="$temp_branch"
	fi

	local response_file="$WORK_DIR/response.json"
	local error_file="$WORK_DIR/response.err"
	gh api graphql --input - <"$payload_file" >"$response_file" 2>"$error_file" || true

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
		else
			delete_temp_branch "$repo" "$temp_branch"
			CLEANUP_TEMP_BRANCH=""
			log_error "${branch} was not changed"
		fi
		return 1
	fi

	if [[ "$mode" == "reset" ]]; then
		if ! point_branch_at "$repo" "$branch" "$commit_oid" "$previous_head"; then
			log_error "Commit ${commit_oid} was created but ${branch} could not be moved to it; ${branch} was not changed"
			delete_temp_branch "$repo" "$temp_branch"
			CLEANUP_TEMP_BRANCH=""
			return 1
		fi
		delete_temp_branch "$repo" "$temp_branch"
		CLEANUP_TEMP_BRANCH=""
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
