#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: GHCR registry helpers for referenced-digest protection during prune
#
# These functions use raw curl against the Docker registry v2 API (ghcr.io)
# because `gh api` only speaks the GitHub REST API. Token exchange, manifest
# fetches, and OCI Referrers lookups require registry-native endpoints that
# the GitHub CLI cannot reach.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/registry.sh"
#   ghcr_exchange_registry_token owner package github_token
#   ghcr_collect_referenced_digests owner package versions_json registry_token

[[ -n "${_LGTM_CI_GHCR_REGISTRY_LOADED:-}" ]] && return 0
readonly _LGTM_CI_GHCR_REGISTRY_LOADED=1

_GHCR_MANIFEST_ACCEPT=$(
	cat <<'EOF'
application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json
EOF
)
readonly _GHCR_MANIFEST_ACCEPT

readonly _GHCR_REFERRERS_ACCEPT="application/vnd.oci.image.index.v1+json"

# Exchange GITHUB_TOKEN for a ghcr.io registry pull bearer token.
# Args:
#   $1 - package owner (org/user)
#   $2 - package name
#   $3 - GitHub token with read:packages
# Prints bearer token on stdout; returns 1 when exchange fails.
ghcr_exchange_registry_token() {
	local owner="${1:?owner required}"
	local package_name="${2:?package required}"
	local github_token="${3:?github token required}"
	local auth url token

	auth=$(printf 'x:%s' "$github_token" | base64 | tr -d '\n')
	url="https://ghcr.io/token?service=ghcr.io&scope=repository:${owner}/${package_name}:pull"

	if ! token=$(
		curl -fsS --max-time 30 "$url" \
			-H "Authorization: Basic ${auth}" 2>/dev/null |
			jq -r '.token // .access_token // empty'
	); then
		return 1
	fi

	if [[ -z "$token" ]]; then
		return 1
	fi

	printf '%s' "$token"
}

# Fetch a manifest from ghcr.io by digest.
# Returns manifest JSON on stdout; prints "404" when genuinely absent;
# prints "ERROR" and returns 1 on transient failures.
ghcr_fetch_manifest() {
	local owner="${1:?owner required}"
	local package_name="${2:?package required}"
	local digest="${3:?digest required}"
	local registry_token="${4:?registry token required}"
	local url http_code body

	url="https://ghcr.io/v2/${owner}/${package_name}/manifests/${digest}"
	body=$(
		curl -sS --max-time 30 -w '\n%{http_code}' "$url" \
			-H "Authorization: Bearer ${registry_token}" \
			-H "Accept: ${_GHCR_MANIFEST_ACCEPT}" 2>/dev/null
	) || {
		printf 'ERROR\n'
		return 1
	}

	http_code="${body##*$'\n'}"
	body="${body%$'\n'*}"

	case "$http_code" in
	404)
		printf '404\n'
		return 0
		;;
	2?? | 3??)
		if ! jq -e 'type == "object"' <<<"$body" >/dev/null 2>&1; then
			printf 'ERROR\n'
			return 1
		fi
		printf '%s' "$body"
		return 0
		;;
	*)
		printf 'ERROR\n'
		return 1
		;;
	esac
}

# Fetch OCI Referrers descriptors for a digest.
# Prints JSON array on stdout; empty array on genuine 404; returns 1 on transient errors.
ghcr_fetch_referrers() {
	local owner="${1:?owner required}"
	local package_name="${2:?package required}"
	local digest="${3:?digest required}"
	local registry_token="${4:?registry token required}"
	local url http_code body

	url="https://ghcr.io/v2/${owner}/${package_name}/referrers/${digest}"
	body=$(
		curl -sS --max-time 30 -w '\n%{http_code}' "$url" \
			-H "Authorization: Bearer ${registry_token}" \
			-H "Accept: ${_GHCR_REFERRERS_ACCEPT}" 2>/dev/null
	) || {
		printf 'ERROR\n'
		return 1
	}

	http_code="${body##*$'\n'}"
	body="${body%$'\n'*}"

	case "$http_code" in
	404)
		printf '[]'
		return 0
		;;
	2?? | 3??)
		if ! jq -e 'type == "object"' <<<"$body" >/dev/null 2>&1; then
			printf 'ERROR\n'
			return 1
		fi
		jq -c '.manifests // [] | map(select(type == "object"))' <<<"$body"
		return 0
		;;
	*)
		printf 'ERROR\n'
		return 1
		;;
	esac
}

# Collect digests referenced by tagged manifest indexes and referrers.
# Includes the root tagged digest itself, its manifest children, subject
# digests, and OCI Referrers descriptors.
# Args:
#   $1 - owner
#   $2 - package name
#   $3 - versions JSON array (GitHub API shape)
#   $4 - registry bearer token
#   $5 - name of caller variable to set complete status (true/false)
#   $6 - name of caller variable to set newline-delimited digests
ghcr_collect_referenced_digests() {
	local owner="${1:?owner required}"
	local package_name="${2:?package required}"
	local versions_json="${3:?versions json required}"
	local registry_token="${4:?registry token required}"
	local complete_var="${5:?complete var required}"
	local digests_var="${6:?digests var required}"
	local -a digests=()
	local complete=true
	local digest manifest referrers_json

	while IFS= read -r digest; do
		[[ -z "$digest" ]] && continue

		# P1: protect the root tagged digest itself
		digests+=("$digest")

		manifest=$(ghcr_fetch_manifest \
			"$owner" \
			"$package_name" \
			"$digest" \
			"$registry_token") || {
			complete=false
			continue
		}

		if [[ "$manifest" == "ERROR" ]]; then
			complete=false
			continue
		fi

		if [[ "$manifest" != "404" ]]; then
			while IFS= read -r child; do
				[[ -n "$child" ]] && digests+=("$child")
			done < <(
				jq -r '.manifests[]? | select(type == "object") | .digest // empty' \
					<<<"$manifest"
			)
			while IFS= read -r subject; do
				[[ -n "$subject" ]] && digests+=("$subject")
			done < <(
				jq -r '.subject | select(type == "object") | .digest // empty' \
					<<<"$manifest"
			)
		fi

		referrers_json=$(ghcr_fetch_referrers \
			"$owner" \
			"$package_name" \
			"$digest" \
			"$registry_token") || {
			complete=false
			continue
		}

		if [[ "$referrers_json" == "ERROR" ]]; then
			complete=false
			continue
		fi

		while IFS= read -r ref_digest; do
			[[ -n "$ref_digest" ]] && digests+=("$ref_digest")
		done < <(jq -r '.[]? | .digest // empty' <<<"$referrers_json")
	done < <(
		jq -r '
			.[] |
			select((.metadata.container.tags | length) > 0) |
			select(.name | startswith("sha256:")) |
			.name
		' <<<"$versions_json"
	)

	printf -v "$complete_var" '%s' "$complete"
	if ((${#digests[@]} > 0)); then
		printf -v "$digests_var" '%s' "$(printf '%s\n' "${digests[@]}" | sort -u)"
	else
		printf -v "$digests_var" ''
	fi
}

export -f ghcr_exchange_registry_token ghcr_fetch_manifest ghcr_fetch_referrers
export -f ghcr_collect_referenced_digests
