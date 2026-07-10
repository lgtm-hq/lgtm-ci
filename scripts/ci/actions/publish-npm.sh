#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Build and publish Node.js packages to npm
#
# Environment variables:
#   STEP: validate | build | publish | summary
#   WORKING_DIRECTORY: Directory containing the package (default: .)
#   DIST_TAG: npm dist-tag (default: latest)
#   PROVENANCE: Enable provenance attestation (default: true)
#   ACCESS: Package access level (default: public)
#   NODE_AUTH_TOKEN: Optional legacy npm token. When unset, publish uses
#     OIDC trusted publishing (requires id-token: write and npm ≥ 11.5.1).
#
# Policy:
#   - Prefer Node 24+ (bundled npm ≥ 11.5.1) for trusted publishing.
#   - Never run `npm install -g npm` / in-place self-upgrade: it corrupts the
#     Actions toolcache and breaks `npm publish --provenance` (missing sigstore).
#   - Under trusted publishing, provenance is automatic; --provenance is still
#     passed when PROVENANCE=true as explicit intent.
set -euo pipefail

: "${STEP:?STEP is required}"
: "${WORKING_DIRECTORY:=.}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
source "$SCRIPT_DIR/../lib/actions.sh"
source "$SCRIPT_DIR/../lib/publish.sh"

# Change to working directory
cd "$WORKING_DIRECTORY"

# Compare dotted numeric versions (major.minor.patch...). Returns 0 if $1 >= $2.
_npm_version_ge() {
	local IFS=.
	# shellcheck disable=SC2206 # intentional word-split on dotted versions
	local -a left=($1) right=($2)
	local i max=${#left[@]}
	if [[ ${#right[@]} -gt $max ]]; then
		max=${#right[@]}
	fi
	for ((i = 0; i < max; i++)); do
		local l=${left[i]:-0}
		local r=${right[i]:-0}
		if ((l > r)); then
			return 0
		fi
		if ((l < r)); then
			return 1
		fi
	done
	return 0
}

# Remove setup-node registry _authToken lines so OIDC trusted publishing can run.
_strip_npmrc_auth_tokens() {
	local npmrc tmp
	for npmrc in "${NPM_CONFIG_USERCONFIG:-}" "${HOME}/.npmrc" ".npmrc"; do
		[[ -n "$npmrc" && -f "$npmrc" ]] || continue
		if grep -q '_authToken' "$npmrc"; then
			tmp="$(mktemp)"
			# Drop authToken entries only; keep registry / always-auth lines.
			# grep -v exits 1 when every line matched (file becomes empty) — tolerate that.
			grep -v '_authToken' "$npmrc" >"$tmp" || true
			mv "$tmp" "$npmrc"
			log_info "Stripped _authToken from ${npmrc} for OIDC trusted publishing"
		fi
	done
}

case "$STEP" in
validate)
	log_info "Validating package.json..."

	if [[ ! -f "package.json" ]]; then
		die "package.json not found in $WORKING_DIRECTORY"
	fi

	if ! validate_npm_package "."; then
		die "package.json validation failed"
	fi

	# Check for required fields for publishing
	name=$(grep -E '^[[:space:]]*"name"[[:space:]]*:' package.json | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/')
	version=$(extract_npm_version ".") || die "Could not extract version"

	log_success "Package valid: $name@$version"
	;;

build)
	log_info "Building and packing npm package..."

	# Extract metadata
	name=$(grep -E '^[[:space:]]*"name"[[:space:]]*:' package.json | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/')
	version=$(extract_npm_version ".") || die "Could not extract version"

	# Detect package manager once based on lockfile
	pm="npm"
	if [[ -f "bun.lockb" ]] || [[ -f "bun.lock" ]]; then
		pm="bun"
	elif [[ -f "pnpm-lock.yaml" ]]; then
		pm="pnpm"
	elif [[ -f "yarn.lock" ]]; then
		pm="yarn"
	elif [[ -f "package-lock.json" ]]; then
		pm="npm"
	else
		log_warn "No lockfile found, defaulting to npm"
	fi

	# Install dependencies
	log_info "Installing dependencies with $pm..."
	case "$pm" in
	bun) bun install --frozen-lockfile ;;
	pnpm) pnpm install --frozen-lockfile ;;
	npm)
		# npm ci requires package-lock.json or npm-shrinkwrap.json
		if [[ -f "package-lock.json" ]] || [[ -f "npm-shrinkwrap.json" ]]; then
			npm ci
		else
			log_warn "No lockfile found, using npm install instead of npm ci"
			npm install
		fi
		;;
	yarn) yarn install --immutable 2>/dev/null || yarn install --frozen-lockfile ;;
	esac

	# Run build script if it exists in scripts object
	has_build_script=false
	if command -v jq >/dev/null 2>&1; then
		jq -e '.scripts.build // empty' package.json >/dev/null 2>&1 && has_build_script=true
	else
		# Fallback: grep-based check (may match non-script "build" keys)
		grep -q '"scripts"' package.json && grep -qE '^[[:space:]]*"build"[[:space:]]*:' package.json && has_build_script=true
	fi
	if [[ "$has_build_script" == "true" ]]; then
		log_info "Running build script with $pm..."
		case "$pm" in
		bun) bun run build ;;
		pnpm) pnpm run build ;;
		yarn) yarn run build ;;
		npm) npm run build ;;
		esac
	fi

	# Pack the package (don't suppress stderr to preserve error messages)
	log_info "Packing package with $pm..."
	case "$pm" in
	bun) tarball=$(bun pm pack 2>&1 | tail -1) ;;
	pnpm) tarball=$(pnpm pack 2>&1 | tail -1) ;;
	yarn)
		# yarn pack outputs the filename; capture output first to avoid pipefail exit
		yarn_out=$(yarn pack 2>&1) || true
		tarball=$(printf '%s\n' "$yarn_out" | grep -oE '[^ ]+\.tgz' | tail -1) || true
		if [[ -z "$tarball" ]] || [[ ! -f "$tarball" ]]; then
			# Fallback to npm pack if yarn pack fails
			tarball=$(npm pack 2>&1 | tail -1)
		fi
		;;
	npm) tarball=$(npm pack 2>&1 | tail -1) ;;
	esac

	if [[ -z "$tarball" ]] || [[ ! -f "$tarball" ]]; then
		die "Failed to pack package"
	fi

	log_success "Packed: $tarball"

	set_github_output "name" "$name"
	set_github_output "version" "$version"
	set_github_output "tarball" "$tarball"
	;;

publish)
	: "${DIST_TAG:=latest}"
	: "${PROVENANCE:=true}"
	: "${ACCESS:=public}"

	# Empty NODE_AUTH_TOKEN (e.g. from setup-node registry-url placeholder)
	# must be cleared so npm initiates OIDC trusted publishing instead of
	# treating an empty classic token as configured auth.
	if [[ -z "${NODE_AUTH_TOKEN:-}" ]]; then
		unset NODE_AUTH_TOKEN
	fi

	local_auth_mode="oidc"
	if [[ -n "${NODE_AUTH_TOKEN:-}" ]]; then
		local_auth_mode="token"
		log_info "Publishing to npm with legacy NODE_AUTH_TOKEN auth..."
	else
		# setup-node with registry-url writes //registry…/:_authToken=${NODE_AUTH_TOKEN}
		# into the user npmrc. Leaving that entry with an empty token makes npm
		# treat token auth as configured and skip OIDC trusted publishing.
		_strip_npmrc_auth_tokens
		log_info "Publishing to npm with OIDC trusted publishing..."
		log_info "Require Node 24+ (npm ≥ 11.5.1). Do not run: npm install -g npm"
	fi

	npm_version=$(npm --version)

	if [[ "$local_auth_mode" == "oidc" ]]; then
		# Trusted publishing requires npm 11.5.1+ (Node 24 recommended).
		if ! _npm_version_ge "$npm_version" "11.5.1"; then
			die "OIDC trusted publishing requires npm 11.5.1+ (found: $npm_version). Use Node 24 via setup-node; do not run npm install -g npm."
		fi
	fi

	# Build publish command
	publish_args=(
		"--tag" "$DIST_TAG"
		"--access" "$ACCESS"
	)

	if [[ "$PROVENANCE" == "true" ]]; then
		# Token path: provenance needs npm 9.5.0+.
		# OIDC path: already gated at 11.5.1+ above; provenance is automatic
		# under trusted publishing, but --provenance remains explicit intent.
		if [[ "$local_auth_mode" == "token" ]]; then
			if ! _npm_version_ge "$npm_version" "9.5.0"; then
				die "npm 9.5.0+ required for provenance support (found: $npm_version)"
			fi
		fi
		publish_args+=("--provenance")
	fi

	# Publish using npm (provenance requires npm, not bun)
	log_info "Running: npm publish ${publish_args[*]}"
	npm publish "${publish_args[@]}"

	log_success "Published successfully"
	set_github_output "published" "true"
	;;

summary)
	: "${PACKAGE_NAME:=unknown}"
	: "${PACKAGE_VERSION:=unknown}"
	: "${DIST_TAG:=latest}"
	: "${DRY_RUN:=false}"
	: "${PUBLISHED:=false}"

	add_github_summary "## npm Publishing"
	add_github_summary ""
	add_github_summary "| Property | Value |"
	add_github_summary "| -------- | ----- |"
	add_github_summary "| Package | $PACKAGE_NAME |"
	add_github_summary "| Version | $PACKAGE_VERSION |"
	add_github_summary "| Tag | $DIST_TAG |"

	if [[ "$DRY_RUN" == "true" ]]; then
		add_github_summary "| Status | :construction: Dry Run (not published) |"
	elif [[ "$PUBLISHED" == "true" ]]; then
		add_github_summary "| Status | :white_check_mark: Published |"
		add_github_summary "| URL | https://www.npmjs.com/package/$PACKAGE_NAME/v/$PACKAGE_VERSION |"
	else
		add_github_summary "| Status | :x: Not Published |"
	fi
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
