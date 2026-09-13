#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Channel detection for the release recovery workflow (#966).
#
# Probes each configured publish channel for the release version and emits:
#   1. a markdown summary table (channel, state, detail) to the step summary
#      and stdout, and
#   2. the missing set as a JSON array (to $GITHUB_OUTPUT when set), which
#      gates the per-channel resume jobs. A dry run stops here by design:
#      detection changes nothing.
#
# A channel is probed only when its configuration inputs are present; a
# channel without configuration is NOT-APPLICABLE, never "missing" — a
# caller that never publishes Docker would otherwise never go green.
#
# PyPI is special by policy: a version is burned on the first upload, so
# PyPI is reported DONE or MISSING-FOREVER (tier three); it is never a
# resume target.
#
# Environment:
#   TAG            Release tag, e.g. v1.2.3 (required)
#   VERSION        Version without the leading v (default: TAG stripped of v)
#   CHANNELS       Comma/JSON list to restrict probing (default: auto = all
#                  channels with configuration)
#   PYPI_PACKAGE   PyPI project name; empty skips the PyPI probe
#   NPM_PACKAGE    npm package name (the meta package); empty skips npm
#   RELEASE_TAG_MODE  unused placeholder for symmetry with TAG
#   DOCKER_IMAGE   Fully-qualified image reference (registry/name); empty skips
#   TAP_REPO       Homebrew tap repository (owner/repo); empty skips
#   TAP_FORMULA    Formula name in the tap
#   GH_CMD / NPM_CMD / CRANE_CMD  binary overrides (gh/npm/crane)
#   GITHUB_REPOSITORY, GH_TOKEN  for the GitHub Release probe
#   GITHUB_OUTPUT  missing=<json> written when set
#   GITHUB_STEP_SUMMARY  table appended when set

set -euo pipefail

: "${TAG:?TAG is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
VERSION="${VERSION:-${TAG#v}}"
CHANNELS="${CHANNELS:-auto}"
PYPI_PACKAGE="${PYPI_PACKAGE:-}"
NPM_PACKAGE="${NPM_PACKAGE:-}"
DOCKER_IMAGE="${DOCKER_IMAGE:-}"
TAP_REPO="${TAP_REPO:-}"
TAP_FORMULA="${TAP_FORMULA:-}"
GH="${GH_CMD:-gh}"
NPM="${NPM_CMD:-npm}"
CRANE="${CRANE_CMD:-crane}"

# Normalize the channel restriction list to a newline set.
restrictions() {
	if [[ "$CHANNELS" == "auto" ]]; then
		return 1
	fi
	if [[ "$CHANNELS" == \[*\] ]]; then
		printf '%s\n' "$CHANNELS" | jq -r '.[]'
	else
		echo "$CHANNELS" | tr ',' '\n'
	fi
}

channel_selected() {
	local channel="$1"
	if restrictions >/dev/null 2>&1; then
		grep -qxF "$channel" < <(restrictions)
	else
		return 0 # auto
	fi
}

declare -a ROWS=()
declare -a MISSING=()

# A probe is "<channel>|<state>|<detail>" where state is
# DONE | MISSING | NOT-APPLICABLE. MISSING rows feed the resume set — except
# pypi, whose missing state is terminal (tier three) by policy.
record() {
	local channel="$1" state="$2" detail="$3"
	ROWS+=("| $channel | $state | $detail |")
	if [[ "$state" == "MISSING" && "$channel" != "pypi" ]]; then
		MISSING+=("\"$channel\"")
	fi
}

probe_pypi() {
	[[ -n "$PYPI_PACKAGE" ]] || {
		record "pypi" "NOT-APPLICABLE" "no PYPI_PACKAGE configured"
		return 0
	}
	local code
	code="$(curl -s -o /dev/null -w '%{http_code}' "https://pypi.org/pypi/${PYPI_PACKAGE}/${VERSION}/json" 2>/dev/null || echo 000)"
	if [[ "$code" == "200" ]]; then
		record "pypi" "DONE" "version visible on PyPI"
	else
		# Terminal by policy: a burned version cannot be resumed.
		record "pypi" "MISSING" "not on PyPI (HTTP ${code}); a PyPI version is burned on first upload — tier three: new patch version"
	fi
}

probe_npm() {
	[[ -n "$NPM_PACKAGE" ]] || {
		record "npm" "NOT-APPLICABLE" "no NPM_PACKAGE configured"
		return 0
	}
	if "$NPM" view "${NPM_PACKAGE}@${VERSION}" version >/dev/null 2>&1; then
		record "npm" "DONE" "version visible on npm"
	else
		record "npm" "MISSING" "version absent from npm; resume via reusable-publish-npm-set"
	fi
}

probe_github_release() {
	local assets
	assets="$("$GH" release view "$TAG" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets | length' 2>/dev/null || echo 0)"
	if [[ "$assets" =~ ^[0-9]+$ && "$assets" -gt 0 ]]; then
		record "github-release" "DONE" "release exists with ${assets} asset(s)"
	else
		# Distinguish no-release from asset-less release in the detail.
		if "$GH" release view "$TAG" --repo "$GITHUB_REPOSITORY" --json assets >/dev/null 2>&1; then
			record "github-release" "MISSING" "release exists without assets; resume via create-github-release.sh"
		else
			record "github-release" "MISSING" "release does not exist; resume via create-github-release.sh"
		fi
	fi
}

probe_docker() {
	[[ -n "$DOCKER_IMAGE" ]] || {
		record "docker" "NOT-APPLICABLE" "no DOCKER_IMAGE configured"
		return 0
	}
	if "$CRANE" digest "${DOCKER_IMAGE}:${VERSION}" >/dev/null 2>&1; then
		record "docker" "DONE" "image tag digest resolvable"
	else
		record "docker" "MISSING" "image tag absent; promote the original staging digests"
	fi
}

probe_homebrew() {
	[[ -n "$TAP_REPO" && -n "$TAP_FORMULA" ]] || {
		record "homebrew" "NOT-APPLICABLE" "no TAP_REPO/TAP_FORMULA configured"
		return 0
	}
	if "$GH" api "repos/${TAP_REPO}/contents/Formula/${TAP_FORMULA}.rb" --jq '.content' 2>/dev/null |
		base64 -d 2>/dev/null | grep -q "version .*${VERSION}"; then
		record "homebrew" "DONE" "formula version matches"
	else
		record "homebrew" "MISSING" "formula missing or stale; resend the tap dispatch"
	fi
}

channel_selected pypi && probe_pypi
channel_selected npm && probe_npm
channel_selected github-release && probe_github_release
channel_selected docker && probe_docker
channel_selected homebrew && probe_homebrew

table="| Channel | State | Detail |
| --- | --- | --- |"
for row in "${ROWS[@]}"; do
	table+=$'\n'"$row"
done
echo "$table"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
	{
		echo "## Release recovery: channel detection (${TAG})"
		echo ""
		echo "$table"
	} >>"${GITHUB_STEP_SUMMARY}"
fi

missing_json="[]"
if ((${#MISSING[@]} > 0)); then
	missing_json="[$(IFS=,; echo "${MISSING[*]}")]"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	{
		echo "missing=${missing_json}"
		echo "missing_count=$((${#MISSING[@]}))"
	} >>"${GITHUB_OUTPUT}"
fi
echo "Missing channels: ${missing_json}"
