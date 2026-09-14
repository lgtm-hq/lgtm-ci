#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Channel detection for the release recovery workflow (#966).
#
# Probes each configured publish channel for the release version and emits:
#   1. a markdown summary table (channel, state, detail) to the step summary
#      and stdout, and
#   2. the missing set as a JSON array (to $GITHUB_OUTPUT when set), which
#      gates the per-channel resume jobs, plus the unresumable set (missing
#      channels no resume job can repair: PyPI by policy, Docker for now) so
#      the record stage never closes an incident that still has work left.
#      A dry run stops here by design: detection changes nothing.
#
# A channel is probed only when its configuration inputs are present; a
# channel without configuration is NOT-APPLICABLE, never "missing" — a
# caller that never publishes Docker would otherwise never go green.
#
# The GitHub Release is complete only when EVERY asset the verified manifest
# lists is published with the SAME digest: a release with some assets is
# partial (resumed), and a published asset whose digest differs from the
# attested artifact is MISMATCH — tier three, and this script exits 1.
#
# PyPI is special by policy: a version is burned on the first upload, so
# PyPI is reported DONE or MISSING (tier three); it is never a resume target.
#
# Environment:
#   TAG            Release tag, e.g. v1.2.3 (required)
#   VERSION        Version without the leading v (default: TAG stripped of v)
#   CHANNELS       Comma/JSON list to restrict probing (default: auto = all
#                  channels with configuration)
#   PYPI_PACKAGE   PyPI project name; empty skips the PyPI probe
#   NPM_PACKAGE    npm package name (the meta package); empty skips npm
#   RELEASE_MANIFEST  SHA256SUMS manifest of the verified release artifacts;
#                  empty skips the GitHub Release probe (not applicable)
#   DOCKER_IMAGE   Fully-qualified image reference (registry/name); empty skips
#   TAP_REPO       Homebrew tap repository (owner/repo); empty skips
#   TAP_FORMULA    Formula name in the tap
#   GH_CMD / NPM_CMD / CRANE_CMD  binary overrides (gh/npm/crane)
#   GITHUB_REPOSITORY, GH_TOKEN  for the GitHub Release probe
#   GITHUB_OUTPUT  missing=<json>, unresumable=<json> written when set
#   GITHUB_STEP_SUMMARY  table appended when set

set -euo pipefail

: "${TAG:?TAG is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
VERSION="${VERSION:-${TAG#v}}"
CHANNELS="${CHANNELS:-auto}"
PYPI_PACKAGE="${PYPI_PACKAGE:-}"
NPM_PACKAGE="${NPM_PACKAGE:-}"
RELEASE_MANIFEST="${RELEASE_MANIFEST:-}"
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
declare -a UNRESUMABLE=()
mismatch=0

# Channels a resume job exists for; a MISSING channel outside this set is
# unresumable and keeps the incident open.
RESUMABLE_RE='^(npm|github-release|homebrew)$'

# A probe is "<channel>|<state>|<detail>" where state is
# DONE | MISSING | MISMATCH | NOT-APPLICABLE. MISSING rows feed the resume
# set when a resume job exists, the unresumable set otherwise; MISMATCH is
# tier three and fails the run after the table is printed.
record() {
	local channel="$1" state="$2" detail="$3"
	ROWS+=("| $channel | $state | $detail |")
	case "$state" in
	MISSING)
		if [[ "$channel" =~ $RESUMABLE_RE ]]; then
			MISSING+=("\"$channel\"")
		else
			UNRESUMABLE+=("\"$channel\"")
		fi
		;;
	MISMATCH)
		UNRESUMABLE+=("\"$channel\"")
		mismatch=1
		;;
	esac
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
	[[ -n "$RELEASE_MANIFEST" ]] || {
		record "github-release" "NOT-APPLICABLE" "no release artifact configured"
		return 0
	}
	[[ -f "$RELEASE_MANIFEST" ]] || {
		record "github-release" "MISMATCH" "release manifest '$RELEASE_MANIFEST' not found; cannot prove completeness"
		return 0
	}
	# name<TAB>digest per published asset; a missing release is an empty list.
	local published
	if ! published="$("$GH" release view "$TAG" --repo "$GITHUB_REPOSITORY" --json assets \
		--jq '.assets[] | [.name, (.digest // "")] | @tsv' 2>/dev/null)"; then
		record "github-release" "MISSING" "release does not exist; resume via create-github-release.sh"
		return 0
	fi
	local expected_total=0 present=0 absent=() different=()
	local hash path name pub_digest
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		hash="${line%%[[:space:]]*}"
		path="$(printf '%s\n' "$line" | awk '{ $1 = ""; sub(/^[[:space:]]+/, ""); print }')"
		[[ -n "$path" ]] || continue
		expected_total=$((expected_total + 1))
		name="$(basename "$path")"
		pub_digest="$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' <<<"$published")"
		if ! grep -qxF "$name" < <(awk -F'\t' '{ print $1 }' <<<"$published"); then
			absent+=("$name")
		elif [[ "$pub_digest" != "sha256:${hash}" ]]; then
			# An asset without a digest cannot be proven identical: fail closed.
			different+=("$name (published ${pub_digest:-no digest}, attested sha256:${hash})")
		else
			present=$((present + 1))
		fi
	done <"$RELEASE_MANIFEST"
	if ((${#different[@]} > 0)); then
		record "github-release" "MISMATCH" "published asset bytes differ from the attested artifacts: ${different[*]} — tier three: cut a new patch version"
	elif ((expected_total == 0)); then
		record "github-release" "MISMATCH" "release manifest lists no assets; cannot prove completeness"
	elif ((${#absent[@]} > 0)); then
		record "github-release" "MISSING" "${present}/${expected_total} manifest assets published; absent: ${absent[*]}; resume via create-github-release.sh"
	else
		record "github-release" "DONE" "all ${expected_total} manifest assets published with matching digests"
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
	# Parse the formula's `version "X"` string and compare it exactly: no
	# regex over the file, no prefix/suffix matches (1.2.3 must not accept
	# 1.2.30 or 11.2.3).
	local formula_version
	formula_version="$("$GH" api "repos/${TAP_REPO}/contents/Formula/${TAP_FORMULA}.rb" --jq '.content' 2>/dev/null |
		base64 -d 2>/dev/null |
		awk 'match($0, /^[[:space:]]*version[[:space:]]+"[^"]*"/) { s = substr($0, RSTART, RLENGTH); sub(/^[[:space:]]*version[[:space:]]+"/, "", s); sub(/"$/, "", s); print s; exit }')" || formula_version=""
	if [[ -z "$formula_version" ]]; then
		record "homebrew" "MISSING" "formula missing or has no version string; resend the tap dispatch"
	elif [[ "$formula_version" == "$VERSION" ]]; then
		record "homebrew" "DONE" "formula version ${formula_version} matches"
	else
		record "homebrew" "MISSING" "formula version is ${formula_version}, expected ${VERSION}; resend the tap dispatch"
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
	missing_json="[$(
		IFS=,
		echo "${MISSING[*]}"
	)]"
fi
unresumable_json="[]"
if ((${#UNRESUMABLE[@]} > 0)); then
	unresumable_json="[$(
		IFS=,
		echo "${UNRESUMABLE[*]}"
	)]"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	{
		echo "missing=${missing_json}"
		echo "missing_count=$((${#MISSING[@]}))"
		echo "unresumable=${unresumable_json}"
	} >>"${GITHUB_OUTPUT}"
fi
echo "Missing channels: ${missing_json}"
echo "Unresumable channels: ${unresumable_json}"
if ((mismatch)); then
	echo "ERROR: published bytes differ from the attested artifacts (see MISMATCH above); recovery refused — tier three: cut a new patch version." >&2
	exit 1
fi
