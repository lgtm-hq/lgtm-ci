#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Resolve and download GitHub Actions workflow artifacts into a site tree
#
# Manifest JSON schema:
#   {
#     "strict": false,
#     "bundles": [
#       {
#         "id": "vitest-coverage",
#         "workflow": "quality-ci-main",
#         "artifact": "coverage-html",
#         "dest": "coverage",
#         "require_success": true
#       }
#     ]
#   }
#
# The workflow field matches the workflow run display name or workflow file stem
# (e.g. quality-ci-main matches path .../quality-ci-main.yml).

[[ -n "${_LGTM_CI_BUNDLE_WORKFLOW_ARTIFACTS_LOADED:-}" ]] && return 0
readonly _LGTM_CI_BUNDLE_WORKFLOW_ARTIFACTS_LOADED=1
readonly BUNDLE_WORKFLOW_RUNS_PER_PAGE=100

# Load manifest JSON from inline JSON or a .json/.yaml/.yml file path.
# Sets BUNDLE_MANIFEST_JSON.
# Usage: bundle_load_manifest "$BUNDLE_MANIFEST"
bundle_load_manifest() {
	local manifest_input="${1:?manifest input is required}"

	if [[ -f "$manifest_input" ]]; then
		case "$manifest_input" in
		*.json)
			BUNDLE_MANIFEST_JSON=$(<"$manifest_input")
			;;
		*.yaml | *.yml)
			if ! command -v ruby >/dev/null 2>&1; then
				log_error "Ruby is required to parse YAML manifests: $manifest_input"
				return 1
			fi
			BUNDLE_MANIFEST_JSON=$(
				ruby -ryaml -rjson -e '
					permitted = [
						Hash, Array, String, Integer, Float, TrueClass, FalseClass, NilClass
					]
					data = YAML.safe_load(
						File.read(ARGV[0]),
						permitted_classes: permitted,
						permitted_symbols: [],
						aliases: false,
					)
					puts JSON.generate(data)
				' "$manifest_input"
			)
			;;
		*)
			log_error "Unsupported manifest file type: $manifest_input"
			return 1
			;;
		esac
	elif [[ "$manifest_input" == \{* ]]; then
		BUNDLE_MANIFEST_JSON="$manifest_input"
	else
		log_error "BUNDLE_MANIFEST must be inline JSON or a path to a manifest file"
		return 1
	fi

	if ! jq -e . >/dev/null 2>&1 <<<"$BUNDLE_MANIFEST_JSON"; then
		log_error "Invalid bundle manifest JSON"
		return 1
	fi
}

# Find a workflow run ID for a commit SHA.
# Usage: bundle_find_workflow_run WORKFLOW_KEY COMMIT_SHA REQUIRE_SUCCESS
bundle_find_workflow_run() {
	local workflow_key="$1"
	local commit_sha="$2"
	local require_success="${3:-true}"

	local workflow_match
	local jq_filter
	# shellcheck disable=SC2016
	workflow_match='((.name | ascii_downcase) == ($wf | ascii_downcase)) or ((.path | split("/")[-1] | sub("\\.ya?ml$"; "") | ascii_downcase) == ($wf | ascii_downcase))'
	if [[ "$require_success" == "false" ]]; then
		jq_filter="first(.workflow_runs[] | select(${workflow_match} and (.conclusion == \"success\" or .conclusion == \"failure\" or .conclusion == \"cancelled\" or .conclusion == \"timed_out\")) | .id) // empty"
	else
		jq_filter="first(.workflow_runs[] | select(${workflow_match} and .conclusion == \"success\") | .id) // empty"
	fi

	gh api "repos/${GITHUB_REPOSITORY}/actions/runs?head_sha=${commit_sha}&per_page=${BUNDLE_WORKFLOW_RUNS_PER_PAGE}" |
		jq -r --arg wf "$workflow_key" "$jq_filter"
}

# Find the latest workflow run on a fallback branch (e.g. main).
# Usage: bundle_find_workflow_run_on_ref WORKFLOW_KEY FALLBACK_REF REQUIRE_SUCCESS
bundle_find_workflow_run_on_ref() {
	local workflow_key="$1"
	local fallback_ref="$2"
	local require_success="${3:-true}"

	local workflow_match
	local jq_filter
	# shellcheck disable=SC2016
	workflow_match='((.name | ascii_downcase) == ($wf | ascii_downcase)) or ((.path | split("/")[-1] | sub("\\.ya?ml$"; "") | ascii_downcase) == ($wf | ascii_downcase))'
	if [[ "$require_success" == "false" ]]; then
		jq_filter="first(.workflow_runs[] | select(${workflow_match} and .head_branch == \$branch and (.conclusion == \"success\" or .conclusion == \"failure\" or .conclusion == \"cancelled\" or .conclusion == \"timed_out\")) | .id) // empty"
	else
		jq_filter="first(.workflow_runs[] | select(${workflow_match} and .head_branch == \$branch and .conclusion == \"success\") | .id) // empty"
	fi

	gh api "repos/${GITHUB_REPOSITORY}/actions/runs?branch=${fallback_ref}&per_page=${BUNDLE_WORKFLOW_RUNS_PER_PAGE}" |
		jq -r --arg wf "$workflow_key" --arg branch "$fallback_ref" "$jq_filter"
}

# Resolve artifact ID from a workflow run.
# Usage: bundle_get_artifact_id RUN_ID ARTIFACT_NAME
bundle_get_artifact_id() {
	local run_id="$1"
	local artifact_name="$2"

	if [[ -z "$run_id" ]]; then
		return 0
	fi

	# shellcheck disable=SC2016
	gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}/artifacts" |
		jq -r --arg name "$artifact_name" \
			'first(.artifacts[] | select(.name == $name) | .id) // empty' \
			2>/dev/null || true
}

# Validate zip member paths and types before extraction (zip-slip / symlink defense).
# Usage: bundle_validate_zip_members TEMP_ZIP ARTIFACT_ID
bundle_validate_zip_members() {
	local temp_zip="$1"
	local artifact_id="$2"
	local entry line perms

	while IFS= read -r entry || [[ -n "$entry" ]]; do
		[[ -z "$entry" ]] && continue
		if [[ "$entry" == /* ]]; then
			log_error "Zip entry is absolute for artifact ${artifact_id}: ${entry}"
			return 1
		fi
		entry="${entry#./}"
		if [[ -z "$entry" ]]; then
			log_error "Zip entry is empty for artifact ${artifact_id}"
			return 1
		fi
		if [[ "$entry" == ".." || "$entry" == ../* || "$entry" == */../* || "$entry" == */.. ]]; then
			log_error "Zip entry contains path traversal for artifact ${artifact_id}: ${entry}"
			return 1
		fi
	done < <(unzip -Z1 "$temp_zip" 2>/dev/null) || {
		log_error "Failed to list zip members for artifact ${artifact_id}"
		return 1
	}

	while IFS= read -r line; do
		[[ "$line" == Archive:* || "$line" == *"Zip file size"* || "$line" == *"----"* ]] && continue
		[[ "$line" =~ ^[[:space:]]*[0-9]+[[:space:]]+files, ]] && break
		[[ -z "${line// /}" ]] && continue
		perms="${line%% *}"
		case "${perms:0:1}" in
		- | d)
			continue
			;;
		l)
			log_error "Zip entry is a symlink for artifact ${artifact_id}: ${line}"
			return 1
			;;
		'?')
			log_error "Zip entry has unsupported type for artifact ${artifact_id}: ${line}"
			return 1
			;;
		*)
			continue
			;;
		esac
	done < <(unzip -Zvl "$temp_zip" 2>/dev/null) || {
		log_error "Failed to inspect zip metadata for artifact ${artifact_id}"
		return 1
	}
}

# Download and extract an artifact zip into a destination directory.
# Usage: bundle_download_artifact ARTIFACT_ID DEST_DIR
bundle_download_artifact() {
	local artifact_id="$1"
	local dest_dir="$2"
	local temp_zip

	if [[ -z "$artifact_id" ]]; then
		return 1
	fi

	temp_zip="$(mktemp "${TMPDIR:-/tmp}/bundle-artifact.XXXXXX.zip")"
	if ! gh api "repos/${GITHUB_REPOSITORY}/actions/artifacts/${artifact_id}/zip" >"$temp_zip"; then
		log_error "Failed to download artifact ${artifact_id}"
		rm -f "$temp_zip"
		return 1
	fi
	if [[ ! -s "$temp_zip" ]]; then
		log_error "Downloaded artifact ${artifact_id} is empty"
		rm -f "$temp_zip"
		return 1
	fi
	if ! unzip -tq "$temp_zip" >/dev/null 2>&1; then
		log_error "Downloaded artifact ${artifact_id} is not a valid zip archive"
		rm -f "$temp_zip"
		return 1
	fi
	if ! bundle_validate_zip_members "$temp_zip" "$artifact_id"; then
		rm -f "$temp_zip"
		return 1
	fi
	mkdir -p "$dest_dir"
	if ! unzip -o -q "$temp_zip" -d "$dest_dir/"; then
		log_error "Failed to extract artifact ${artifact_id}"
		rm -f "$temp_zip"
		return 1
	fi
	rm -f "$temp_zip"
}

# Resolve and validate a manifest dest path under SITE_ROOT.
# Prints the absolute target directory on success.
# Usage: bundle_resolve_site_dest SITE_ROOT DEST_SUBDIR
bundle_resolve_site_dest() {
	local site_root="$1"
	local dest_subdir="$2"
	local site_root_abs target_dir

	if [[ -z "$dest_subdir" || "$dest_subdir" == "null" ]]; then
		log_error "Bundle dest is required"
		return 1
	fi
	if [[ "$dest_subdir" == /* ]]; then
		log_error "Bundle dest must be relative to site root: ${dest_subdir}"
		return 1
	fi
	if [[ "$dest_subdir" == *".."* ]]; then
		log_error "Bundle dest must not contain .. segments: ${dest_subdir}"
		return 1
	fi

	site_root_abs=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$site_root")
	target_dir=$(
		python3 -c 'import os, sys; print(os.path.realpath(os.path.join(sys.argv[1], sys.argv[2])))' \
			"$site_root_abs" "$dest_subdir"
	)

	case "$target_dir" in
	"$site_root_abs" | "$site_root_abs"/*)
		printf '%s\n' "$target_dir"
		return 0
		;;
	*)
		log_error "Bundle dest escapes site root: ${dest_subdir}"
		return 1
		;;
	esac
}

# Copy extracted artifact contents into SITE_ROOT/dest.
# Usage: bundle_copy_to_site SOURCE_DIR SITE_ROOT DEST_SUBDIR
bundle_copy_to_site() {
	local source_dir="$1"
	local site_root="$2"
	local dest_subdir="$3"
	local target_dir

	if [[ ! -d "$source_dir" ]] || [[ -z "$(ls -A "$source_dir" 2>/dev/null || true)" ]]; then
		return 1
	fi

	if ! target_dir=$(bundle_resolve_site_dest "$site_root" "$dest_subdir"); then
		return 1
	fi

	mkdir -p "$target_dir"
	cp -R "${source_dir}/." "$target_dir/"
}

__bundle_run_manifest_temp_root=""
__bundle_run_manifest_saved_return_cmd=""

__bundle_run_manifest_on_return() {
	rm -rf "${__bundle_run_manifest_temp_root:-}"
	__bundle_run_manifest_temp_root=""
	if [[ -n "$__bundle_run_manifest_saved_return_cmd" ]]; then
		eval "$__bundle_run_manifest_saved_return_cmd"
	else
		trap - RETURN
	fi
	__bundle_run_manifest_saved_return_cmd=""
}

# Process all manifest bundles.
# Requires: BUNDLE_MANIFEST_JSON, COMMIT_SHA, SITE_ROOT, GITHUB_REPOSITORY
# Optional: FALLBACK_REF, STRICT (true|false)
bundle_run_manifest() {
	local strict="${STRICT:-false}"
	local manifest_strict
	local bundle_count
	local files_bundled=0
	local warnings=0
	local temp_root

	if [[ -z "${BUNDLE_MANIFEST_JSON:-}" ]]; then
		log_error "BUNDLE_MANIFEST_JSON is not set"
		return 1
	fi

	: "${COMMIT_SHA:?COMMIT_SHA is required}"
	: "${SITE_ROOT:?SITE_ROOT is required}"
	: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

	if ! command -v gh >/dev/null 2>&1; then
		log_error "GitHub CLI (gh) is required but not found"
		return 1
	fi

	if ! command -v jq >/dev/null 2>&1; then
		log_error "jq is required but not found"
		return 1
	fi

	if ! command -v python3 >/dev/null 2>&1; then
		log_error "python3 is required but not found"
		return 1
	fi

	manifest_strict=$(jq -r '.strict // false' <<<"$BUNDLE_MANIFEST_JSON")
	if [[ "$manifest_strict" == "true" ]]; then
		strict=true
	fi

	bundle_count=$(jq '.bundles | length' <<<"$BUNDLE_MANIFEST_JSON")
	if ((bundle_count == 0)); then
		log_warn "Bundle manifest contains no entries"
		set_github_output "files-bundled" "0"
		set_github_output "bundles-applied" "0"
		set_github_output "bundle-warnings" "0"
		return 0
	fi

	temp_root="$(mktemp -d "${TMPDIR:-/tmp}/bundle-workflow-artifacts.XXXXXX")"
	__bundle_run_manifest_temp_root="$temp_root"
	__bundle_run_manifest_saved_return_cmd=$(trap -p RETURN 2>/dev/null || true)
	# shellcheck disable=SC2064 # Invoke file-scoped RETURN handler on function exit
	trap '__bundle_run_manifest_on_return' RETURN
	local applied=0
	local index
	for ((index = 0; index < bundle_count; index++)); do
		local bundle_id workflow artifact dest require_success run_id artifact_id
		local staging_dir staging_key="bundle-${index}" used_fallback=false

		bundle_id=$(jq -r ".bundles[$index].id // \"bundle-${index}\"" <<<"$BUNDLE_MANIFEST_JSON")
		workflow=$(jq -r ".bundles[$index].workflow" <<<"$BUNDLE_MANIFEST_JSON")
		artifact=$(jq -r ".bundles[$index].artifact" <<<"$BUNDLE_MANIFEST_JSON")
		dest=$(jq -r ".bundles[$index].dest" <<<"$BUNDLE_MANIFEST_JSON")
		require_success=$(jq -r '.bundles['"$index"'].require_success // true' <<<"$BUNDLE_MANIFEST_JSON")

		if [[ -z "$workflow" || "$workflow" == "null" ]]; then
			log_error "Bundle ${bundle_id}: workflow is required"
			((warnings++)) || true
			if [[ "$strict" == "true" ]]; then
				return 1
			fi
			continue
		fi
		if [[ -z "$artifact" || "$artifact" == "null" ]]; then
			log_error "Bundle ${bundle_id}: artifact is required"
			((warnings++)) || true
			if [[ "$strict" == "true" ]]; then
				return 1
			fi
			continue
		fi
		if [[ -z "$dest" || "$dest" == "null" ]]; then
			log_error "Bundle ${bundle_id}: dest is required"
			((warnings++)) || true
			if [[ "$strict" == "true" ]]; then
				return 1
			fi
			continue
		fi
		if ! bundle_resolve_site_dest "$SITE_ROOT" "$dest" >/dev/null; then
			log_warn "Bundle ${bundle_id}: invalid dest ${dest}"
			((warnings++)) || true
			if [[ "$strict" == "true" ]]; then
				return 1
			fi
			continue
		fi

		log_info "Bundle ${bundle_id}: resolving workflow ${workflow} for ${COMMIT_SHA}"
		run_id=$(bundle_find_workflow_run "$workflow" "$COMMIT_SHA" "$require_success")

		if [[ -z "$run_id" && -n "${FALLBACK_REF:-}" ]]; then
			log_info "Bundle ${bundle_id}: no run for commit; trying ${FALLBACK_REF}"
			run_id=$(bundle_find_workflow_run_on_ref "$workflow" "$FALLBACK_REF" "$require_success")
			if [[ -n "$run_id" ]]; then
				used_fallback=true
			fi
		fi

		if [[ -z "$run_id" ]]; then
			log_warn "Bundle ${bundle_id}: no workflow run found for ${workflow}"
			((warnings++)) || true
			if [[ "$strict" == "true" ]]; then
				return 1
			fi
			continue
		fi

		if [[ "$used_fallback" == "true" ]]; then
			log_info "Bundle ${bundle_id}: using fallback run ${run_id} from ${FALLBACK_REF}"
		fi

		artifact_id=$(bundle_get_artifact_id "$run_id" "$artifact")
		if [[ -z "$artifact_id" ]]; then
			log_warn "Bundle ${bundle_id}: artifact ${artifact} not found in run ${run_id}"
			((warnings++)) || true
			if [[ "$strict" == "true" ]]; then
				return 1
			fi
			continue
		fi

		staging_dir="${temp_root}/${staging_key}"
		mkdir -p "$staging_dir"
		if ! bundle_download_artifact "$artifact_id" "$staging_dir"; then
			log_warn "Bundle ${bundle_id}: failed to download artifact ${artifact_id}"
			((warnings++)) || true
			if [[ "$strict" == "true" ]]; then
				return 1
			fi
			continue
		fi

		if bundle_copy_to_site "$staging_dir" "$SITE_ROOT" "$dest"; then
			local copied
			copied=$(find "$staging_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
			files_bundled=$((files_bundled + copied))
			((applied++)) || true
			log_success "Bundle ${bundle_id}: copied ${copied} file(s) to ${SITE_ROOT}/${dest}"
		else
			log_warn "Bundle ${bundle_id}: no files copied to ${SITE_ROOT}/${dest}"
			((warnings++)) || true
			if [[ "$strict" == "true" ]]; then
				return 1
			fi
		fi
	done

	set_github_output "files-bundled" "$files_bundled"
	set_github_output "bundles-applied" "$applied"
	set_github_output "bundle-warnings" "$warnings"

	if [[ "$strict" == "true" && "$warnings" -gt 0 ]]; then
		return 1
	fi

	log_success "Bundled ${applied}/${bundle_count} manifest entries (${files_bundled} files)"
	return 0
}

export -f bundle_load_manifest bundle_find_workflow_run
export -f bundle_find_workflow_run_on_ref bundle_get_artifact_id
export -f bundle_validate_zip_members bundle_download_artifact
export -f bundle_resolve_site_dest bundle_copy_to_site bundle_run_manifest
