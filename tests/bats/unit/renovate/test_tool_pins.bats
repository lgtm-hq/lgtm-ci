#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Prove #1062/#1096 supplier pins are regex-visible to renovate.json,
#          that scripts/ci/versions.env is the single source for every tool
#          version installed by scripts/ci, and that every remaining YAML copy
#          equals its annotated source.

load "../../../helpers/common"
load "../../../helpers/mocks"

MATCHER="${PROJECT_ROOT}/scripts/ci/maintenance/match-renovate-pins.py"
RENOVATE_JSON="${PROJECT_ROOT}/renovate.json"
VERSIONS_ENV="${PROJECT_ROOT}/scripts/ci/versions.env"

# Value of one DEFAULT_* assignment in versions.env.
_pin() {
	sed -n "s/^${1}=\"\([^\"]*\)\".*/\1/p" "$VERSIONS_ENV"
}

# =============================================================================
# renovate.json shape
# =============================================================================

@test "renovate.json: versions.env manager captures version and digest lines" {
	run jq -r '.customManagers[] | select(.description | test("Supplier tool pins")) | .managerFilePatterns[]' \
		"$RENOVATE_JSON"
	assert_success
	assert_output '/^scripts/ci/versions\.env$/'
	run jq -r '.customManagers[] | select(.description | test("Supplier tool pins")) | .matchStrings | length' \
		"$RENOVATE_JSON"
	assert_output "2"
	run jq -r '.customManagers[] | select(.description | test("Supplier tool pins")) | .matchStrings[1]' \
		"$RENOVATE_JSON"
	assert_output --partial "currentDigest"
	assert_output --partial "SHA256|COMMIT"
}

@test "renovate.json: no manager still scans scripts/*.sh for private annotations" {
	run jq -r '.customManagers[].managerFilePatterns[]' "$RENOVATE_JSON"
	assert_success
	refute_output --partial 'scripts/.*\\.sh'
}

@test "renovate.json: YAML manager lists the annotated action and workflow files" {
	run jq -r '.customManagers[] | select(.description | test("YAML version pins")) | .managerFilePatterns[]' \
		"$RENOVATE_JSON"
	assert_success
	assert_output --partial "setup-python"
	assert_output --partial "setup-node"
	assert_output --partial "reusable-test-node"
	refute_output --partial "reusable-ai-review"
}

@test "renovate.json: digest-only versions.env updates are never automerged" {
	run jq -r '.packageRules[] | select(.matchFileNames != null and (.matchFileNames | index("scripts/ci/versions.env"))) | "\(.matchUpdateTypes | join(",")) automerge=\(.automerge)"' \
		"$RENOVATE_JSON"
	assert_success
	assert_output "digest automerge=false"
}

@test "renovate.json: validator accepts the config (recorded run)" {
	# `bunx --package renovate renovate-config-validator` was run against this
	# file when the manager was added; this guards the JSON shape offline.
	run jq -e '.customManagers | length >= 5' "$RENOVATE_JSON"
	assert_success
}

# =============================================================================
# versions.env grammar
# =============================================================================

@test "versions.env: every non-comment line is a quoted DEFAULT_ assignment" {
	run bash -c "grep -vE '^\s*(#|$)' '$VERSIONS_ENV' | grep -vE '^DEFAULT_[A-Z0-9_]+=\"[^\"]*\"( # \S+)?$'"
	assert_output ""
}

@test "versions.env: sources cleanly with no side effects" {
	# No -u: under kcov the child shell inherits a PS4 that expands
	# ${BASH_SOURCE}, which is unset in `bash -c` (#856).
	run bash -c "set -eo pipefail; source '$VERSIONS_ENV'; declare -p | grep -c '^declare -- DEFAULT_'"
	assert_success
	[[ "$output" -ge 40 ]]
}

@test "versions.env: every version line and every digest line is annotated" {
	# A DEFAULT_*_VERSION / _SHA256_* / _COMMIT line must be preceded by a
	# `# renovate:` line, except the cursor-agent pins (no registry datasource).
	run awk '
		/^# renovate:/ { annotated = 1; next }
		/^DEFAULT_CURSOR_AGENT_/ { annotated = 0; next }
		/^DEFAULT_[A-Z0-9_]+_(VERSION|SHA256|COMMIT)/ {
			if (!annotated) { print "unannotated: " $0; bad = 1 }
			annotated = 0; next
		}
		{ annotated = 0 }
		END { exit bad }' "$VERSIONS_ENV"
	assert_success
	assert_output ""
}

@test "versions.env: digest lines use a digest datasource and carry the release tag" {
	run awk '
		/^# renovate:/ { ds = $0; next }
		/^DEFAULT_[A-Z0-9_]+_SHA256/ {
			if (ds !~ /datasource=github-release-attachments/ && $0 !~ /CURSOR_AGENT/) { print "bad datasource: " $0; bad = 1 }
			if ($0 !~ /" # [^ ]+$/ && $0 !~ /CURSOR_AGENT/) { print "no tag comment: " $0; bad = 1 }
		}
		/^DEFAULT_[A-Z0-9_]+_COMMIT=/ {
			if (ds !~ /datasource=github-tags/) { print "bad datasource: " $0; bad = 1 }
			if ($0 !~ /" # [^ ]+$/) { print "no tag comment: " $0; bad = 1 }
		}
		END { exit bad }' "$VERSIONS_ENV"
	assert_success
	assert_output ""
}

@test "versions.env: every digest-line tag ends with the tool's pinned version" {
	# DEFAULT_<TOOL>_SHA256_<X>="…" # <tag>  must agree with DEFAULT_<TOOL>_VERSION.
	run bash -c '
		set -eo pipefail
		source "$1"
		bad=0
		while IFS= read -r line; do
			var="${line%%=*}"
			tag="${line##* # }"
			tool="${var%_SHA256*}"
			tool="${tool%_COMMIT}"
			vname="${tool}_VERSION"
			version="${!vname:-}"
			if [[ -z "$version" ]]; then echo "no version for $var"; bad=1; continue; fi
			if [[ "$tag" != *"$version" ]]; then echo "$var tag $tag does not end with $version"; bad=1; fi
		done < <(grep -E "^DEFAULT_[A-Z0-9_]+_(SHA256[A-Z0-9_]*|COMMIT)=\"[a-f0-9]+\" # " "$1")
		exit $bad
	' _ "$VERSIONS_ENV"
	assert_success
	assert_output ""
}

@test "versions.env: digests are well-formed hex and no placeholder survives" {
	run bash -c "grep -E '^DEFAULT_[A-Z0-9_]+_SHA256' '$VERSIONS_ENV' | grep -vE '=\"[a-f0-9]{64}\"'"
	assert_output ""
	run bash -c "grep -E '^DEFAULT_[A-Z0-9_]+_COMMIT=' '$VERSIONS_ENV' | grep -vE '=\"[a-f0-9]{40}\"'"
	assert_output ""
	run grep -c '"0000000000000000000000000000000000000000000000000000000000000000"' "$VERSIONS_ENV"
	assert_output "0"
}

# =============================================================================
# Every pin is regex-visible to the versions.env manager
# =============================================================================

@test "tool pins: every versions.env version line is a manager match with its own value" {
	# Expected values come from versions.env itself so a Renovate bump that
	# moves the version and its digest tags together keeps this test green.
	local matches line var value dep
	matches="$(python3 "$MATCHER" scripts/ci/versions.env)"
	while IFS= read -r line; do
		var="${line%%=*}"
		value="$(_pin "$var")"
		dep="$(grep -B1 -F "${var}=" "$VERSIONS_ENV" | sed -n 's/^# renovate: datasource=[a-z-]* depName=\([^ ]*\).*/\1/p')"
		[[ -n "$dep" ]] || {
			echo "no annotation for $var" >&2
			return 1
		}
		grep -qF $'\t'"${dep}"$'\t'"${value}"$'\t' <<<"$matches" || {
			echo "manager did not extract $dep $value from $var" >&2
			return 1
		}
	done < <(grep -E '^DEFAULT_[A-Z0-9_]+_VERSION=' "$VERSIONS_ENV" | grep -v CURSOR_AGENT)
	grep -qF "cargo-nextest-" <<<"$matches"
}

@test "tool pins: every digest line in versions.env is a manager match" {
	local expected matched
	expected="$(grep -cE '^DEFAULT_[A-Z0-9_]+_(SHA256[A-Z0-9_]*|COMMIT)="[a-f0-9]+" # ' "$VERSIONS_ENV")"
	matched="$(python3 "$MATCHER" scripts/ci/versions.env | awk -F'\t' 'NR>1 && $3 ~ /^(v|cargo-nextest-)/ && $1 == "scripts/ci/versions.env"' | wc -l | tr -d ' ')"
	[[ "$expected" -ge 20 ]]
	# Digest matches report the tag (v-prefixed or cargo-nextest-) as currentValue;
	# the version lines for bats helpers and kcov also carry a v, so matched >= expected.
	[[ "$matched" -ge "$expected" ]]
}

@test "tool pins: no installer under scripts/ci carries its own version literal" {
	local f v
	for f in scripts/ci/security/install-osv-scanner.sh \
		scripts/ci/testing/rust/setup-rust-nextest.sh \
		scripts/ci/release/install-cross.sh \
		scripts/ci/release/install-cargo-xwin.sh \
		scripts/ci/actions/setup-rust.sh \
		scripts/ci/actions/prime-syft-tool-cache.sh \
		scripts/ci/actions/install-ai-review-cli.sh \
		scripts/ci/actions/run-bats-tests.sh; do
		while IFS= read -r v; do
			run grep -F "\"$v\"" "${PROJECT_ROOT}/${f}"
			assert_failure
		done < <(sed -n 's/^DEFAULT_[A-Z0-9_]*_VERSION="\([^"]*\)".*/\1/p' "$VERSIONS_ENV")
	done
}

# =============================================================================
# Remaining duplicates equal their source
# =============================================================================

@test "tool pins: npm CLI lockfile manifests equal versions.env" {
	run jq -r '.dependencies["@anthropic-ai/claude-code"]' "${PROJECT_ROOT}/scripts/ci/ai-review-cli/claude/package.json"
	assert_output "$(_pin DEFAULT_CLAUDE_CODE_VERSION)"
	run jq -r '.packages["node_modules/@anthropic-ai/claude-code"].version' "${PROJECT_ROOT}/scripts/ci/ai-review-cli/claude/package-lock.json"
	assert_output "$(_pin DEFAULT_CLAUDE_CODE_VERSION)"
	run jq -r '.dependencies["@openai/codex"]' "${PROJECT_ROOT}/scripts/ci/ai-review-cli/codex/package.json"
	assert_output "$(_pin DEFAULT_CODEX_VERSION)"
	run jq -r '.packages["node_modules/@openai/codex"].version' "${PROJECT_ROOT}/scripts/ci/ai-review-cli/codex/package-lock.json"
	assert_output "$(_pin DEFAULT_CODEX_VERSION)"
}

@test "tool pins: npm CLI lockfiles pin integrity for every package" {
	local f
	for f in claude codex; do
		run jq -r '[.packages | to_entries[] | select(.key != "") | .value.integrity // "MISSING"] | map(select(. == "MISSING")) | length' \
			"${PROJECT_ROOT}/scripts/ci/ai-review-cli/${f}/package-lock.json"
		assert_output "0"
	done
}

# Annotated YAML default for a tool in an action.yml (the source copy).
_yaml_pin() {
	python3 "$MATCHER" "$1" | awk -F'\t' -v dep="$2" 'NR>1 && $2 == dep {print $3; exit}'
}

@test "tool pins: uv and bun action defaults match the YAML manager" {
	local uv bun
	uv="$(_yaml_pin .github/actions/setup-python/action.yml uv)"
	bun="$(_yaml_pin .github/actions/setup-node/action.yml bun)"
	[[ "$uv" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
	[[ "$bun" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "tool pins: every workflow bun copy matches the grouped pin" {
	local wf bun
	bun="$(_yaml_pin .github/actions/setup-node/action.yml bun)"
	[[ -n "$bun" ]]
	for wf in \
		.github/workflows/reusable-test-node.yml \
		.github/workflows/reusable-test-node-custom.yml \
		.github/workflows/reusable-test-e2e.yml \
		.github/workflows/reusable-test-e2e-matrix.yml \
		.github/workflows/reusable-test-e2e-playwright.yml \
		.github/workflows/reusable-deploy-site-with-reports.yml \
		.github/workflows/reusable-site-quality.yml \
		.github/actions/run-vitest/action.yml \
		.github/actions/run-playwright/action.yml \
		.github/actions/run-lighthouse/action.yml; do
		run _yaml_pin "$wf" bun
		assert_success
		assert_output "$bun"
	done
	run grep -R -n "bun-version: latest" "${PROJECT_ROOT}/.github"
	assert_failure
}

@test "tool pins: grype default matches its manager" {
	run python3 "$MATCHER" ".github/actions/scan-vulnerabilities/action.yml"
	assert_success
	assert_output --partial "grype"
}

@test "tool pins: versions.env lists the YAML duplicates it cannot absorb" {
	run grep -E '^#   (uv|bun|grype) ' "$VERSIONS_ENV"
	assert_success
	[[ "$(echo "$output" | wc -l | tr -d ' ')" -eq 3 ]]
}

@test "tool pins: lintro lives in versions.env and the workflow input defaults to empty" {
	run awk '/^      lintro-version:$/{show=1;next} show&&/^      [a-z]/{exit} show{print}' \
		"${PROJECT_ROOT}/.github/workflows/reusable-ai-review.yml"
	assert_success
	assert_output --partial 'default: ""'
	refute_output --partial "# renovate:"
	run grep -F 'DEFAULT_LINTRO_VERSION' "${PROJECT_ROOT}/scripts/ci/actions/run-ai-review.sh"
	assert_success
}

@test "reusable-vuln-suppression-check: osv-version defaults to empty" {
	run awk '/^      osv-version:$/{show=1;next} show&&/^      [a-z]/{exit} show{print}' \
		"${PROJECT_ROOT}/.github/workflows/reusable-vuln-suppression-check.yml"
	assert_success
	assert_output --partial 'default: ""'
}

@test "reusable-test-shell: bats-version defaults to empty" {
	run awk '/^      bats-version:$/{show=1;next} show&&/^      [a-z]/{exit} show{print}' \
		"${PROJECT_ROOT}/.github/workflows/reusable-test-shell.yml"
	assert_success
	assert_output --partial 'default: ""'
}

# Run the real install-bats step with a recording git stub that fails the
# first clone, so the step stops before installing anything. The recorded
# clone shows which bats-core tag the step resolved.
_install_bats_clone_args() {
	mock_command_record "git" "" 1
	run env STEP=install-bats BATS_VERSION="$1" BATS_INSTALL_NO_SUDO=1 \
		BATS_INSTALL_SRC="$BATS_TEST_TMPDIR/src" \
		bash "${PROJECT_ROOT}/scripts/ci/actions/run-bats-tests.sh"
	assert_failure
	run head -n 1 "$BATS_TEST_TMPDIR/mock_calls_git"
}

@test "run-bats-tests: empty BATS_VERSION clones the versions.env bats-core tag" {
	local pin
	pin="$(_pin DEFAULT_BATS_CORE_VERSION)"
	[[ -n "$pin" ]]
	_install_bats_clone_args ""
	assert_output "clone --depth 1 --branch v${pin} https://github.com/bats-core/bats-core.git ${BATS_TEST_TMPDIR}/src/bats-core"
}

@test "run-bats-tests: a v-prefixed BATS_VERSION override clones a single-v tag" {
	_install_bats_clone_args "v9.8.7"
	assert_output "clone --depth 1 --branch v9.8.7 https://github.com/bats-core/bats-core.git ${BATS_TEST_TMPDIR}/src/bats-core"
}
