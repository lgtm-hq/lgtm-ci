#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for reusable-build-rust-binaries workflow

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-build-rust-binaries.yml"

@test "reusable-build-rust-binaries: declares strict tier via validate-runner-policy" {
	run grep -F 'tier: strict' "$WORKFLOW"
	assert_success
	run grep -F 'validate-runner-policy' "$WORKFLOW"
	assert_success
}

@test "reusable-build-rust-binaries: egress-preset defaults to rust-release" {
	run awk '/^      egress-preset:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: "rust-release"'
}

@test "reusable-build-rust-binaries: timeout-minutes defaults to 45" {
	run awk '/^      timeout-minutes:$/{show=1;next} show&&/^      [a-z]/ {exit} show{print}' \
		"$WORKFLOW"
	assert_success
	assert_output --partial 'default: 45'
}

@test "reusable-build-rust-binaries: harden-first with runner-context gate; policy still present" {
	# Harden must be first (pre/main before checkout). Gate with runner context
	# instead of steps.policy outputs (those do not exist at step 1).
	run awk '
		/- name: Harden runner/ { harden = NR; next }
		harden && !gated && /^[[:space:]]+if: runner\.os == .Linux. \|\| runner\.environment == .self-hosted./ { gated = 1 }
		harden && /^[[:space:]]+- name:/ { harden = 0 }
		/- name: Validate runner policy/ { policy = 1 }
		END { exit !(gated && policy) }
	' "$WORKFLOW"
	assert_success
	run egress_tooling_checkout_order_ok "$WORKFLOW"
	assert_success
}

@test "reusable-build-rust-binaries: uploads artifact with target suffix" {
	run grep -F '${{ matrix.target }}' "$WORKFLOW"
	assert_success
	run grep -F 'SHA256SUMS-${{ matrix.target }}' "$WORKFLOW"
	assert_success
}

@test "reusable-build-rust-binaries: workflow-level concurrency is namespaced by callee and caller workflow" {
	# `github` in a called workflow is the caller's, so the group carries a
	# stable callee prefix plus the caller repository and workflow (#1076).
	run bash -c "awk '/^concurrency:\$/,/^jobs:/ { print }' '$WORKFLOW' | tr -d '\n' | tr -s ' '"
	assert_success
	assert_output --partial 'lgtm-ci-rust-binaries-${{ github.repository }}-${{ github.workflow }}-${{ github.ref }}-'
	assert_output --partial "\${{ inputs.concurrency-scope || 'default' }}"
	assert_output --partial 'cancel-in-progress: false'
	refute_output --partial 'github.job'
}

@test "reusable-build-rust-binaries: attests release archives not checksum manifests" {
	run awk '/subject-path:/{show=1;next} show&&/^        [a-z]/{exit} show{print}' "$WORKFLOW"
	assert_success
	assert_output --partial '*.tar.gz'
	assert_output --partial '*.zip'
	refute_output --partial 'SHA256SUMS'
}

@test "reusable-build-rust-binaries: installs cross via the annotated script" {
	run grep -F "scripts/ci/release/install-cross.sh" "$WORKFLOW"
	assert_success
	run grep -F "cargo install cross --locked --version 0.2.5" "$WORKFLOW"
	assert_failure
}

# The default matrix literal, one entry per line.
_default_matrix() {
	awk '/^              .\[$/{show=1;next} show&&/^              \]/{exit} show{print}' "$WORKFLOW" | tr -d ' '
}

@test "reusable-build-rust-binaries: every default matrix entry names a builder" {
	local matrix
	matrix="$(_default_matrix)"
	[[ "$(echo "$matrix" | wc -l | tr -d ' ')" -eq 3 ]]
	run bash -c "echo '$matrix' | grep -v '\"builder\":\"'"
	assert_output ""
	run echo "$matrix"
	refute_output --partial '"cross":'
}

@test "reusable-build-rust-binaries: default matrix never pairs cross with an MSVC target" {
	run _default_matrix
	assert_success
	refute_output --regexp 'windows-msvc[^}]*"builder":"cross"'
	refute_output --regexp '"builder":"cross"[^}]*windows-msvc'
	assert_output --partial '{"target":"x86_64-unknown-linux-musl","builder":"native","archive":"tar.gz"}'
	assert_output --partial '{"target":"aarch64-unknown-linux-gnu","builder":"cross","archive":"tar.gz"}'
	assert_output --partial '{"target":"x86_64-pc-windows-msvc","builder":"xwin","archive":"zip"}'
	refute_output --partial 'windows-gnu'
}

@test "reusable-build-rust-binaries: builder reaches the build script and gates the installers" {
	run awk '/- name: Build release binaries/{show=1;next} show&&/- name:/{exit} show{print}' "$WORKFLOW"
	assert_output --partial 'BUILDER: ${{ matrix.builder }}'
	run awk '/- name: Install cross/{show=1;next} show&&/- name:/{exit} show{print}' "$WORKFLOW"
	assert_output --partial "if: matrix.builder == 'cross' || (!matrix.builder && (matrix.cross == true || matrix.cross == 'true'))"
	run awk '/- name: Install cargo-xwin/{show=1;next} show&&/- name:/{exit} show{print}' "$WORKFLOW"
	assert_output --partial "if: matrix.builder == 'xwin'"
	assert_output --partial 'scripts/ci/release/install-cargo-xwin.sh'
	run awk '/- name: Cache the xwin Windows SDK and CRT/{show=1;next} show&&/- name:/{exit} show{print}' "$WORKFLOW"
	assert_output --partial "if: matrix.builder == 'xwin'"
	assert_output --partial '~/.cache/cargo-xwin'
	# Keyed on the cargo-xwin pin the installer reports, not on all of versions.env.
	assert_output --partial 'key: cargo-xwin-${{ runner.os }}-${{ matrix.target }}-${{ steps.xwin.outputs.version }}'
	refute_output --partial 'hashFiles'
	run awk '/- name: Install cargo-xwin/{show=1;next} show&&/- name:/{exit} show{print}' "$WORKFLOW"
	assert_output --partial 'id: xwin'
}

EVAL="${PROJECT_ROOT}/tests/helpers/gha_expr.py"

# The Install cross `if:` and the USE_CROSS value, as written in the workflow.
_cross_gate() {
	awk '/- name: Install cross/{show=1;next} show&&/- name:/{exit} show&&/^        if: /{sub(/^        if: /,""); print; exit}' "$WORKFLOW"
}
_use_cross() {
	grep -E '^          USE_CROSS: ' "$WORKFLOW" | sed -E 's/^ *USE_CROSS: \$\{\{ (.*) \}\}$/\1/'
}

@test "reusable-build-rust-binaries: cross gate and USE_CROSS agree with the build script for every key shape" {
	local gate use
	gate="$(_cross_gate)"
	use="$(_use_cross)"
	[[ -n "$gate" && "$gate" == "$use" ]]
	# builder wins; the legacy key as boolean or string selects cross; native
	# and plain xwin entries never install cross.
	run python3 "$EVAL" --value "$gate" "matrix.builder=cross"
	assert_output "true"
	run python3 "$EVAL" --value "$gate" "matrix.cross:=true"
	assert_output "true"
	run python3 "$EVAL" --value "$gate" "matrix.cross=true"
	assert_output "true"
	run python3 "$EVAL" --value "$gate" "matrix.builder=native" "matrix.cross:=true"
	assert_output "false"
	run python3 "$EVAL" --value "$gate" "matrix.builder=xwin"
	assert_output "false"
	run python3 "$EVAL" --value "$gate" "matrix.cross:=false"
	assert_output "false"
	run python3 "$EVAL" --value "$gate"
	assert_output "false"
}

@test "reusable-build-rust-binaries: xwin legs get llvm-tools from setup-rust" {
	run awk '/- name: Setup Rust/{show=1;next} show&&/- name:/{exit} show{print}' "$WORKFLOW"
	assert_output --partial 'components: ${{ matrix.builder == '"'"'xwin'"'"' && '"'"'llvm-tools'"'"' || '"'"''"'"' }}'
}
