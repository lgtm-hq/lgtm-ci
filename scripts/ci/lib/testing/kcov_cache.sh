#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Stage, verify and restore the kcov build that reusable-test-shell.yml
#          caches with actions/cache (#886), so a warm cache installs kcov
#          without apt-get, git clone or a build.
#
# Usage (from scripts/ci/actions/run-bats-tests.sh):
#   source "scripts/ci/lib/testing/kcov_cache.sh"
#   key="$(kcov_cache_key v43 <commit> <patch-file-or-empty>)"
#   kcov_cache_restore <stage-dir> "$key" v43 /usr/local   # 0: installed
#   kcov_cache_populate <stage-dir> "$key" v43 <build-dir> /usr/local
#
# Stage layout (the directory actions/cache saves and restores):
#   <stage-dir>/cache-key   the exact key the tree was built for
#   <stage-dir>/tree/       the `make install` tree for <prefix> (bin/kcov, ...)
#
# The key is exact: kcov version, the verified tag commit, the digest of the
# patch applied to the source (or "nopatch"), the runner image (ImageOS), the
# OS release (/etc/os-release ID and VERSION_ID) and the architecture. It is
# empty when a part is unknown (an unverified version override, an unreadable
# os-release): the workflow then skips the cache and the stage is never used
# or written.
#
# Cache state never fails the step. A stage that is missing, built for another
# key, has a missing or non-executable binary, a shared library ldd cannot
# resolve, or a binary whose `--version` does not print "kcov <version>"
# makes kcov_cache_restore return 1 (with a ::warning:: for a stage that is
# present but unusable), and the caller builds from source as before.
#
# Environment (tests and adopters):
#   OS_RELEASE_FILE   os-release file to read (default /etc/os-release)
#   ImageOS           GitHub's runner image id (ubuntu24, ...; "noimage" when unset)
#   RUNNER_ARCH       X64 / ARM64 (default: uname -m)
#   KCOV_CACHE_SUDO   command prefix for writes under <prefix> (default sudo)

KCOV_CACHE_STAMP="cache-key"
KCOV_CACHE_TREE="tree"
# Seconds a staged `kcov --version` may take; a binary that hangs is unusable.
KCOV_CACHE_VERIFY_TIMEOUT_SECONDS=10

# Print the version without its leading "v" (v43 -> 43).
_kcov_cache_bare_version() {
	printf '%s' "${1#v}"
}

# Print the sha256 of a file, or nothing when it cannot be read.
_kcov_cache_sha256() {
	local file="$1" sum=""
	[[ -r "$file" ]] || return 0
	if command -v sha256sum >/dev/null 2>&1; then
		sum="$(sha256sum "$file" 2>/dev/null)" || sum=""
	elif command -v shasum >/dev/null 2>&1; then
		sum="$(shasum -a 256 "$file" 2>/dev/null)" || sum=""
	fi
	sum="${sum%% *}"
	[[ "$sum" =~ ^[0-9a-f]{64}$ ]] && printf '%s' "$sum"
	return 0
}

# Print "<image>-<distro><release>" (noimage-ubuntu24.04), or nothing when
# the os-release file does not name both ID and VERSION_ID.
kcov_cache_os_part() {
	local file="${OS_RELEASE_FILE:-/etc/os-release}" line key value id="" release=""
	[[ -r "$file" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		key="${line%%=*}"
		[[ "$line" == *=* ]] || continue
		value="${line#*=}"
		value="${value#[\"\']}"
		value="${value%[\"\']}"
		case "$key" in
		ID) id="$value" ;;
		VERSION_ID) release="$value" ;;
		esac
	done <"$file"
	[[ -n "$id" && -n "$release" ]] || return 0
	printf '%s-%s%s' "${ImageOS:-noimage}" "$id" "$release"
}

# Print x64 or arm64, or nothing for another architecture.
kcov_cache_arch_part() {
	local raw="${RUNNER_ARCH:-}"
	[[ -n "$raw" ]] || raw="$(uname -m 2>/dev/null || true)"
	case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
	x64 | x86_64 | amd64) printf 'x64' ;;
	arm64 | aarch64) printf 'arm64' ;;
	*) ;;
	esac
}

# Print the exact cache key, or nothing (with the reason on stderr) when a
# part is unknown. <patch-file> is the patch the build applies; empty when
# it applies none.
# Usage: kcov_cache_key <version> <commit> [<patch-file>]
kcov_cache_key() {
	local version="$1" commit="$2" patch="${3:-}" patch_part="nopatch" os_part arch_part
	commit="$(printf '%s' "$commit" | tr '[:upper:]' '[:lower:]')"
	if [[ -n "$patch" ]]; then
		patch_part="$(_kcov_cache_sha256 "$patch")"
	fi
	os_part="$(kcov_cache_os_part)"
	arch_part="$(kcov_cache_arch_part)"
	if [[ ! "$version" =~ ^[A-Za-z0-9._-]+$ || ! "$commit" =~ ^[0-9a-f]{40}$ ||
		-z "$patch_part" || -z "$os_part" || -z "$arch_part" ]]; then
		echo "kcov cache: no exact key (version=${version:-?} commit=${commit:-?}" \
			"patch=${patch_part:-?} os=${os_part:-?} arch=${arch_part:-?}); the cache is skipped" >&2
		return 0
	fi
	printf 'lgtm-kcov-%s-%s-%s-%s-%s' "$version" "$commit" "$patch_part" "$os_part" "$arch_part" |
		tr -c 'A-Za-z0-9._-' '-'
}

# Print the shared libraries ldd cannot resolve for <binary>, one per line.
# Prints nothing when every library resolves, when the file is not a dynamic
# executable, or when ldd is not installed (executing the binary then shows a
# missing library as an exec failure).
kcov_cache_missing_libraries() {
	local binary="$1" out
	command -v ldd >/dev/null 2>&1 || return 0
	out="$(ldd "$binary" 2>&1)" || true
	printf '%s\n' "$out" | awk '/=> not found/ { print $1 }'
}

# Succeed when executing <binary> --version prints exactly "kcov <version>"
# (leading "v" ignored on both sides). Sets KCOV_CACHE_REPORTED to what it
# printed (or the exec failure) for the caller's message.
# Usage: kcov_cache_version_matches <binary> <version>
kcov_cache_version_matches() {
	local binary="$1" version="$2" out rc=0
	out="$(timeout --kill-after=2s "${KCOV_CACHE_VERIFY_TIMEOUT_SECONDS}s" \
		"$binary" --version 2>&1)" || rc=$?
	out="$(printf '%s' "$out" | head -n 1)"
	if [[ "$rc" -ne 0 ]]; then
		KCOV_CACHE_REPORTED="exit ${rc}${out:+: ${out}}"
		return 1
	fi
	KCOV_CACHE_REPORTED="$out"
	[[ "$out" =~ ^kcov\ v?(.+)$ ]] || return 1
	[[ "${BASH_REMATCH[1]}" == "$(_kcov_cache_bare_version "$version")" ]]
}

# Print why the kcov binary at <binary> cannot be used for <version>, or
# nothing when it is usable: present, executable, every shared library
# resolved, and `--version` reporting <version>.
kcov_cache_binary_problem() {
	local binary="$1" version="$2" missing
	if [[ ! -f "$binary" ]]; then
		printf 'no kcov binary at %s' "$binary"
		return 0
	fi
	if [[ ! -x "$binary" ]]; then
		printf '%s is not executable' "$binary"
		return 0
	fi
	missing="$(kcov_cache_missing_libraries "$binary" | paste -sd ' ' -)"
	if [[ -n "$missing" ]]; then
		printf '%s needs shared libraries ldd cannot resolve: %s' "$binary" "$missing"
		return 0
	fi
	if ! kcov_cache_version_matches "$binary" "$version"; then
		printf '%s --version reported "%s", expected kcov %s' "$binary" "$KCOV_CACHE_REPORTED" "$version"
	fi
	return 0
}

# Install kcov from <stage> into <prefix> when the stage was built for <key>
# and its binary passes kcov_cache_binary_problem, before and after the copy.
# Returns 0 when kcov is installed from the stage, 1 when the caller must build.
# Usage: kcov_cache_restore <stage> <key> <version> <prefix>
kcov_cache_restore() {
	local stage="$1" key="$2" version="$3" prefix="$4" stamp="" problem sudo
	sudo="${KCOV_CACHE_SUDO-sudo}"
	if [[ -z "$key" ]]; then
		echo "kcov cache: no exact key; building kcov ${version} from source"
		return 1
	fi
	if [[ ! -d "$stage" ]]; then
		echo "kcov cache: no staged build at ${stage}; building kcov ${version} from source"
		return 1
	fi
	if [[ -r "$stage/$KCOV_CACHE_STAMP" ]]; then
		stamp="$(head -n 1 "$stage/$KCOV_CACHE_STAMP")"
	fi
	if [[ "$stamp" != "$key" ]]; then
		echo "::warning title=kcov cache unusable::staged kcov at ${stage} was built for '${stamp:-no key}', not '${key}'; building from source"
		return 1
	fi
	problem="$(kcov_cache_binary_problem "$stage/$KCOV_CACHE_TREE/bin/kcov" "$version")"
	if [[ -n "$problem" ]]; then
		echo "::warning title=kcov cache unusable::${problem}; building from source"
		return 1
	fi
	if ! $sudo mkdir -p "$prefix" || ! $sudo cp -R "$stage/$KCOV_CACHE_TREE/." "$prefix/"; then
		echo "::warning title=kcov cache unusable::copying ${stage}/${KCOV_CACHE_TREE} into ${prefix} failed; building from source"
		return 1
	fi
	problem="$(kcov_cache_binary_problem "$prefix/bin/kcov" "$version")"
	if [[ -n "$problem" ]]; then
		echo "::warning title=kcov cache unusable::installed from the stage, but ${problem}; building from source"
		return 1
	fi
	echo "::notice title=kcov cache::kcov ${version} restored from cache (${key}); apt, clone and build skipped"
	return 0
}

# Stage the finished build in <build-dir> for the cache: `make install` into a
# DESTDIR, check the staged binary, then swap it in as <stage>/tree with the
# key stamp. Never fails: a stage that cannot be written is a warning and the
# cache saves nothing usable (the next run builds again).
# Usage: kcov_cache_populate <stage> <key> <version> <build-dir> <prefix>
kcov_cache_populate() {
	local stage="$1" key="$2" version="$3" build="$4" prefix="$5" tmp problem
	if [[ -z "$key" ]]; then
		echo "kcov cache: no exact key; the build is not staged"
		return 0
	fi
	tmp="${stage}.partial"
	rm -rf "$tmp" "$stage" || true
	if ! mkdir -p "$tmp/destdir" ||
		! make -C "$build" install DESTDIR="$tmp/destdir" >/dev/null; then
		echo "::warning title=kcov cache not populated::make install into ${tmp} failed; the next run builds again"
		rm -rf "$tmp" || true
		return 0
	fi
	problem="$(kcov_cache_binary_problem "$tmp/destdir${prefix}/bin/kcov" "$version")"
	if [[ -n "$problem" ]]; then
		echo "::warning title=kcov cache not populated::${problem}; the next run builds again"
		rm -rf "$tmp" || true
		return 0
	fi
	if ! mkdir -p "$stage" ||
		! mv "$tmp/destdir${prefix}" "$stage/$KCOV_CACHE_TREE" ||
		! printf '%s\n' "$key" >"$stage/$KCOV_CACHE_STAMP"; then
		echo "::warning title=kcov cache not populated::writing ${stage} failed; the next run builds again"
		rm -rf "$tmp" "$stage" || true
		return 0
	fi
	rm -rf "$tmp" || true
	echo "kcov cache: staged kcov ${version} at ${stage} (${key})"
	return 0
}
