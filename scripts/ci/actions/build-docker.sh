#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Build and push Docker images with multi-platform support
#
# Required environment variables:
#   STEP - Which step to run: setup, build, push, metadata, parse-tags, summary,
#          set-output-digest, classify, record-digest, smoke-test,
#          merge-manifests, cleanup-staging
#
# Optional environment variables:
#   CONTEXT - Build context path (default: .)
#   FILE - Dockerfile path (default: Dockerfile)
#   PLATFORMS - Target platforms (default: linux/amd64,linux/arm64)
#   REGISTRY - Registry URL (default: ghcr.io)
#   IMAGE_NAME - Image name (default: from GITHUB_REPOSITORY)
#   TAGS - Additional tags (comma-separated)
#   VERSION - Version for semver tags
#   PUSH - Push to registry (default: false)
#   LOAD - Load into local docker (default: false)
#   BUILD_ARGS - Build arguments (comma-separated key=value)
#                Note: Values containing commas are not supported
#   LABELS - Additional labels (comma-separated key=value)
#            Note: Values containing commas are not supported
#   CACHE_FROM - Cache sources
#   CACHE_TO - Cache destinations

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/docker.sh
source "$SCRIPT_DIR/../lib/docker.sh"

case "$STEP" in
setup)
	log_info "Setting up Docker environment..."

	# Check Docker availability
	if ! check_docker_available; then
		die "Docker is not available or not running"
	fi

	# Check Buildx availability
	if ! check_buildx_available; then
		die "Docker Buildx is not available"
	fi

	log_info "Docker version: $(docker --version)"
	log_info "Buildx version: $(docker buildx version)"

	log_success "Docker environment ready"
	;;

build)
	: "${CONTEXT:=.}"
	: "${FILE:=Dockerfile}"
	: "${PLATFORMS:=linux/amd64,linux/arm64}"
	: "${REGISTRY:=ghcr.io}"
	: "${IMAGE_NAME:=${GITHUB_REPOSITORY:-}}"
	: "${TAGS:=}"
	: "${VERSION:=}"
	: "${PUSH:=false}"
	: "${LOAD:=false}"
	: "${BUILD_ARGS:=}"
	: "${LABELS:=}"
	: "${CACHE_FROM:=}"
	: "${CACHE_TO:=}"

	# Validate required inputs
	if [[ -z "$IMAGE_NAME" ]]; then
		die "IMAGE_NAME is required (or set GITHUB_REPOSITORY)"
	fi

	# Construct full image name
	full_image="${REGISTRY}/${IMAGE_NAME}"

	log_info "Building image: $full_image"
	log_info "Context: $CONTEXT"
	log_info "Dockerfile: $FILE"
	log_info "Platforms: $PLATFORMS"

	# Build docker buildx command
	BUILD_CMD=("docker" "buildx" "build")
	BUILD_CMD+=("--file" "$FILE")

	# Add platforms (--load only supports single-platform builds)
	if [[ "$LOAD" != "true" ]]; then
		BUILD_CMD+=("--platform" "$PLATFORMS")
	fi

	# Generate and add tags
	all_tags=()

	# Add SHA tag
	sha_tag=$(generate_sha_tag 2>/dev/null || echo "")
	if [[ -n "$sha_tag" ]]; then
		all_tags+=("${full_image}:${sha_tag}")
	fi

	# Add version tags if provided
	if [[ -n "$VERSION" ]]; then
		while IFS= read -r tag; do
			all_tags+=("${full_image}:${tag}")
		done < <(generate_semver_tags "$VERSION" 2>/dev/null || true)
	fi

	# Add branch tag
	branch_tag=$(generate_branch_tag 2>/dev/null || echo "")
	if [[ -n "$branch_tag" ]]; then
		all_tags+=("${full_image}:${branch_tag}")
	fi

	# Add custom tags
	if [[ -n "$TAGS" ]]; then
		IFS=',' read -ra custom_tags <<<"$TAGS"
		for tag in "${custom_tags[@]}"; do
			tag=$(echo "$tag" | xargs) # Trim whitespace
			if [[ -n "$tag" ]]; then
				# Add registry prefix if not present
				if [[ "$tag" != *":"* ]]; then
					all_tags+=("${full_image}:${tag}")
				else
					all_tags+=("$tag")
				fi
			fi
		done
	fi

	# Add tags to command
	for tag in "${all_tags[@]}"; do
		BUILD_CMD+=("--tag" "$tag")
	done

	# Add build args
	if [[ -n "$BUILD_ARGS" ]]; then
		IFS=',' read -ra args <<<"$BUILD_ARGS"
		for arg in "${args[@]}"; do
			BUILD_CMD+=("--build-arg" "$arg")
		done
	fi

	# Add labels
	if [[ -n "$LABELS" ]]; then
		IFS=',' read -ra label_args <<<"$LABELS"
		for label in "${label_args[@]}"; do
			BUILD_CMD+=("--label" "$label")
		done
	fi

	# Add OCI labels
	BUILD_CMD+=("--label" "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY:-unknown}")
	BUILD_CMD+=("--label" "org.opencontainers.image.revision=${GITHUB_SHA:-unknown}")
	BUILD_CMD+=("--label" "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)")

	# Add cache configuration
	if [[ -n "$CACHE_FROM" ]]; then
		BUILD_CMD+=("--cache-from" "$CACHE_FROM")
	fi
	if [[ -n "$CACHE_TO" ]]; then
		BUILD_CMD+=("--cache-to" "$CACHE_TO")
	fi

	# Add push/load flags
	if [[ "$PUSH" == "true" ]]; then
		BUILD_CMD+=("--push")
	elif [[ "$LOAD" == "true" ]]; then
		BUILD_CMD+=("--load")
	fi

	# Add context
	BUILD_CMD+=("$CONTEXT")

	# Log command without sensitive args (build-args and labels may contain secrets)
	safe_cmd=()
	skip_next=0
	for arg in "${BUILD_CMD[@]}"; do
		if [[ "$skip_next" -eq 1 ]]; then
			# Skip the secret value following --build-arg or --label
			skip_next=0
			continue
		elif [[ "$arg" == "--build-arg" ]] || [[ "$arg" == "--label" ]]; then
			safe_cmd+=("$arg" "[REDACTED]")
			skip_next=1
		else
			safe_cmd+=("$arg")
		fi
	done
	log_info "Running: ${safe_cmd[*]}"

	# Execute build
	exit_code=0
	"${BUILD_CMD[@]}" || exit_code=$?

	# Set outputs
	set_github_output "exit-code" "$exit_code"

	# Output tags as newline-separated list
	tags_output=$(printf '%s\n' "${all_tags[@]}")
	set_github_output_multiline "tags" "$tags_output"

	if [[ $exit_code -eq 0 ]]; then
		log_success "Build completed successfully"
	else
		log_error "Build failed with exit code: $exit_code"
	fi

	exit "$exit_code"
	;;

push)
	: "${REGISTRY:=ghcr.io}"
	: "${IMAGE_NAME:=${GITHUB_REPOSITORY:-}}"
	: "${TAGS:=}"

	log_info "Pushing image tags..."

	# Parse tags (handle both newline and comma-separated formats)
	while IFS= read -r tag; do
		tag=$(echo "$tag" | xargs) # Trim whitespace
		if [[ -n "$tag" ]]; then
			log_info "Pushing: $tag"
			docker push "$tag"
		fi
	done < <(printf '%s\n' "$TAGS" | tr ',' '\n')

	log_success "Push completed"
	;;

metadata)
	# Extract digest from a built image using a concrete tag
	: "${REGISTRY:=ghcr.io}"
	: "${IMAGE_NAME:=${GITHUB_REPOSITORY:-}}"
	: "${BUILT_TAGS:=}"

	log_info "Extracting image metadata..."

	# Parse first tag from newline-separated list
	first_tag=$(echo "$BUILT_TAGS" | head -1)
	fmt='{{.Manifest.Digest}}'

	if [[ -n "$first_tag" ]]; then
		log_info "Using tag: $first_tag"
		digest=$(docker buildx imagetools inspect "$first_tag" --format "$fmt" 2>/dev/null || echo "")
	else
		# Fallback to image:latest if no tags available
		full_image="${REGISTRY}/${IMAGE_NAME}:latest"
		log_info "No tags found, falling back to: $full_image"
		digest=$(docker buildx imagetools inspect "$full_image" --format "$fmt" 2>/dev/null || echo "")
	fi

	set_github_output "digest" "$digest"

	if [[ -n "$digest" ]]; then
		log_success "Extracted digest: $digest"
	else
		log_warn "Could not extract digest"
	fi
	;;

parse-tags)
	# Convert comma-separated tags to metadata-action format for docker/metadata-action
	: "${INPUT_TAGS:=}"

	if [[ -z "$INPUT_TAGS" ]]; then
		set_github_output "tags" ""
		exit 0
	fi

	# Convert comma-separated tags to metadata-action format
	# Trim whitespace and filter empty entries
	tags_list=""
	IFS=',' read -ra tag_array <<<"$INPUT_TAGS"
	for tag in "${tag_array[@]}"; do
		tag=$(echo "$tag" | xargs) # Trim whitespace
		if [[ -n "$tag" ]]; then
			tags_list="${tags_list}type=raw,value=${tag}"$'\n'
		fi
	done

	# Output using heredoc for multiline
	set_github_output_multiline "tags" "$tags_list"

	log_info "Parsed tags for metadata-action"
	;;

set-output-digest)
	# Write a pre-computed digest to GITHUB_OUTPUT.
	#
	# Required environment variables:
	#   DIGEST - Image digest (e.g. sha256:abc123...)
	: "${DIGEST:?DIGEST is required}"
	set_github_output "digest" "${DIGEST}"
	log_info "Digest: ${DIGEST}"
	;;

classify)
	# Classify platforms and determine build strategy.
	#
	# Required environment variables:
	#   PLATFORMS  - Comma-separated list of target platforms
	#   PUSH       - Whether images will be pushed ("true"/"false")
	#
	# Optional environment variables:
	#   RUNNER_MAP        - JSON object mapping platform → runner label (default: "{}")
	#                       Platforms not in the map default to ubuntu-24.04 with QEMU.
	#                       Example: {"linux/arm64":"ubuntu-24.04-arm"}
	#   SMOKE_TEST        - Smoke-test shorthand command (validated only; not used here).
	#   SMOKE_TEST_SCRIPT - Smoke-test script path (validated only; not used here).
	#                       SMOKE_TEST and SMOKE_TEST_SCRIPT are mutually exclusive.
	#
	# Outputs:
	#   use-split - "true" when split per-platform build should be used
	#   matrix    - JSON array of {platform, runner, slug, qemu} entries
	: "${PLATFORMS:?PLATFORMS is required}"
	: "${PUSH:?PUSH is required}"
	: "${RUNNER_MAP:={}}"
	: "${SMOKE_TEST:=}"
	: "${SMOKE_TEST_SCRIPT:=}"

	# Mutex: smoke-test and smoke-test-script cannot both be set
	if [[ -n "$SMOKE_TEST" && -n "$SMOKE_TEST_SCRIPT" ]]; then
		die "smoke-test and smoke-test-script are mutually exclusive (set at most one)"
	fi

	# Validate RUNNER_MAP is parseable JSON
	if ! echo "$RUNNER_MAP" | jq empty 2>/dev/null; then
		die "RUNNER_MAP is not valid JSON: ${RUNNER_MAP}"
	fi

	# Parse comma-separated platforms into array, trimming whitespace
	platforms=()
	while IFS= read -r p; do
		p=$(echo "$p" | xargs)
		[[ -n "$p" ]] && platforms+=("$p")
	done < <(echo "$PLATFORMS" | tr ',' '\n')

	# Deduplicate platform entries (preserve order, drop repeats)
	declare -A _seen_platforms=()
	deduped_platforms=()
	for p in "${platforms[@]}"; do
		if [[ -z "${_seen_platforms[$p]+x}" ]]; then
			_seen_platforms[$p]=1
			deduped_platforms+=("$p")
		fi
	done
	platforms=("${deduped_platforms[@]}")
	unset _seen_platforms deduped_platforms

	# Fail fast on empty/whitespace-only PLATFORMS input
	if [[ "${#platforms[@]}" -eq 0 ]]; then
		die "PLATFORMS is empty or contains only whitespace"
	fi

	# push=false → always use the QEMU build job (imagetools requires a registry)
	if [[ "$PUSH" != "true" ]]; then
		set_github_output "use-split" "false"
		set_github_output "matrix" "[]"
		log_info "Split disabled: push=${PUSH}"
		exit 0
	fi

	# Single platform: use split only if a native runner is mapped for it
	if [[ "${#platforms[@]}" -lt 2 ]]; then
		_single="${platforms[0]}"
		_mapped=$(echo "$RUNNER_MAP" | jq -r --arg p "$_single" '.[$p] // empty')
		if [[ -z "$_mapped" ]]; then
			set_github_output "use-split" "false"
			set_github_output "matrix" "[]"
			log_info "Split disabled: single platform '${_single}' has no runner mapping"
			exit 0
		fi
		log_info "Split enabled: single platform '${_single}' mapped to runner '${_mapped}'"
		unset _single _mapped
	fi

	# Build matrix JSON array
	matrix_json="[]"
	for platform in "${platforms[@]}"; do
		# Resolve runner from map; default to ubuntu-24.04
		runner=$(echo "$RUNNER_MAP" | jq -r --arg p "$platform" '.[$p] // "ubuntu-24.04"')

		# Generate slug: replace all / with - (e.g. linux/arm/v7 → linux-arm-v7)
		slug=$(echo "$platform" | tr '/' '-')

		# Determine runner architecture from label
		runner_arch="amd64"
		if [[ "$runner" == *"-arm"* ]]; then
			runner_arch="arm64"
		fi

		# Extract platform architecture (second path component, strip variant)
		platform_arch="${platform#*/}"       # linux/arm/v7 → arm/v7
		platform_arch="${platform_arch%%/*}" # arm/v7 → arm

		# QEMU not needed when runner and platform architectures match
		qemu=true
		if [[ "$runner_arch" == "amd64" && "$platform_arch" == "amd64" ]]; then
			qemu=false
		elif [[ "$runner_arch" == "arm64" && "$platform_arch" == "arm64" ]]; then
			qemu=false
		fi

		# Build JSON entry and append to matrix array
		entry=$(jq -n \
			--arg platform "$platform" \
			--arg runner "$runner" \
			--arg slug "$slug" \
			--argjson qemu "$qemu" \
			'{platform: $platform, runner: $runner, slug: $slug, qemu: $qemu}')
		matrix_json=$(echo "$matrix_json" | jq --argjson e "$entry" '. + [$e]')
	done

	set_github_output "use-split" "true"
	set_github_output "matrix" "$(echo "$matrix_json" | jq -c .)"
	log_info "Split enabled: ${#platforms[@]} platform(s)"
	for platform in "${platforms[@]}"; do
		log_info "  ${platform}"
	done
	;;

record-digest)
	# Persist a build-push-action digest to an artifact-friendly path.
	#
	# Required environment variables:
	#   DIGEST      - Image digest emitted by build-push-action (sha256:...)
	#   DIGEST_FILE - Absolute path to write the digest to
	: "${DIGEST:?DIGEST is required}"
	: "${DIGEST_FILE:?DIGEST_FILE is required}"

	if ! [[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
		die "DIGEST is not a valid sha256 digest: ${DIGEST}"
	fi

	mkdir -p "$(dirname "$DIGEST_FILE")"
	printf '%s' "$DIGEST" >"$DIGEST_FILE"
	log_info "Recorded digest to ${DIGEST_FILE}"
	;;

smoke-test)
	# Run a smoke test against a per-platform staging image.
	# Pulls by immutable digest (IMAGE@sha256:...) to avoid TOCTOU between
	# the build and verify jobs.
	#
	# Required environment variables:
	#   REGISTRY    - Container registry URL
	#   IMAGE_NAME  - Registry-relative image name
	#   PLATFORM    - Target platform (e.g. linux/arm64)
	#   DIGEST_FILE - Path to a file containing the sha256:... digest of the
	#                 staging image (produced by the `record-digest` step)
	#
	# Optional environment variables (mutually exclusive; at least one required):
	#   SMOKE_TEST        - Shorthand command + args; word-split into `docker run`
	#   SMOKE_TEST_SCRIPT - Path to caller-owned script; receives IMAGE, PLATFORM,
	#                       REGISTRY in the environment and owns the docker run
	: "${REGISTRY:?REGISTRY is required}"
	: "${IMAGE_NAME:?IMAGE_NAME is required}"
	: "${PLATFORM:?PLATFORM is required}"
	: "${DIGEST_FILE:?DIGEST_FILE is required}"
	: "${SMOKE_TEST:=}"
	: "${SMOKE_TEST_SCRIPT:=}"

	if [[ -n "$SMOKE_TEST" && -n "$SMOKE_TEST_SCRIPT" ]]; then
		die "SMOKE_TEST and SMOKE_TEST_SCRIPT are mutually exclusive"
	fi
	if [[ -z "$SMOKE_TEST" && -z "$SMOKE_TEST_SCRIPT" ]]; then
		die "One of SMOKE_TEST or SMOKE_TEST_SCRIPT is required"
	fi
	if [[ ! -s "$DIGEST_FILE" ]]; then
		die "DIGEST_FILE missing or empty: ${DIGEST_FILE}"
	fi

	digest=$(<"$DIGEST_FILE")
	if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
		die "Invalid digest in ${DIGEST_FILE}: ${digest}"
	fi

	IMAGE="${REGISTRY}/${IMAGE_NAME}@${digest}"
	export IMAGE

	echo "::group::Pulling ${IMAGE} (${PLATFORM})"
	docker pull --platform "${PLATFORM}" "${IMAGE}"
	echo "::endgroup::"

	if [[ -n "$SMOKE_TEST_SCRIPT" ]]; then
		if [[ ! -f "$SMOKE_TEST_SCRIPT" ]]; then
			echo "::error::smoke-test-script not found: ${SMOKE_TEST_SCRIPT}"
			exit 1
		fi
		echo "::group::${SMOKE_TEST_SCRIPT} (IMAGE=${IMAGE} PLATFORM=${PLATFORM})"
		chmod +x "$SMOKE_TEST_SCRIPT"
		"./${SMOKE_TEST_SCRIPT#./}"
		echo "::endgroup::"
	else
		echo "::group::docker run --rm --platform ${PLATFORM} ${IMAGE} ${SMOKE_TEST}"
		# Intentionally word-split SMOKE_TEST so callers can pass flags+args
		# shellcheck disable=SC2086
		docker run --rm --platform "${PLATFORM}" "${IMAGE}" ${SMOKE_TEST}
		echo "::endgroup::"
	fi
	;;

merge-manifests)
	# Assemble a multi-arch manifest list from per-platform staging images.
	#
	# Required environment variables:
	#   MATRIX     - JSON matrix from classify step (array of {platform, runner, slug, qemu})
	#   REGISTRY   - Container registry URL
	#   IMAGE_NAME - Registry-relative image name
	#   RUN_ID     - GitHub Actions run ID used to locate staging tags
	#   TARGET_TAGS - Newline-separated list of final tags to create
	: "${MATRIX:?MATRIX is required}"
	: "${REGISTRY:?REGISTRY is required}"
	: "${IMAGE_NAME:?IMAGE_NAME is required}"
	: "${RUN_ID:?RUN_ID is required}"
	: "${TARGET_TAGS:?TARGET_TAGS is required}"

	MERGE_CMD=("docker" "buildx" "imagetools" "create")

	while IFS= read -r tag; do
		tag=$(echo "$tag" | xargs)
		[[ -n "$tag" ]] && MERGE_CMD+=("--tag" "$tag")
	done <<<"$TARGET_TAGS"

	# Validate at least one --tag was appended (TARGET_TAGS was not all whitespace)
	if [[ "${#MERGE_CMD[@]}" -le 4 ]]; then
		log_error "No valid tags found in TARGET_TAGS — cannot create manifest"
		exit 1
	fi

	# Add per-platform staging images as sources (referenced by staging tag)
	while IFS= read -r slug; do
		[[ -n "$slug" ]] && MERGE_CMD+=("${REGISTRY}/${IMAGE_NAME}:build-${RUN_ID}-${slug}")
	done < <(echo "$MATRIX" | jq -r '.[].slug')

	platform_count=$(echo "$MATRIX" | jq 'length')
	log_info "Merging ${platform_count} platform(s) into manifest..."
	"${MERGE_CMD[@]}"
	log_success "Multi-arch manifest created"
	;;

cleanup-staging)
	# Delete per-platform staging manifests from GHCR after a multi-arch merge.
	# Uses the GitHub Packages API; skips non-GHCR registries.
	#
	# Required environment variables:
	#   IMAGE_NAME - Registry-relative image name (e.g. org/repo or org/group/repo)
	#   RUN_ID     - GitHub Actions run ID used to construct staging tag names
	#   GH_TOKEN   - GitHub token with packages:delete permission
	#   MATRIX     - JSON matrix from classify step (array of {platform, runner, slug, qemu})
	: "${IMAGE_NAME:?IMAGE_NAME is required}"
	: "${RUN_ID:?RUN_ID is required}"
	: "${GH_TOKEN:?GH_TOKEN is required}"
	: "${MATRIX:?MATRIX is required}"

	# Parse owner and package name; URL-encode nested slashes
	pkg_owner="${IMAGE_NAME%%/*}"
	pkg_name="${IMAGE_NAME#*/}"
	pkg_name_encoded="${pkg_name//\//%2F}"

	while IFS= read -r slug; do
		[[ -z "$slug" ]] && continue
		tag="build-${RUN_ID}-${slug}"
		log_info "Looking up staging manifest: ${tag}"

		# Prefer org endpoint; fall back to user endpoint for personal repos
		version_id=$(
			gh api "orgs/${pkg_owner}/packages/container/${pkg_name_encoded}/versions" \
				--paginate \
				--jq ".[] | select(.metadata.container.tags[]? == \"${tag}\") | .id" \
				2>/dev/null ||
				gh api "user/packages/container/${pkg_name_encoded}/versions" \
					--paginate \
					--jq ".[] | select(.metadata.container.tags[]? == \"${tag}\") | .id" \
					2>/dev/null ||
				true
		)

		if [[ -n "${version_id}" ]]; then
			deleted=false
			if gh api --method DELETE \
				"orgs/${pkg_owner}/packages/container/${pkg_name_encoded}/versions/${version_id}" \
				2>/dev/null; then
				deleted=true
			elif gh api --method DELETE \
				"user/packages/container/${pkg_name_encoded}/versions/${version_id}" \
				2>/dev/null; then
				deleted=true
			fi
			if [[ "$deleted" == true ]]; then
				log_success "Deleted staging manifest: ${tag}"
			else
				log_warn "Failed to delete staging manifest: ${tag} (version ${version_id})"
			fi
		else
			log_warn "Could not locate staging manifest version for tag ${tag} — skipping deletion"
		fi
	done < <(echo "$MATRIX" | jq -r '.[].slug')
	;;

summary)
	: "${IMAGE_NAME:=}"
	: "${TAGS:=}"
	: "${PLATFORMS:=}"
	: "${PUSH:=false}"

	add_github_summary "## Docker Build Results"
	add_github_summary ""

	add_github_summary "| Property | Value |"
	add_github_summary "|----------|-------|"
	add_github_summary "| Image | \`$IMAGE_NAME\` |"
	add_github_summary "| Platforms | \`$PLATFORMS\` |"
	add_github_summary "| Pushed | $PUSH |"
	add_github_summary ""

	if [[ -n "$TAGS" ]]; then
		add_github_summary "### Tags"
		add_github_summary ""
		# TAGS is newline-separated, read into array properly
		readarray -t tag_array <<<"$TAGS"
		for tag in "${tag_array[@]}"; do
			# Trim whitespace
			tag=$(echo "$tag" | xargs)
			if [[ -n "$tag" ]]; then
				add_github_summary "- \`$tag\`"
			fi
		done
	fi

	add_github_summary ""
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
