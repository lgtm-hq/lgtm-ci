#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail early when @playwright/test is too old for the runner image (#1313)
#
# Usage:
#   source "$(dirname "${BASH_SOURCE:-$0}")/playwright_runner.sh"
#   check_playwright_runner_support "$version"
#
# Optional environment variables:
#   OS_RELEASE_FILE - os-release file to read (default: /etc/os-release); lets
#                     tests avoid reading the host file

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_PLAYWRIGHT_RUNNER_LOADED:-}" ]] && return 0
readonly _LGTM_CI_PLAYWRIGHT_RUNNER_LOADED=1

_PLAYWRIGHT_RUNNER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
if ! declare -F log_info >/dev/null 2>&1; then
	# shellcheck source=../log.sh
	source "$_PLAYWRIGHT_RUNNER_LIB_DIR/../log.sh"
fi

# Single source of truth for the minimum @playwright/test (major.minor) whose
# browser builds support Ubuntu 26.04. Upstream: "Playwright now supports
# Ubuntu 26.04" in the v1.61.0 release notes,
# https://github.com/microsoft/playwright/releases/tag/v1.61.0 (v1.60.0 notes
# carry no such entry).
PLAYWRIGHT_MIN_VERSION_UBUNTU_2604="1.61"

# Print the VERSION_ID of the running OS (empty when unreadable).
playwright_runner_os_version_id() {
	local file="${OS_RELEASE_FILE:-/etc/os-release}"
	local id="" version_id=""
	[[ -r "$file" ]] || return 0
	while IFS='=' read -r key value; do
		value="${value%\"}"
		value="${value#\"}"
		case "$key" in
		ID) id="$value" ;;
		VERSION_ID) version_id="$value" ;;
		esac
	done <"$file"
	[[ "$id" == "ubuntu" ]] && printf '%s' "$version_id"
	return 0
}

# Return 0 when version $1 (e.g. 1.55.0) is below minimum $2 (major.minor).
# Return 2 when $1 is not parseable as major.minor.
playwright_version_below() {
	local version="$1" minimum="$2"
	local major minor min_major min_minor
	if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+) ]]; then
		return 2
	fi
	major="${BASH_REMATCH[1]}"
	minor="${BASH_REMATCH[2]}"
	min_major="${minimum%%.*}"
	min_minor="${minimum#*.}"
	((10#$major < 10#$min_major || (10#$major == 10#$min_major && 10#$minor < 10#$min_minor)))
}

# Return 0 when the running OS is Ubuntu 26.04 (detected from os-release, not
# from the runs-on label).
playwright_runner_is_ubuntu_2604() {
	[[ "$(playwright_runner_os_version_id)" == "26.04" ]]
}

# Fail (return 1) with an ::error:: when the runner is Ubuntu 26.04 and the
# resolved @playwright/test version is below the minimum. An unresolvable
# version warns and continues.
# Usage: check_playwright_runner_support <version>
check_playwright_runner_support() {
	local version="${1:-unknown}"
	local minimum="$PLAYWRIGHT_MIN_VERSION_UBUNTU_2604"

	playwright_runner_is_ubuntu_2604 || return 0

	local rc=0
	playwright_version_below "$version" "$minimum" || rc=$?
	case "$rc" in
	0)
		echo "::error::@playwright/test ${version} has no browser builds for Ubuntu 26.04; ${minimum} or newer is required. Bump @playwright/test to ${minimum}+ (runner-image: ubuntu-24.04 is a temporary escape hatch only)."
		return 1
		;;
	2)
		echo "::warning::Could not resolve the @playwright/test version (got '${version}'); skipping the Ubuntu 26.04 minimum check (requires ${minimum}+)."
		;;
	esac
	return 0
}

# Return 0 on a Linux runner (RUNNER_OS, else uname), the only OS where
# Playwright's browsers need system packages from apt.
playwright_runner_is_linux() {
	[[ "${RUNNER_OS:-$(uname -s)}" == "Linux" ]]
}

# Install Playwright browsers (#1432).
#
# On Linux the system packages are installed by the shared apt helper, never
# by Playwright: `apt_helper.py update` refreshes the package lists,
# `playwright install-deps --dry-run` reports the packages (parsed by
# playwright_deps.py), `apt_helper.py install --no-install-recommends`
# installs them (as Playwright itself would), and
# `playwright install` downloads the browsers without --with-deps. When the
# dry run's output is not recognised, a ::warning:: is printed and the
# original `playwright install --with-deps` runs instead, which is what ran
# before. Off Linux (macOS, Windows) `install --with-deps` runs unchanged: it
# never calls apt there.
#
# Usage: playwright_install_browsers <browsers|all> <launcher...>
#   browsers - space-separated browser names, or "all" (no names)
#   launcher - the command that runs the Playwright CLI, e.g. npx playwright
playwright_install_browsers() {
	local browsers="${1:?playwright_install_browsers: browsers required}"
	shift
	[[ $# -gt 0 ]] || {
		log_error "playwright_install_browsers: launcher required"
		return 2
	}
	local -a names=() packages=()
	if [[ "$browsers" != "all" ]]; then
		read -ra names <<<"$browsers"
	fi
	if ! playwright_runner_is_linux; then
		"$@" install --with-deps "${names[@]+"${names[@]}"}"
		return
	fi

	local lib="$_PLAYWRIGHT_RUNNER_LIB_DIR/.." dry_run="" dry_rc=0 parsed=""
	python3 -I "$lib/apt_helper.py" update || return $?
	dry_run="$("$@" install-deps --dry-run "${names[@]+"${names[@]}"}" 2>&1)" || dry_rc=$?
	if ! parsed="$(printf '%s\n' "$dry_run" |
		python3 -I "$lib/playwright_deps.py" --exit-code "$dry_rc")"; then
		echo "::warning title=Playwright system packages::playwright install-deps --dry-run output was not recognised; falling back to playwright install --with-deps, which runs apt without the shared helper's timeouts and retries"
		"$@" install --with-deps "${names[@]+"${names[@]}"}"
		return
	fi
	read -ra packages <<<"$(printf '%s' "$parsed" | tr '\n' ' ')"
	if [[ ${#packages[@]} -gt 0 ]]; then
		log_info "Installing ${#packages[@]} Playwright system packages through the apt helper..."
		python3 -I "$lib/apt_helper.py" install --no-install-recommends "${packages[@]}" || return $?
	else
		log_info "Playwright reports every system package installed"
	fi
	"$@" install "${names[@]+"${names[@]}"}"
}
