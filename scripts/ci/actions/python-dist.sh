#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Build and upload Python packages to PyPI (STEP dispatch)
#
# Environment variables:
#   STEP: preflight | validate | build | validate-dist | extract-dist-metadata |
#         set-published | summary
#   WORKING_DIRECTORY: Directory containing the package (default: .)
#   VERIFY_TAG_VERSION: Verify git tag matches pyproject.toml version
#   ENSURE_TAG_ON_DEFAULT_BRANCH: Verify tagged commit is on the default branch
#   DEFAULT_BRANCH: Default branch name (default: main)
#   PACKAGE_NAME: Package name (for summary)
#   PACKAGE_VERSION: Package version (for summary)
#   DRY_RUN: Whether this is a dry run
#   TEST_PYPI: Whether publishing to TestPyPI
#   PUBLISHED: Whether the package was published
#   VALIDATE_STRICT: When true, fail validate-dist if twine/uv cannot run twine check
set -euo pipefail

: "${STEP:?STEP is required}"
: "${WORKING_DIRECTORY:=.}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
source "$SCRIPT_DIR/../lib/actions.sh"
source "$SCRIPT_DIR/../lib/publish.sh"

_validate_working_directory() {
	local dir="${1:-.}"

	if [[ -z "$dir" || "$dir" == "/" || "$dir" == "~" || "$dir" == ~/* || "$dir" =~ ^~(/|$) ]]; then
		die "Refusing to use unsafe WORKING_DIRECTORY: ${dir:-<empty>}"
	fi

	if [[ -n "${HOME:-}" && ("$dir" == "$HOME" || "$dir" == "${HOME}/"*) ]]; then
		die "Refusing to use unsafe WORKING_DIRECTORY: ${dir}"
	fi

	if [[ ! -d "$dir" ]]; then
		die "WORKING_DIRECTORY does not exist: ${dir}"
	fi
}

_validate_working_directory "$WORKING_DIRECTORY"
cd "$WORKING_DIRECTORY"

# Prefix a path relative to the current working directory with OUTPUT_PREFIX
# (the caller's working-directory input, which the step already cd'ed into)
# so outputs resolve from the workspace root. "." and empty leave the path
# unchanged. Deliberately not WORKING_DIRECTORY: the build step reads that
# as a directory to enter and validates it against the current directory.
_workspace_relative() {
	local rel="$1"
	local wd="${OUTPUT_PREFIX:-.}"
	wd="${wd%/}"
	if [[ -z "$wd" || "$wd" == "." ]]; then
		printf '%s\n' "$rel"
	else
		printf '%s/%s\n' "$wd" "$rel"
	fi
}

case "$STEP" in
preflight)
	: "${VERIFY_TAG_VERSION:=false}"
	: "${ENSURE_TAG_ON_DEFAULT_BRANCH:=false}"
	: "${DEFAULT_BRANCH:=main}"

	if [[ "$VERIFY_TAG_VERSION" != "true" && "$ENSURE_TAG_ON_DEFAULT_BRANCH" != "true" ]]; then
		log_info "Preflight checks disabled, skipping"
		exit 0
	fi

	tag="${GITHUB_REF_NAME:-}"
	if [[ -z "$tag" ]]; then
		die "GITHUB_REF_NAME not set; cannot run tag preflight"
	fi

	if [[ "$VERIFY_TAG_VERSION" == "true" ]]; then
		version=$(extract_pypi_version ".") || die "Could not extract version from pyproject.toml"
		tag_stripped="${tag#v}"
		log_info "pyproject version: ${version} / tag: ${tag} (stripped: ${tag_stripped})"
		if [[ "$version" != "$tag_stripped" ]]; then
			die "Version mismatch: pyproject=${version} tag=${tag}"
		fi
		log_success "Tag version matches pyproject.toml"
	fi

	if [[ "$ENSURE_TAG_ON_DEFAULT_BRANCH" == "true" ]]; then
		git fetch --no-tags origin "${DEFAULT_BRANCH}:refs/remotes/origin/${DEFAULT_BRANCH}"
		ref="${GITHUB_REF:-refs/tags/${tag}}"
		tag_commit=$(git rev-parse "${ref}^{}")
		log_info "Tag ${tag} -> ${tag_commit}"
		if git merge-base --is-ancestor "$tag_commit" "origin/${DEFAULT_BRANCH}"; then
			log_success "Tag commit is on ${DEFAULT_BRANCH}"
		else
			die "Tag commit is not on ${DEFAULT_BRANCH}; aborting publish"
		fi
	fi
	;;

validate)
	log_info "Validating package metadata..."

	if [[ ! -f "pyproject.toml" ]]; then
		die "pyproject.toml not found in $WORKING_DIRECTORY"
	fi

	# Extract and validate version
	version=$(extract_pypi_version ".") || die "Could not extract version from pyproject.toml"
	# Python dists are PEP 440 by definition (1.2.3a1, not 1.2.3-alpha.1); the
	# SemVer validator stays for the non-Python callers.
	if ! validate_pep440_version_format "$version"; then
		die "Invalid version format: $version (expected canonical PEP 440)"
	fi

	# Extract name
	name=$(extract_pypi_name ".") || true
	if [[ -z "$name" ]]; then
		die "Could not extract package name from pyproject.toml"
	fi

	log_success "Package metadata valid: $name@$version"
	;;

build)
	log_info "Building Python package..."

	abs_pwd=$(pwd -P)
	if [[ "$abs_pwd" == "/" ]]; then
		die "Refusing to run build from filesystem root"
	fi

	repo_root=""
	if [[ -n "${GITHUB_WORKSPACE:-}" ]]; then
		repo_root=$(cd "$GITHUB_WORKSPACE" && pwd -P)
	elif git rev-parse --show-toplevel >/dev/null 2>&1; then
		repo_root=$(cd "$(git rev-parse --show-toplevel)" && pwd -P)
	fi
	if [[ -z "$repo_root" ]]; then
		die "Cannot determine repository root; refusing build cleanup"
	fi
	case "$abs_pwd" in
	"$repo_root" | "$repo_root"/*) ;;
	*)
		die "Refusing to build outside repository root: $abs_pwd (root: $repo_root)"
		;;
	esac

	# Clean previous builds (paths relative to WORKING_DIRECTORY after cd above)
	rm -rf dist/ build/
	shopt -s nullglob
	rm -rf ./*.egg-info/
	shopt -u nullglob

	# Extract version and name
	version=$(extract_pypi_version ".") || die "Could not extract version"
	name=$(extract_pypi_name ".") || die "Could not extract package name from pyproject.toml"
	if [[ -z "$name" ]]; then
		die "Could not extract package name from pyproject.toml"
	fi

	# Build using uv or python -m build
	if command -v uv >/dev/null 2>&1; then
		log_info "Running uv build..."
		uv build
	elif command -v python >/dev/null 2>&1; then
		log_info "uv not found, falling back to python -m build..."
		python -m build
	else
		die "Neither uv nor python found. Please install uv or python with build module."
	fi

	# Verify build output
	if [[ ! -d "dist" ]]; then
		die "Build failed: dist/ directory not created"
	fi

	wheel_count=$(find dist -name "*.whl" 2>/dev/null | wc -l)
	sdist_count=$(find dist -name "*.tar.gz" 2>/dev/null | wc -l)

	if ((wheel_count == 0 && sdist_count == 0)); then
		die "Build failed: no distribution files created"
	fi

	log_success "Build complete: $wheel_count wheel(s), $sdist_count sdist(s)"

	# List built files
	log_info "Built files:"
	ls -la dist/

	set_github_output "version" "$version"
	set_github_output "name" "$name"
	;;

validate-dist)
	log_info "Validating distribution files..."

	if [[ ! -d "dist" ]]; then
		die "dist/ directory not found"
	fi

	# validate_pypi_package runs twine when available, or provisions it via
	# `uv run --with twine twine check` (no `uv pip install --system` — PEP 668).
	if validate_pypi_package "dist"; then
		log_success "Distribution validation passed"
	else
		die "Distribution validation failed"
	fi
	;;

write-checksums)
	# SHA256SUMS next to the distributions, so the GitHub Release can attach a
	# manifest and a verifier can `sha256sum --check` (release-security
	# policy, section 1). Written after the attestation step so the manifest
	# is not itself an attestation subject. Only distribution files are
	# listed; the manifest never lists itself.
	if [[ ! -d "dist" ]]; then
		die "dist/ directory not found"
	fi
	mapfile -t dist_files < <(find dist -maxdepth 1 -type f \( -name '*.whl' -o -name '*.tar.gz' -o -name '*.zip' \) -exec basename {} \; | sort)
	if ((${#dist_files[@]} == 0)); then
		die "No distribution files in dist/ to checksum"
	fi
	if command -v sha256sum >/dev/null 2>&1; then
		(cd dist && sha256sum "${dist_files[@]}") >dist/SHA256SUMS
	else
		(cd dist && shasum -a 256 "${dist_files[@]}") >dist/SHA256SUMS
	fi
	log_success "Wrote dist/SHA256SUMS for ${#dist_files[@]} file(s)"
	# Workspace-relative, so a caller resolving the output from the
	# workspace root finds it under a non-default working directory too.
	set_github_output "checksums-path" "$(_workspace_relative "dist/SHA256SUMS")"
	;;

stage-sidecars)
	# The python-dist artifact carries dist/ plus sidecar files that must not
	# reach twine (`twine check` and `twine upload` reject a non-distribution
	# file in packages-dir). Move them beside dist/ and expose their paths.
	# Staged into a dedicated directory owned by this step, so a caller's
	# own SHA256SUMS (or a directory of that name) is never overwritten.
	checksums_path=""
	if [[ -f "dist/SHA256SUMS" ]]; then
		# mkdir -p, never rm -rf: a second call in the same job must not wipe
		# what an earlier call staged; only this manifest is replaced.
		mkdir -p ".lgtm-ci-sidecars"
		mv -f "dist/SHA256SUMS" ".lgtm-ci-sidecars/SHA256SUMS"
		checksums_path="$(_workspace_relative ".lgtm-ci-sidecars/SHA256SUMS")"
		log_info "Staged dist/SHA256SUMS -> ${checksums_path} (kept out of packages-dir)"
	fi
	set_github_output "checksums-path" "$checksums_path"
	;;

verify-attestations)
	# Every distribution file must carry a valid GitHub build-provenance
	# attestation from this repository before the caller's upload step runs
	# (release-security policy, section 2). Fails closed: a missing gh, a
	# missing attestation or a signer mismatch all stop the job.
	: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
	: "${SIGNER_WORKFLOW:=}"
	if [[ ! -d "dist" ]]; then
		die "dist/ directory not found"
	fi
	if ! command -v gh >/dev/null 2>&1; then
		die "gh is required to verify attestations"
	fi
	mapfile -t dist_files < <(find dist -maxdepth 1 -type f \( -name '*.whl' -o -name '*.tar.gz' -o -name '*.zip' \) | sort)
	if ((${#dist_files[@]} == 0)); then
		die "No distribution files in dist/ to verify"
	fi
	verify_args=(--repo "$GITHUB_REPOSITORY")
	if [[ -n "$SIGNER_WORKFLOW" ]]; then
		verify_args+=(--signer-workflow "$SIGNER_WORKFLOW")
	fi
	failed=0
	for dist_file in "${dist_files[@]}"; do
		if gh attestation verify "$dist_file" "${verify_args[@]}"; then
			log_success "Attestation verified: $dist_file"
		else
			log_error "No valid attestation for $dist_file (repo ${GITHUB_REPOSITORY}${SIGNER_WORKFLOW:+, signer ${SIGNER_WORKFLOW}})"
			failed=$((failed + 1))
		fi
	done
	if ((failed > 0)); then
		die "$failed of ${#dist_files[@]} distribution file(s) lack a valid attestation; nothing may be uploaded"
	fi
	log_success "All ${#dist_files[@]} distribution file(s) carry a valid attestation"
	set_github_output "attestations-verified" "${#dist_files[@]}"
	;;

set-published)
	set_github_output "published" "true"
	;;

extract-dist-metadata)
	name=""
	version=""

	if [[ -f "pyproject.toml" ]]; then
		version=$(extract_pypi_version ".") || true
		name=$(extract_pypi_name ".") || true
	fi

	if [[ (-z "$name" || -z "$version") && -d "dist" ]]; then
		wheel_file=$(find dist -name "*.whl" -print -quit 2>/dev/null || true)
		if [[ -n "$wheel_file" ]]; then
			wheel_basename=$(basename "$wheel_file")
			wheel_name="${wheel_basename%%-*}"
			wheel_remainder="${wheel_basename#*-}"
			wheel_version="${wheel_remainder%%-*}"
			name="${name:-${wheel_name//_/-}}"
			version="${version:-$wheel_version}"
		else
			sdist_file=$(find dist \( -name "*.tar.gz" -o -name "*.zip" \) -print -quit 2>/dev/null || true)
			if [[ -n "$sdist_file" ]]; then
				sdist_basename=$(basename "$sdist_file")
				sdist_basename="${sdist_basename%.tar.gz}"
				sdist_basename="${sdist_basename%.zip}"
				sdist_version="${sdist_basename##*-}"
				sdist_name="${sdist_basename%-*}"
				name="${name:-${sdist_name//_/-}}"
				version="${version:-$sdist_version}"
			fi
		fi
	fi

	set_github_output "name" "${name:-unknown}"
	set_github_output "version" "${version:-unknown}"
	;;

summary)
	: "${PACKAGE_NAME:=unknown}"
	: "${PACKAGE_VERSION:=unknown}"
	: "${DRY_RUN:=false}"
	: "${TEST_PYPI:=false}"
	: "${PUBLISHED:=false}"

	add_github_summary "## PyPI Publishing"
	add_github_summary ""
	add_github_summary "| Property | Value |"
	add_github_summary "| -------- | ----- |"
	add_github_summary "| Package | $PACKAGE_NAME |"
	add_github_summary "| Version | $PACKAGE_VERSION |"

	if [[ "$TEST_PYPI" == "true" ]]; then
		add_github_summary "| Registry | TestPyPI |"
	else
		add_github_summary "| Registry | PyPI |"
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		add_github_summary "| Status | :construction: Dry Run (not published) |"
	elif [[ "$PUBLISHED" == "true" ]]; then
		add_github_summary "| Status | :white_check_mark: Published |"
		if [[ "$TEST_PYPI" == "true" ]]; then
			add_github_summary "| URL | https://test.pypi.org/project/$PACKAGE_NAME/$PACKAGE_VERSION/ |"
		else
			add_github_summary "| URL | https://pypi.org/project/$PACKAGE_NAME/$PACKAGE_VERSION/ |"
		fi
	else
		add_github_summary "| Status | :x: Not Published |"
	fi

	# List distribution files if they exist
	if [[ -d "dist" ]]; then
		add_github_summary ""
		add_github_summary "### Distribution Files"
		add_github_summary ""
		add_github_summary '```'
		while IFS= read -r line; do
			add_github_summary "$line"
		done < <(find dist/ -type f -ls)
		add_github_summary '```'
	fi
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
