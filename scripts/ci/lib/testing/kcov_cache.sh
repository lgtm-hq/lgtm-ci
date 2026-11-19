#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Stage, check and install the kcov build that reusable-test-shell.yml
#          caches with actions/cache/restore and actions/cache/save (#886), so
#          a warm cache installs kcov without apt-get, git clone or a build.
#
# Usage (from scripts/ci/actions/run-bats-tests.sh):
#   source "scripts/ci/lib/testing/kcov_cache.sh"
#   key="$(kcov_cache_key v43 <commit> <patch-file-or-empty> <recipe-sha256>)"
#   kcov_cache_restore <stage-dir> "$key" v43 /usr/local          # 0: installed
#   kcov_cache_populate <stage-dir> "$key" v43 <destdir-tree>      # 0: staged
#   kcov_cache_install <tree> /usr/local                           # allowlisted copy
#
# Stage layout (the directory the workflow restores and saves):
#   <stage-dir>/cache-key   the exact key the tree was built for
#   <stage-dir>/tree/       the `make install DESTDIR=` tree for the prefix
#
# Trust model. The key and the checks below catch a stale or broken stage
# (another kcov version, commit, patch, build recipe, OS release or
# architecture; a binary that does not run or misses a shared library). They
# do not authenticate the bytes: whoever can write the cache entry can write
# the stamp and a binary that passes the checks. The workflow therefore
# saves the cache only from a push to the repository's default branch, and
# GitHub scopes caches so pull requests read the default branch's entries but
# never write them. The install copies only the allowlisted kcov files below,
# each with a fixed mode, and rejects a tree holding anything else.
#
# The key is exact: kcov version, the tag commit the source build checks, the
# digest of the patch applied to the source (or "nopatch"), the digest of the
# build recipe (this file plus the install-kcov block of run-bats-tests.sh),
# the runner image (ImageOS), the OS release (/etc/os-release ID and
# VERSION_ID) and the architecture. It is empty when a part is unknown (an
# unchecked version override, an unreadable os-release): the workflow then
# skips the cache and the stage is never used or written.
#
# Cache state never fails the step. A stage that is missing, built for
# another key, holds a file outside the allowlist, a symlink or a special
# file, misses a required file, or whose kcov does not pass the ldd and
# --version probes makes kcov_cache_restore return 1 (with a ::warning:: for
# a stage that is present but unusable), and the caller builds from source.
#
# Environment (tests and adopters):
#   OS_RELEASE_FILE   os-release file to read (default /etc/os-release)
#   ImageOS           GitHub's runner image id (ubuntu24, ...; "noimage" when unset)
#   RUNNER_ARCH       X64 / ARM64 (default: uname -m)
#   KCOV_CACHE_SUDO   command prefix for writes under the prefix (default sudo)
#   KCOV_CACHE_LDD    ldd command (default ldd)

KCOV_CACHE_STAMP="cache-key"
KCOV_CACHE_TREE="tree"
# Seconds a staged `kcov --version` or its ldd probe may take; a hang is a
# reason to rebuild, never to wait for the step timeout.
KCOV_CACHE_VERIFY_TIMEOUT_SECONDS=10
KCOV_CACHE_KILL_AFTER=2s

# What kcov v43's `make install` puts down (CMakeLists.txt, src/ and doc/
# CMakeLists.txt at the pinned commit): "<mode> <path> <required|optional>".
# kcov-system-daemon is built on Linux only.
_kcov_cache_manifest() {
	printf '%s\n' \
		"0755 bin/kcov required" \
		"0755 bin/kcov-system-daemon optional" \
		"0644 share/doc/kcov/ChangeLog required" \
		"0644 share/doc/kcov/COPYING required" \
		"0644 share/doc/kcov/COPYING.externals required" \
		"0644 share/man/man1/kcov.1 required"
}

# The directories the allowlisted files live in.
_kcov_cache_dirs() {
	printf '%s\n' bin share share/doc share/doc/kcov share/man share/man/man1
}

# Print the version without its leading "v" (v43 -> 43).
_kcov_cache_bare_version() {
	printf '%s' "${1#v}"
}

# Print the sha256 of stdin, or nothing when no hashing tool works.
_kcov_cache_sha256_stdin() {
	local sum=""
	if command -v sha256sum >/dev/null 2>&1; then
		sum="$(sha256sum 2>/dev/null)" || sum=""
	elif command -v shasum >/dev/null 2>&1; then
		sum="$(shasum -a 256 2>/dev/null)" || sum=""
	fi
	sum="${sum%% *}"
	[[ "$sum" =~ ^[0-9a-f]{64}$ ]] && printf '%s' "$sum"
	return 0
}

# Print the sha256 of a file, or nothing when it cannot be read.
_kcov_cache_sha256() {
	[[ -r "$1" ]] || return 0
	_kcov_cache_sha256_stdin <"$1"
}

# Print the digest of the build recipe: this file plus the lines between
# "# kcov-recipe:begin" and "# kcov-recipe:end" in <run-bats-tests.sh>.
# Nothing when either is unreadable or the markers are missing, so a recipe
# that cannot be hashed keys nothing.
# Usage: kcov_cache_recipe_digest <run-bats-tests.sh>
kcov_cache_recipe_digest() {
	local script="$1" lib block
	lib="${BASH_SOURCE[0]}"
	[[ -r "$lib" && -r "$script" ]] || return 0
	block="$(awk '/^# kcov-recipe:begin$/ { on = 1 } on { print } /^# kcov-recipe:end$/ { on = 0 }' "$script")"
	[[ "$block" == *"# kcov-recipe:end" ]] || return 0
	{
		cat "$lib"
		printf '%s\n' "$block"
	} | _kcov_cache_sha256_stdin
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
# it applies none. <recipe> is kcov_cache_recipe_digest's output.
# Usage: kcov_cache_key <version> <commit> <patch-file> <recipe>
kcov_cache_key() {
	local version="$1" commit="$2" patch="${3:-}" recipe="${4:-}" patch_part="nopatch" os_part arch_part
	commit="$(printf '%s' "$commit" | tr '[:upper:]' '[:lower:]')"
	if [[ -n "$patch" ]]; then
		patch_part="$(_kcov_cache_sha256 "$patch")"
	fi
	os_part="$(kcov_cache_os_part)"
	arch_part="$(kcov_cache_arch_part)"
	if [[ ! "$version" =~ ^[A-Za-z0-9._-]+$ || ! "$commit" =~ ^[0-9a-f]{40}$ ||
		-z "$patch_part" || ! "$recipe" =~ ^[0-9a-f]{64}$ || -z "$os_part" || -z "$arch_part" ]]; then
		echo "kcov cache: no exact key (version=${version:-?} commit=${commit:-?}" \
			"patch=${patch_part:-?} recipe=${recipe:-?} os=${os_part:-?} arch=${arch_part:-?});" \
			"the cache is skipped" >&2
		return 0
	fi
	printf 'lgtm-kcov-%s-%s-%s-r%s-%s-%s' "$version" "$commit" "$patch_part" "$recipe" "$os_part" "$arch_part" |
		tr -c 'A-Za-z0-9._-' '-'
}

# Print why ldd cannot confirm that every shared library of <binary>
# resolves, or nothing when it confirms it. A missing ldd, an ldd error, an
# ldd that outlives its timeout and a library reported "not found" are all
# reasons not to use the stage.
kcov_cache_ldd_problem() {
	local binary="$1" ldd="${KCOV_CACHE_LDD:-ldd}" out rc=0 missing
	if ! command -v "$ldd" >/dev/null 2>&1; then
		printf '%s is not on PATH, so the shared libraries of %s are unchecked' "$ldd" "$binary"
		return 0
	fi
	out="$(timeout --kill-after="$KCOV_CACHE_KILL_AFTER" "${KCOV_CACHE_VERIFY_TIMEOUT_SECONDS}s" \
		"$ldd" "$binary" 2>&1)" || rc=$?
	if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
		printf 'ldd %s timed out after %ss' "$binary" "$KCOV_CACHE_VERIFY_TIMEOUT_SECONDS"
		return 0
	fi
	if [[ "$rc" -ne 0 ]]; then
		printf 'ldd %s failed (exit %s): %s' "$binary" "$rc" "$(printf '%s\n' "$out" | tail -n 1)"
		return 0
	fi
	missing="$(printf '%s\n' "$out" | awk '/=> not found/ { print $1 }' | paste -sd ' ' -)"
	if [[ -n "$missing" ]]; then
		printf '%s needs shared libraries ldd cannot resolve: %s' "$binary" "$missing"
	fi
	return 0
}

# Succeed when executing <binary> --version prints exactly "kcov <version>"
# (with or without the leading "v") and nothing else. Sets
# KCOV_CACHE_REPORTED to the first line it printed (or the exec failure) for
# the caller's message.
# Usage: kcov_cache_version_matches <binary> <version>
kcov_cache_version_matches() {
	local binary="$1" version="$2" out rc=0 bare
	out="$(timeout --kill-after="$KCOV_CACHE_KILL_AFTER" "${KCOV_CACHE_VERIFY_TIMEOUT_SECONDS}s" \
		"$binary" --version 2>&1)" || rc=$?
	KCOV_CACHE_REPORTED="$(printf '%s' "$out" | head -n 1)"
	if [[ "$rc" -ne 0 ]]; then
		KCOV_CACHE_REPORTED="exit ${rc}${KCOV_CACHE_REPORTED:+: ${KCOV_CACHE_REPORTED}}"
		return 1
	fi
	if [[ "$out" == *$'\n'* ]]; then
		KCOV_CACHE_REPORTED="${KCOV_CACHE_REPORTED} (and $(($(printf '%s\n' "$out" | wc -l) - 1)) more line(s))"
		return 1
	fi
	bare="$(_kcov_cache_bare_version "$version")"
	[[ "$out" == "kcov v${bare}" || "$out" == "kcov ${bare}" ]]
}

# Print why the kcov binary at <binary> cannot be used for <version>, or
# nothing when it is usable: a regular executable file, every shared library
# resolved, and `--version` printing exactly "kcov <version>".
kcov_cache_binary_problem() {
	local binary="$1" version="$2" problem
	if [[ -L "$binary" || ! -f "$binary" ]]; then
		printf 'no regular kcov binary at %s' "$binary"
		return 0
	fi
	if [[ ! -x "$binary" ]]; then
		printf '%s is not executable' "$binary"
		return 0
	fi
	problem="$(kcov_cache_ldd_problem "$binary")"
	if [[ -n "$problem" ]]; then
		printf '%s' "$problem"
		return 0
	fi
	if ! kcov_cache_version_matches "$binary" "$version"; then
		printf '%s --version reported "%s", expected exactly "kcov %s"' "$binary" "$KCOV_CACHE_REPORTED" "$version"
	fi
	return 0
}

# Print why <tree> is not exactly an allowlisted kcov install, or nothing:
# only regular files on the allowlist and their directories, no symlink or
# special file anywhere, and every required file present.
kcov_cache_tree_problem() {
	local tree="$1" entry rel mode path need
	if [[ -L "$tree" || ! -d "$tree" ]]; then
		printf 'no install tree at %s' "$tree"
		return 0
	fi
	local allowed_files allowed_dirs
	allowed_files="$(_kcov_cache_manifest | awk '{ print $2 }')"
	allowed_dirs="$(_kcov_cache_dirs)"
	while IFS= read -r -d '' entry; do
		rel="${entry#"$tree"/}"
		if [[ -L "$entry" ]]; then
			printf '%s holds a symlink: %s' "$tree" "$rel"
			return 0
		elif [[ -d "$entry" ]]; then
			if ! grep -qxF -- "$rel" <<<"$allowed_dirs"; then
				printf '%s holds an unexpected directory: %s' "$tree" "$rel"
				return 0
			fi
		elif [[ -f "$entry" ]]; then
			if ! grep -qxF -- "$rel" <<<"$allowed_files"; then
				printf '%s holds a file outside the kcov allowlist: %s' "$tree" "$rel"
				return 0
			fi
		else
			printf '%s holds an entry that is not a regular file or directory: %s' "$tree" "$rel"
			return 0
		fi
	done < <(find "$tree" -mindepth 1 -print0)
	while read -r mode path need; do
		: "$mode"
		if [[ "$need" == required && ! -f "$tree/$path" ]]; then
			printf '%s misses %s' "$tree" "$path"
			return 0
		fi
	done < <(_kcov_cache_manifest)
	return 0
}

# Install the allowlisted files of <tree> into <prefix>, each with its fixed
# mode (install -m), after kcov_cache_tree_problem passes. Nothing else in
# the tree is copied. Returns 1 (message on stdout) on any problem.
# Usage: kcov_cache_install <tree> <prefix>
kcov_cache_install() {
	local tree="$1" prefix="$2" problem mode path need sudo
	sudo="${KCOV_CACHE_SUDO-sudo}"
	problem="$(kcov_cache_tree_problem "$tree")"
	if [[ -n "$problem" ]]; then
		printf '%s' "$problem"
		return 1
	fi
	while read -r mode path need; do
		: "$need"
		[[ -f "$tree/$path" ]] || continue
		if ! $sudo mkdir -p "$prefix/$(dirname "$path")" ||
			! $sudo install -m "$mode" "$tree/$path" "$prefix/$path"; then
			printf 'installing %s into %s failed' "$path" "$prefix"
			return 1
		fi
	done < <(_kcov_cache_manifest)
	return 0
}

# Install kcov from <stage> into <prefix> when the stage was built for <key>,
# its tree is exactly the allowlisted install and its kcov passes
# kcov_cache_binary_problem, before and after the install.
# Returns 0 when kcov is installed from the stage, 1 when the caller must build.
# Usage: kcov_cache_restore <stage> <key> <version> <prefix>
kcov_cache_restore() {
	local stage="$1" key="$2" version="$3" prefix="$4" stamp="" problem tree
	tree="$stage/$KCOV_CACHE_TREE"
	if [[ -z "$key" ]]; then
		echo "kcov cache: no exact key; building kcov ${version} from source"
		return 1
	fi
	if [[ ! -e "$stage" && ! -L "$stage" ]]; then
		echo "kcov cache: no staged build at ${stage}; building kcov ${version} from source"
		return 1
	fi
	if [[ -L "$stage" || ! -d "$stage" ]]; then
		echo "::warning title=kcov cache unusable::${stage} is not a plain directory; building from source"
		return 1
	fi
	if [[ -f "$stage/$KCOV_CACHE_STAMP" && ! -L "$stage/$KCOV_CACHE_STAMP" ]]; then
		stamp="$(head -n 1 "$stage/$KCOV_CACHE_STAMP")"
	fi
	if [[ "$stamp" != "$key" ]]; then
		echo "::warning title=kcov cache unusable::staged kcov at ${stage} was built for '${stamp:-no key}', not '${key}'; building from source"
		return 1
	fi
	problem="$(kcov_cache_tree_problem "$tree")"
	if [[ -z "$problem" ]]; then
		problem="$(kcov_cache_binary_problem "$tree/bin/kcov" "$version")"
	fi
	if [[ -n "$problem" ]]; then
		echo "::warning title=kcov cache unusable::${problem}; building from source"
		return 1
	fi
	if ! problem="$(kcov_cache_install "$tree" "$prefix")"; then
		echo "::warning title=kcov cache unusable::${problem}; building from source"
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

# Move a fresh `make install DESTDIR=` tree (<built>, the prefix inside the
# DESTDIR) into <stage> for the cache when it is exactly the allowlisted
# install and its kcov passes kcov_cache_binary_problem. Returns 0 when the
# stage holds it (install from <stage>/tree), 1 when it was not staged
# (<built> is left in place; install from it).
# Usage: kcov_cache_populate <stage> <key> <version> <built>
kcov_cache_populate() {
	local stage="$1" key="$2" version="$3" built="$4" problem
	if [[ -z "$key" ]]; then
		echo "kcov cache: no exact key; the build is not staged"
		return 1
	fi
	problem="$(kcov_cache_tree_problem "$built")"
	if [[ -z "$problem" ]]; then
		problem="$(kcov_cache_binary_problem "$built/bin/kcov" "$version")"
	fi
	if [[ -n "$problem" ]]; then
		echo "::warning title=kcov cache not populated::${problem}; the cache is not saved"
		return 1
	fi
	rm -rf "$stage" || true
	if ! mkdir -p "$stage" ||
		! mv "$built" "$stage/$KCOV_CACHE_TREE" ||
		! printf '%s\n' "$key" >"$stage/$KCOV_CACHE_STAMP"; then
		echo "::warning title=kcov cache not populated::writing ${stage} failed; the cache is not saved"
		if [[ -d "$stage/$KCOV_CACHE_TREE" && ! -e "$built" ]]; then
			mv "$stage/$KCOV_CACHE_TREE" "$built" || true
		fi
		rm -rf "$stage" || true
		return 1
	fi
	echo "kcov cache: staged kcov ${version} at ${stage} (${key})"
	return 0
}
