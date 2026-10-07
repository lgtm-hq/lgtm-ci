#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Install the pinned CLI binary for one (provider, transport) pair.
#
# Gated: does nothing when transport is not cli or the provider is unknown.
# Versions come from scripts/ci/versions.env. The npm CLIs install with
# `npm ci` from the committed, integrity-pinned lockfiles under
# scripts/ci/ai-review-cli/<binary>/ (Renovate's npm manager keeps the
# lockfile and versions.env in step; test_tool_pins.bats asserts they agree).
# Cursor has no registry datasource — bump version and both checksums together
# in versions.env.
#
# Environment:
#   PROVIDER                 Resolved provider (anthropic|cursor|openai)
#   TRANSPORT                Resolved transport (cli|api)
#   CLAUDE_CODE_VERSION      npm @anthropic-ai/claude-code (anthropic/cli)
#   CODEX_VERSION            npm @openai/codex (openai/cli)
#   CURSOR_AGENT_VERSION     Calendar build id (cursor/cli)
#   CURSOR_AGENT_SHA256_X64  sha256 of the linux/x64 tarball
#   CURSOR_AGENT_SHA256_ARM64 sha256 of the linux/arm64 tarball
#   AI_TOOLS_PREFIX          Install prefix (default: $RUNNER_TEMP/ai-tools)
#
# Overriding an npm CLI version away from the lockfile pin bypasses the
# lockfile; that is refused unless LGTM_CI_ALLOW_UNVERIFIED=1 (then
# `npm install -g pkg@version` runs with registry-side integrity only).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ai_review_matrix.sh
source "${SCRIPT_DIR}/../lib/ai_review_matrix.sh"
# shellcheck source=../lib/github/output.sh
source "${SCRIPT_DIR}/../lib/github/output.sh"
# shellcheck source=../lib/network/download.sh
source "${SCRIPT_DIR}/../lib/network/download.sh"
# shellcheck source=../lib/supply_chain.sh
source "${SCRIPT_DIR}/../lib/supply_chain.sh"
# shellcheck source=../versions.env
source "${SCRIPT_DIR}/../versions.env"

CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-$DEFAULT_CLAUDE_CODE_VERSION}"
CODEX_VERSION="${CODEX_VERSION:-$DEFAULT_CODEX_VERSION}"
CURSOR_AGENT_VERSION="${CURSOR_AGENT_VERSION:-$DEFAULT_CURSOR_AGENT_VERSION}"
CURSOR_AGENT_SHA256_X64="${CURSOR_AGENT_SHA256_X64:-$DEFAULT_CURSOR_AGENT_SHA256_X64}"
CURSOR_AGENT_SHA256_ARM64="${CURSOR_AGENT_SHA256_ARM64:-$DEFAULT_CURSOR_AGENT_SHA256_ARM64}"
LOCKFILE_DIR="${SCRIPT_DIR}/../ai-review-cli"

provider="$(ai_review_normalize "${PROVIDER:-}")"
transport="$(ai_review_normalize "${TRANSPORT:-}")"
binary="$(ai_review_cli_binary "$provider" "$transport")"

if [[ -z "$binary" ]]; then
	echo "install-ai-review-cli: no CLI binary for provider=${provider:-<unset>} transport=${transport:-<unset>}; skipping"
	exit 0
fi

require_exact_semver() {
	local name="$1" value="$2"
	if [[ ! "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "ERROR: ${name} must be an exact X.Y.Z version (got '${value}')" >&2
		exit 1
	fi
}

# Version pinned for a package in the committed lockfile directory.
lockfile_version() {
	local dir="$1" package="$2"
	node -p "require(process.argv[1]).dependencies[process.argv[2]]" \
		"${dir}/package.json" "$package"
}

# Install from the committed lockfile: copy package.json + package-lock.json to
# a scratch prefix and run `npm ci` there, then expose node_modules/.bin.
# Usage: install_npm_cli <binary> <package> <version>
install_npm_cli() {
	local name="$1" package="$2" version="$3"
	local src="${LOCKFILE_DIR}/${name}" prefix dir pinned
	require_exact_semver "${package}" "$version"
	if [[ ! -f "${src}/package-lock.json" ]]; then
		echo "::error::missing committed lockfile ${src}/package-lock.json" >&2
		exit 1
	fi
	pinned="$(lockfile_version "$src" "$package")"
	prefix="${AI_TOOLS_PREFIX:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ai-tools}"
	dir="${prefix}/${name}"
	mkdir -p "$dir"

	if [[ "$version" != "$pinned" ]]; then
		if ! supply_chain_unverified_allowed; then
			echo "::error title=unverified install::${package}@${version} requested but the committed lockfile pins ${pinned}; set LGTM_CI_ALLOW_UNVERIFIED=1 to install outside the lockfile" >&2
			exit 1
		fi
		echo "::warning title=unverified install::${package}@${version} installed outside the committed lockfile (LGTM_CI_ALLOW_UNVERIFIED=1 set by caller)" >&2
		echo "Installing ${package}@${version}..."
		npm install -g --no-fund --no-audit "${package}@${version}"
		return 0
	fi

	echo "Installing ${package}@${version} from the committed lockfile..."
	cp "${src}/package.json" "${src}/package-lock.json" "$dir/"
	(cd "$dir" && npm ci --no-fund --no-audit)
	add_github_path "${dir}/node_modules/.bin"
	export PATH="${dir}/node_modules/.bin:${PATH}"
}

install_cursor_agent() {
	# NOTE: tmp is deliberately NOT local — the EXIT trap below runs at script
	# exit, outside this function's scope, and `set -u` would kill the trap
	# (and fail the step) on an unbound local.
	local arch machine expected url dir prefix
	if [[ ! "${CURSOR_AGENT_VERSION}" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[A-Za-z0-9]+$ ]]; then
		echo "ERROR: CURSOR_AGENT_VERSION must be a calendar build id (YYYY.MM.DD-<rev>)" >&2
		exit 1
	fi
	machine="$(uname -m)"
	case "$machine" in
	x86_64 | amd64) arch="x64" expected="$CURSOR_AGENT_SHA256_X64" ;;
	aarch64 | arm64) arch="arm64" expected="$CURSOR_AGENT_SHA256_ARM64" ;;
	*)
		echo "ERROR: unsupported architecture: $machine" >&2
		exit 1
		;;
	esac
	if [[ ! "${expected}" =~ ^[a-fA-F0-9]{64}$ ]]; then
		echo "ERROR: Cursor agent sha256 must be a 64-character hex digest" >&2
		exit 1
	fi
	prefix="${AI_TOOLS_PREFIX:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ai-tools}"
	url="https://downloads.cursor.com/lab/${CURSOR_AGENT_VERSION}/linux/${arch}/agent-cli-package.tar.gz"
	dir="${prefix}/cursor/${CURSOR_AGENT_VERSION}"
	tmp="$(mktemp -d)"
	trap 'rm -rf "${tmp:-}"' EXIT
	echo "Installing Cursor agent ${CURSOR_AGENT_VERSION} (${arch})..."
	if ! download_with_retries "$url" "${tmp}/agent-cli-package.tar.gz"; then
		echo "ERROR: failed to download Cursor agent tarball from ${url}" >&2
		exit 1
	fi
	echo "${expected}  ${tmp}/agent-cli-package.tar.gz" | sha256sum -c -
	mkdir -p "${prefix}/bin" "$dir"
	tar -xzf "${tmp}/agent-cli-package.tar.gz" -C "$dir" --strip-components=1
	if [[ ! -x "${dir}/cursor-agent" ]]; then
		echo "ERROR: unpacked tarball has no executable cursor-agent binary" >&2
		exit 1
	fi
	ln -sfn "${dir}/cursor-agent" "${prefix}/bin/agent"
	ln -sfn "${dir}/cursor-agent" "${prefix}/bin/cursor-agent"
	add_github_path "${prefix}/bin"
	export PATH="${prefix}/bin:${PATH}"
}

case "$binary" in
claude)
	install_npm_cli claude "@anthropic-ai/claude-code" "$CLAUDE_CODE_VERSION"
	claude --version
	;;
codex)
	install_npm_cli codex "@openai/codex" "$CODEX_VERSION"
	codex --version
	;;
agent)
	install_cursor_agent
	agent --version
	;;
*)
	echo "ERROR: unknown CLI binary '${binary}'" >&2
	exit 1
	;;
esac
