#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/install-ai-review-cli.sh gating

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/install-ai-review-cli.sh"

@test "install-ai-review-cli: skips when transport is api" {
	run env PROVIDER=anthropic TRANSPORT=api bash "$SCRIPT"
	assert_success
	assert_output --partial "no CLI binary"
}

@test "install-ai-review-cli: skips when provider is unset" {
	run env PROVIDER="" TRANSPORT="cli" bash "$SCRIPT"
	assert_success
	assert_output --partial "no CLI binary"
}

@test "install-ai-review-cli: rejects non-semver claude pin" {
	run env PROVIDER=anthropic TRANSPORT=cli CLAUDE_CODE_VERSION=latest bash "$SCRIPT"
	assert_failure
	assert_output --partial "exact X.Y.Z"
}

@test "install-ai-review-cli: rejects non-semver codex pin" {
	run env PROVIDER=openai TRANSPORT=cli CODEX_VERSION='^0.1.0' bash "$SCRIPT"
	assert_failure
	assert_output --partial "exact X.Y.Z"
}

@test "install-ai-review-cli: Cursor download uses download_with_retries" {
	run grep -F "download_with_retries" "$SCRIPT"
	assert_success
	run grep -F "lib/network/download.sh" "$SCRIPT"
	assert_success
}

@test "install-ai-review-cli: Cursor pin includes long-headless-session fix" {
	# Cursor 2026.08.11 fixed wedged uploads silently stalling long headless
	# sessions; older pins reproduce the AI review hang under larger PRs.
	local env="${PROJECT_ROOT}/scripts/ci/versions.env"
	run grep -F 'DEFAULT_CURSOR_AGENT_VERSION="2026.08.11-e8db854"' "$env"
	assert_success
	run grep -F 'DEFAULT_CURSOR_AGENT_SHA256_X64="bfff4bf6f4e9dd30c1d0ef0a70b6077b074015dd2948e4c50685d53afdcfce5a"' "$env"
	assert_success
	run grep -F 'DEFAULT_CURSOR_AGENT_SHA256_ARM64="ea13f92e295f523a99ce8d8f57d6894d21e5d1e2d030ffad718ccd5955ca2eed"' "$env"
	assert_success
	run grep -F 'CURSOR_AGENT_SHA256_X64="${CURSOR_AGENT_SHA256_X64:-$DEFAULT_CURSOR_AGENT_SHA256_X64}"' "$SCRIPT"
	assert_success
}

@test "install-ai-review-cli: npm CLIs install from the committed lockfile" {
	local calls="${BATS_TEST_TMPDIR}/npm_calls" mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	: >"$calls"
	# npm records its argv and cwd; claude is the binary the lockfile would provide.
	cat >"${mock_bin}/npm" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$(pwd)" "\$*" >>'${calls}'
mkdir -p node_modules/.bin
printf '#!/usr/bin/env bash\necho claude-mock\n' >node_modules/.bin/claude
chmod +x node_modules/.bin/claude
EOF
	chmod +x "${mock_bin}/npm"
	run env PATH="${mock_bin}:${PATH}" PROVIDER=anthropic TRANSPORT=cli \
		AI_TOOLS_PREFIX="${BATS_TEST_TMPDIR}/ai-tools" GITHUB_PATH="${BATS_TEST_TMPDIR}/gh_path" \
		bash "$SCRIPT"
	assert_success
	assert_output --partial "from the committed lockfile"
	assert_output --partial "claude-mock"
	run cat "$calls"
	assert_output --partial "${BATS_TEST_TMPDIR}/ai-tools/claude|ci --no-fund --no-audit"
	[[ -f "${BATS_TEST_TMPDIR}/ai-tools/claude/package-lock.json" ]]
	run cat "${BATS_TEST_TMPDIR}/gh_path"
	assert_output --partial "/ai-tools/claude/node_modules/.bin"
}

@test "install-ai-review-cli: npm version outside the lockfile is refused" {
	run env PROVIDER=openai TRANSPORT=cli CODEX_VERSION=0.1.0 bash "$SCRIPT"
	assert_failure
	assert_output --partial "@openai/codex@0.1.0 requested but the committed lockfile pins"
	assert_output --partial "LGTM_CI_ALLOW_UNVERIFIED=1"
}

@test "install-ai-review-cli: npm version outside the lockfile installs under the escape hatch" {
	local calls="${BATS_TEST_TMPDIR}/npm_calls" mock_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$mock_bin"
	: >"$calls"
	cat >"${mock_bin}/npm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>'${calls}'
EOF
	chmod +x "${mock_bin}/npm"
	printf '#!/usr/bin/env bash\necho codex-mock\n' >"${mock_bin}/codex"
	chmod +x "${mock_bin}/codex"
	run env PATH="${mock_bin}:${PATH}" PROVIDER=openai TRANSPORT=cli CODEX_VERSION=0.1.0 \
		LGTM_CI_ALLOW_UNVERIFIED=1 bash "$SCRIPT"
	assert_success
	assert_output --partial "::warning title=unverified install::"
	run cat "$calls"
	assert_output --partial "install -g --no-fund --no-audit @openai/codex@0.1.0"
}

@test "install-ai-review-cli: EXIT trap is safe under set -u outside function scope" {
	# Regression (#889 pilot run): the EXIT trap fires at script exit, where a
	# function-local tmp is out of scope — set -u then kills the trap and the
	# step. tmp must not be declared local, and the trap must default-expand.
	run grep -F 'trap '\''rm -rf "${tmp:-}"'\'' EXIT' "$SCRIPT"
	assert_success
	# Match every local declaration form: bare (`local tmp`), listed
	# (`local a tmp b`), and assignment (`local tmp=...`).
	run bash -c "grep -E '\blocal\b[^#]*\btmp\b' '$SCRIPT'"
	assert_failure
}
