#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Stage the tooling of the repository a composite action was loaded
# from into the caller's workspace, so the action can call a sibling action by
# a workspace-relative path and run its scripts from the same tree (#1451).
#
# A composite action cannot reach a sibling with `./` (that resolves against
# the caller's workspace) and `$/` is not available on every runner or on
# GitHub Enterprise Server. The runner has already downloaded the action's
# whole repository at the pinned ref, so this script copies `.github/actions`
# and `scripts` from there into `<workspace>/.lgtm-ci-tooling`. No repository
# is named and nothing is cloned: a fork or mirror serves its own copy.
#
# Bash on purpose (exception to "logic in Python", #1421): this runs before
# the action sets Python up, and a self-hosted or container runner is not
# guaranteed to have a `python3`. The action needed only bash before.
#
# It runs before the staged copy exists, so the action must invoke it through
# its own downloaded path:
#
#   run: bash "${GITHUB_ACTION_PATH}/../../../scripts/ci/actions/stage-action-tooling.sh"
#
# The repository root is derived from GITHUB_ACTION_PATH alone
# (`<root>/.github/actions/<name>`). `git rev-parse` is deliberately not used:
# on a self-hosted runner the `_actions` directory can sit inside an unrelated
# enclosing repository, and git would return that one.
#
# An existing tooling directory is REPLACED as a whole, never merged into: the
# staged tree always holds exactly one commit's tooling. A directory this
# script did not stage (a caller's earlier checkout, a leftover on a
# persistent runner) is replaced with a warning. Two cases are exceptions:
#   - the action was loaded from the tooling directory itself
#     (`uses: ./<tooling dir>/.github/actions/<name>`): it is used in place;
#   - the action lives deeper inside the tooling directory: replacing it would
#     delete the source, so the script fails.
#
# Required environment variables:
#   GITHUB_ACTION_PATH - Composite action directory
#   GITHUB_WORKSPACE   - Caller workspace
#   GITHUB_ENV         - GitHub Actions environment file
#
# The destination is fixed. Actions that use this script call their sibling
# at `./.lgtm-ci-tooling/...`, so a destination taken from the environment
# could stage one tree while the action runs another.
#
# Optional environment variables:
#   TOOLING_REF - Raw value of the deprecated `tooling-ref` input. Ignored for
#                 staging; a warning is emitted when it is non-empty and
#                 differs from the ref the action was loaded at. That ref is
#                 only known for the runner's `_actions/<owner>/<repo>/<ref>`
#                 layout; otherwise, or when the path names `_actions` more
#                 than once, no comparison is made.
#
# Exports through GITHUB_ENV:
#   SCRIPTS_DIR - `<workspace>/.lgtm-ci-tooling/scripts`

set -euo pipefail

: "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

readonly MARKER=".staged-by-action"

die() {
	echo "::error title=stage-action-tooling::$*" >&2
	exit 1
}

# Value safe to print inside a workflow command: no line breaks.
one_line() {
	local value="$1"
	value="${value//$'\r'/ }"
	value="${value//$'\n'/ }"
	printf '%s' "$value"
}

readonly tooling_dir=".lgtm-ci-tooling"

action_dir="${GITHUB_ACTION_PATH//\\//}"
action_dir="${action_dir%/}"
case "$action_dir" in
*/.github/actions/?*) ;;
*)
	die "cannot derive the repository root: '$(one_line "$action_dir")' is not <root>/.github/actions/<name>"
	;;
esac
source_root="${action_dir%/.github/actions/*}"

workspace="${GITHUB_WORKSPACE//\\//}"
workspace="${workspace%/}"
[[ -d "$workspace" ]] || die "GITHUB_WORKSPACE '$(one_line "$workspace")' is not a directory"

for part in .github/actions scripts/ci; do
	[[ -d "${source_root}/${part}" ]] ||
		die "'$(one_line "${source_root}/${part}")' is missing: the action's repository was not downloaded whole"
done

dest="${workspace}/${tooling_dir}"

# Physical paths, so a symlinked workspace or tool directory compares equal.
source_real="$(cd "$source_root" && pwd -P)"
workspace_real="$(cd "$workspace" && pwd -P)"
dest_real="${workspace_real}/${tooling_dir}"
# A symlink at the destination is removed as a link, never followed, so it
# is compared by its own path and not by its target.
if [[ -d "$dest" && ! -L "$dest" ]]; then
	dest_real="$(cd "$dest" && pwd -P)"
fi

warn_tooling_ref() {
	local requested="${TOOLING_REF:-}"
	local loaded tail
	[[ -n "$requested" ]] || return 0
	# A path inside the workspace is a local `./` use: the checkout's ref is
	# the caller's business and is not readable from the path.
	case "${source_real}/" in
	"${workspace_real}/"*) return 0 ;;
	esac
	# Runner layout: <...>/_actions/<owner>/<repo>/<ref>, where <ref> may
	# itself contain slashes (a branch such as feature/x).
	case "$source_root" in
	*/_actions/*/*/?*) ;;
	*) return 0 ;;
	esac
	# A ref can itself contain `/_actions/`; the split is then ambiguous.
	tail="${source_root#*/_actions/}"
	case "$tail" in
	*/_actions/*) return 0 ;;
	esac
	tail="${tail#*/}"
	loaded="${tail#*/}"
	[[ -n "$loaded" ]] || return 0
	if [[ "$requested" != "$loaded" ]]; then
		echo "::warning title=tooling-ref ignored::tooling-ref '$(one_line "$requested")' differs from the ref this action was loaded at ('$(one_line "$loaded")'); the tooling of '$(one_line "$loaded")' is used. Remove the input."
	fi
}

warn_tooling_ref

export_scripts_dir() {
	echo "SCRIPTS_DIR=${dest}/scripts" >>"$GITHUB_ENV"
}

if [[ "$source_real" == "$dest_real" ]]; then
	echo "Action was loaded from ${dest}; using its tooling in place"
	export_scripts_dir
	exit 0
fi

case "${source_real}/" in
"${dest_real}/"*)
	die "the action was loaded from inside '$(one_line "$dest")', which this action replaces; check the tooling out directly at '${tooling_dir}' or at another path"
	;;
esac

# Build the new tree beside the destination, then swap it in whole.
staging="${dest}.staging.$$"
rm -rf -- "$staging"
trap 'rm -rf -- "$staging"' EXIT
mkdir -p "${staging}/.github"
cp -Rp "${source_root}/.github/actions" "${staging}/.github/actions"
cp -Rp "${source_root}/scripts" "${staging}/scripts"
printf '%s\n' "$source_root" >"${staging}/${MARKER}"

if [[ -e "$dest" || -L "$dest" ]]; then
	if [[ -f "${dest}/${MARKER}" ]]; then
		echo "Replacing tooling staged earlier at ${dest}"
	else
		echo "::warning title=tooling directory replaced::'$(one_line "$dest")' already existed and was not staged by this action; it is replaced as a whole with the tooling of the action's own repository."
	fi
	rm -rf -- "$dest"
fi
mv -- "$staging" "$dest"
trap - EXIT

echo "Staged tooling from ${source_root} into ${dest}"
export_scripts_dir
