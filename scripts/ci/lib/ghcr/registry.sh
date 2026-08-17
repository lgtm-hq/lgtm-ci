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
#   ghcr_collect_referenced_digests owner package versions_var token \
#     complete_var digests_file
#
# versions_var is the *name* of a caller variable holding the GitHub versions
# JSON. digests_file is a path the collector writes (newline-delimited
# digests). Passing either payload by value would re-enter Bash xtrace (#856).

[[ -n "${_LGTM_CI_GHCR_REGISTRY_LOADED:-}" ]] && return 0
readonly _LGTM_CI_GHCR_REGISTRY_LOADED=1

_GHCR_MANIFEST_ACCEPT=$(
	cat <<'EOF'
application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json
EOF
)
readonly _GHCR_MANIFEST_ACCEPT

readonly _GHCR_REFERRERS_ACCEPT="application/vnd.oci.image.index.v1+json"

# Write a nameref's value to a file with xtrace off so kcov's PS4 tracer
# cannot dump a multi-megabyte payload as unprefixed continuation lines
# (#856). The call site must pass the *name*, not the payload.
_ghcr_xtrace_off() {
	case "$-" in
	*x*) _GHCR_XTRACE_RESTORE=1 ;;
	*) _GHCR_XTRACE_RESTORE=0 ;;
	esac
	set +x
}

_ghcr_xtrace_restore() {
	if [[ "${_GHCR_XTRACE_RESTORE:-0}" -eq 1 ]]; then
		set -x
	fi
}

_ghcr_write_var_to_file() {
	local -n _ghcr_src="${1:?variable name required}"
	local _ghcr_dest="${2:?destination path required}"
	local _status=0
	_ghcr_xtrace_off
	printf '%s' "$_ghcr_src" >"$_ghcr_dest" || _status=$?
	_ghcr_xtrace_restore
	return "$_status"
}

# Write unique lines from a nameref array to a file with xtrace off (#856).
_ghcr_write_unique_lines() {
	local -n _ghcr_arr="${1:?array name required}"
	local _ghcr_dest="${2:?destination path required}"
	local _status=0
	_ghcr_xtrace_off
	if ((${#_ghcr_arr[@]} > 0)); then
		printf '%s\n' "${_ghcr_arr[@]}" | sort -u >"$_ghcr_dest" || _status=$?
	else
		: >"$_ghcr_dest" || _status=$?
	fi
	_ghcr_xtrace_restore
	return "$_status"
}

# Run curl with xtrace off and write the raw response (body + trailing
# http_code line from -w) to dest. Returns curl's exit status. The body
# never enters a scalar, so kcov cannot dump it (#856).
_ghcr_curl_raw_to_file() {
	local url="${1:?url required}"
	local dest="${2:?dest required}"
	local accept="${3:?accept required}"
	local token="${4:?token required}"
	local status=0
	_ghcr_xtrace_off
	curl -sS --max-time 30 -w '\n%{http_code}' "$url" \
		-H "Authorization: Bearer ${token}" \
		-H "Accept: ${accept}" \
		2>/dev/null >"$dest" || status=$?
	_ghcr_xtrace_restore
	return "$status"
}

# Split a raw curl file (body + last-line http_code) into dest body file
# and an http_code nameref. Never loads the body into a scalar.
_ghcr_split_raw_response() {
	local raw="${1:?raw file required}"
	local body_dest="${2:?body dest required}"
	local -n _http_code_out="${3:?http code var required}"
	local status=0
	_ghcr_xtrace_off
	_http_code_out="$(tail -n 1 "$raw")" || status=$?
	if [[ "$status" -eq 0 ]]; then
		sed '$d' "$raw" >"$body_dest" || status=$?
	fi
	_ghcr_xtrace_restore
	return "$status"
}

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
# Optional $5: destination path. On success the JSON is written there and
# nothing is printed; on 404 the file is truncated. Use this for large
# indexes so the body never re-enters an xtraced command (#856).
ghcr_fetch_manifest() {
	local owner="${1:?owner required}"
	local package_name="${2:?package required}"
	local digest="${3:?digest required}"
	local registry_token="${4:?registry token required}"
	local dest="${5:-}"
	local url http_code
	local raw_file body_file

	url="https://ghcr.io/v2/${owner}/${package_name}/manifests/${digest}"
	raw_file="$(mktemp "${TMPDIR:-/tmp}/ghcr-manifest-raw.XXXXXX")" || {
		printf 'ERROR\n'
		return 1
	}
	body_file="$(mktemp "${TMPDIR:-/tmp}/ghcr-manifest.XXXXXX")" || {
		rm -f "$raw_file"
		printf 'ERROR\n'
		return 1
	}

	if ! _ghcr_curl_raw_to_file \
		"$url" \
		"$raw_file" \
		"${_GHCR_MANIFEST_ACCEPT}" \
		"$registry_token"; then
		rm -f "$raw_file" "$body_file"
		printf 'ERROR\n'
		return 1
	fi

	if ! _ghcr_split_raw_response "$raw_file" "$body_file" http_code; then
		rm -f "$raw_file" "$body_file"
		printf 'ERROR\n'
		return 1
	fi
	rm -f "$raw_file"

	case "$http_code" in
	404)
		rm -f "$body_file"
		if [[ -n "$dest" ]]; then
			if ! : >"$dest"; then
				printf 'ERROR\n'
				return 1
			fi
			return 0
		fi
		printf '404\n'
		return 0
		;;
	2?? | 3??)
		if ! jq -e 'type == "object"' "$body_file" >/dev/null 2>&1; then
			rm -f "$body_file"
			printf 'ERROR\n'
			return 1
		fi
		# Optional dest ($5): leave the JSON on disk and print nothing
		# so a large index never re-enters the caller's xtrace stream.
		if [[ -n "$dest" ]]; then
			if ! mv "$body_file" "$dest"; then
				rm -f "$body_file"
				printf 'ERROR\n'
				return 1
			fi
			return 0
		fi
		cat "$body_file"
		rm -f "$body_file"
		return 0
		;;
	*)
		rm -f "$body_file"
		printf 'ERROR\n'
		return 1
		;;
	esac
}

# Fetch OCI Referrers descriptors for a digest.
# Prints JSON array on stdout; empty array on genuine 404; returns 1 on transient errors.
# Optional $5: destination path. On success the compact descriptor array is
# written there and nothing is printed (#856).
ghcr_fetch_referrers() {
	local owner="${1:?owner required}"
	local package_name="${2:?package required}"
	local digest="${3:?digest required}"
	local registry_token="${4:?registry token required}"
	local dest="${5:-}"
	local url http_code
	local raw_file body_file out_file

	url="https://ghcr.io/v2/${owner}/${package_name}/referrers/${digest}"
	raw_file="$(mktemp "${TMPDIR:-/tmp}/ghcr-referrers-raw.XXXXXX")" || {
		printf 'ERROR\n'
		return 1
	}
	body_file="$(mktemp "${TMPDIR:-/tmp}/ghcr-referrers.XXXXXX")" || {
		rm -f "$raw_file"
		printf 'ERROR\n'
		return 1
	}

	if ! _ghcr_curl_raw_to_file \
		"$url" \
		"$raw_file" \
		"${_GHCR_REFERRERS_ACCEPT}" \
		"$registry_token"; then
		rm -f "$raw_file" "$body_file"
		printf 'ERROR\n'
		return 1
	fi

	if ! _ghcr_split_raw_response "$raw_file" "$body_file" http_code; then
		rm -f "$raw_file" "$body_file"
		printf 'ERROR\n'
		return 1
	fi
	rm -f "$raw_file"

	case "$http_code" in
	404)
		rm -f "$body_file"
		if [[ -n "$dest" ]]; then
			if ! printf '[]' >"$dest"; then
				printf 'ERROR\n'
				return 1
			fi
			return 0
		fi
		printf '[]'
		return 0
		;;
	2?? | 3??)
		if ! jq -e 'type == "object"' "$body_file" >/dev/null 2>&1; then
			rm -f "$body_file"
			printf 'ERROR\n'
			return 1
		fi
		out_file="$(mktemp "${TMPDIR:-/tmp}/ghcr-referrers-out.XXXXXX")" || {
			rm -f "$body_file"
			printf 'ERROR\n'
			return 1
		}
		if ! jq -c '.manifests // [] | map(select(type == "object"))' \
			"$body_file" >"$out_file"; then
			rm -f "$body_file" "$out_file"
			printf 'ERROR\n'
			return 1
		fi
		rm -f "$body_file"
		if [[ -n "$dest" ]]; then
			if ! mv "$out_file" "$dest"; then
				rm -f "$out_file"
				printf 'ERROR\n'
				return 1
			fi
			return 0
		fi
		cat "$out_file"
		rm -f "$out_file"
		return 0
		;;
	*)
		rm -f "$body_file"
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
#   $3 - name of caller variable holding versions JSON (GitHub API shape)
#   $4 - registry bearer token
#   $5 - name of caller variable to set complete status (true/false)
#   $6 - destination path for newline-delimited unique digests
# Returns 1 when a temporary-file write fails (fail closed). Manifest or
# referrer fetch errors set complete=false and still return 0 so callers
# can skip prune instead of deleting unprotected artifacts.
ghcr_collect_referenced_digests() {
	local owner="${1:?owner required}"
	local package_name="${2:?package required}"
	local versions_var="${3:?versions var name required}"
	local -n _versions_json="${versions_var}"
	local registry_token="${4:?registry token required}"
	local complete_var="${5:?complete var required}"
	local digests_file="${6:?digests file required}"
	local -a digests=()
	local complete=true
	local digest
	local manifest_file versions_file unique_file referrers_file

	_ghcr_collect_fail() {
		printf -v "$complete_var" 'false'
		: >"$digests_file" || true
		rm -f -- "$manifest_file" "$versions_file" "$unique_file" "$referrers_file"
		return 1
	}

	manifest_file="$(mktemp "${TMPDIR:-/tmp}/ghcr-collect-manifest.XXXXXX")" || return 1
	versions_file="$(mktemp "${TMPDIR:-/tmp}/ghcr-collect-versions.XXXXXX")" || return 1
	unique_file="$(mktemp "${TMPDIR:-/tmp}/ghcr-collect-digests.XXXXXX")" || return 1
	referrers_file="$(mktemp "${TMPDIR:-/tmp}/ghcr-collect-referrers.XXXXXX")" || return 1

	if ! _ghcr_write_var_to_file _versions_json "$versions_file"; then
		_ghcr_collect_fail
		return 1
	fi

	while IFS= read -r digest; do
		[[ -z "$digest" ]] && continue

		# P1: protect the root tagged digest itself
		digests+=("$digest")

		# Fetch to a file so a 24k-entry index never lands in a
		# here-string that kcov dumps to the job log (#856).
		: >"$manifest_file"
		if ! ghcr_fetch_manifest \
			"$owner" \
			"$package_name" \
			"$digest" \
			"$registry_token" \
			"$manifest_file" \
			>/dev/null; then
			complete=false
			continue
		fi

		# dest-mode 404 leaves an empty file: no children/subject, but
		# referrers can still exist and must still be collected.
		if [[ -s "$manifest_file" ]]; then
			while IFS= read -r child; do
				[[ -n "$child" ]] && digests+=("$child")
			done < <(
				jq -r '.manifests[]? | select(type == "object") | .digest // empty' \
					"$manifest_file"
			)
			while IFS= read -r subject; do
				[[ -n "$subject" ]] && digests+=("$subject")
			done < <(
				jq -r '.subject | select(type == "object") | .digest // empty' \
					"$manifest_file"
			)
		fi

		: >"$referrers_file"
		if ! ghcr_fetch_referrers \
			"$owner" \
			"$package_name" \
			"$digest" \
			"$registry_token" \
			"$referrers_file" \
			>/dev/null; then
			complete=false
			continue
		fi

		while IFS= read -r ref_digest; do
			[[ -n "$ref_digest" ]] && digests+=("$ref_digest")
		done < <(jq -r '.[]? | .digest // empty' "$referrers_file")
	done < <(
		jq -r '
			.[] |
			select((.metadata.container.tags | length) > 0) |
			select(.name | startswith("sha256:")) |
			.name
		' "$versions_file"
	)

	if ! _ghcr_write_unique_lines digests "$unique_file"; then
		_ghcr_collect_fail
		return 1
	fi
	if ! mv "$unique_file" "$digests_file"; then
		_ghcr_collect_fail
		return 1
	fi
	unique_file=""
	printf -v "$complete_var" '%s' "$complete"
	rm -f -- "$manifest_file" "$versions_file" "$referrers_file"
	return 0
}

export -f ghcr_exchange_registry_token ghcr_fetch_manifest ghcr_fetch_referrers
export -f ghcr_collect_referenced_digests
export -f _ghcr_xtrace_off _ghcr_xtrace_restore
export -f _ghcr_write_var_to_file _ghcr_write_unique_lines
export -f _ghcr_curl_raw_to_file _ghcr_split_raw_response
