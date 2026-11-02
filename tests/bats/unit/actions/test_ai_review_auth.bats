#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Real wrapper/runner invocation with offline fake provider binaries.

load "../../../helpers/common"

AUTH_SOURCE="${PROJECT_ROOT}/scripts/ci/actions/ai_review_auth.py"

setup() {
    setup_temp_dir
    [[ "$(uname -s)" == Linux ]] || skip "Codex fixture requires Linux"
    local target triple
    case "$(uname -m)" in
        x86_64) target=linux-x64; triple=x86_64-unknown-linux-musl ;;
        aarch64) target=linux-arm64; triple=aarch64-unknown-linux-musl ;;
        *) skip "Unsupported Codex fixture architecture" ;;
    esac
    # Test-only import seam: keep all roots under owned scratch, not /var/tmp.
    export TEST_EXECUTION_BASE="${BATS_TEST_TMPDIR}/external" AUTH_SOURCE
    mkdir -p "$TEST_EXECUTION_BASE"
    SCRIPT="${BATS_TEST_TMPDIR}/auth-driver.py"
    cat >"$SCRIPT" <<'DRIVER'
import importlib.util
import os
import sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('auth', os.environ['AUTH_SOURCE'])
auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auth)
auth.external_base = lambda: Path(os.environ['TEST_EXECUTION_BASE'])
auth.EXECUTION_BASE = Path(os.environ['TEST_EXECUTION_BASE'])
try:
    sys.exit(auth.main())
except (ValueError, OSError, KeyError) as error:
    print('Review auth refused: ' + str(error), file=sys.stderr)
    sys.exit(1)
DRIVER
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "$HOME/.codex" "${BATS_TEST_TMPDIR}/venv/bin" "${BATS_TEST_TMPDIR}/tools/bin" "${BATS_TEST_TMPDIR}/tools/codex/node_modules/.bin" "${BATS_TEST_TMPDIR}/tools/claude/node_modules/.bin"
    printf 'ambient-session' >"$HOME/.codex/auth.json"
    HOME="$(cd "$HOME" && pwd -P)"
    export GITHUB_RUN_ID=1196 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=review
    export GITHUB_REPOSITORY=x/y PR_NUMBER=1 GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/workspace"
    mkdir -p "$GITHUB_WORKSPACE"
    export VENV_DIR="${BATS_TEST_TMPDIR}/venv" AI_TOOLS_PREFIX="${BATS_TEST_TMPDIR}/tools"
    export REVIEW_NODE_BIN="$(command -v node)"
    export LINTRO_AI_PROVIDER=openai LINTRO_AI_TRANSPORT=cli AI_REVIEW_AUTH=oauth LINTRO_CLI_BARE=""
    export CODEX_AUTH_JSON
    CODEX_AUTH_JSON="$(printf '%s' '{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token":"fixture-id","access_token":"fixture-access","refresh_token":"fixture-refresh","account_id":"fixture-account"}}' | base64 | tr -d '\n')"
    unset CODEX_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN CURSOR_API_KEY ANTHROPIC_AUTH_TOKEN
    cat >"$VENV_DIR/bin/lintro" <<'FAKE'
#!/bin/bash
set -eu
[[ -z "${CODEX_AUTH_JSON+x}" ]]
[[ -z "${BASH_ENV+x}${PYTHONPATH+x}${OPENAI_BASE_URL+x}" ]]
[[ "$HOME" == *'.lgtm-ci-review-'* ]]
[[ "$(cat .lintro-config.yaml)" == '{}' ]]
case "$LINTRO_AI_PROVIDER/$LINTRO_AI_TRANSPORT" in
    openai/cli) [[ "$(command -v codex)" == "$HOME/bin/codex" ]] ;;
    anthropic/cli) [[ "$(command -v claude)" == "$HOME/bin/claude" ]] ;;
    cursor/cli) [[ "$(command -v agent)" == "$HOME/bin/agent" ]] ;;
esac
credential_count=0
for credential in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY CODEX_API_KEY CURSOR_API_KEY; do
    if printenv "$credential" >/dev/null; then credential_count=$((credential_count + 1)); fi
done
if [[ -f "$CODEX_HOME/auth.json" ]]; then credential_count=$((credential_count + 1)); fi
[[ "$credential_count" -eq 1 ]]
if [[ "$LINTRO_AI_PROVIDER/$LINTRO_AI_TRANSPORT" == anthropic/cli ]]; then
    if printenv ANTHROPIC_API_KEY >/dev/null; then
        [[ "$LINTRO_CLI_BARE" == always ]]
    else
        [[ "$LINTRO_CLI_BARE" == never ]]
    fi
fi
if [[ "$LINTRO_AI_PROVIDER/$LINTRO_AI_TRANSPORT" == openai/cli && -f "$CODEX_HOME/auth.json" ]]; then
    [[ -z "${CODEX_API_KEY+x}" ]]
    python3 -I -c 'import os, stat; assert stat.S_IMODE(os.stat(os.environ["CODEX_HOME"]+"/auth.json").st_mode) == 0o600'
fi
printf '{"verdict":"approve","coverage":{"complete":true}}\n'
FAKE
    chmod +x "$VENV_DIR/bin/lintro"
    touch "$AI_TOOLS_PREFIX/bin/agent" "$AI_TOOLS_PREFIX/codex/node_modules/.bin/codex" "$AI_TOOLS_PREFIX/claude/node_modules/.bin/claude"
    chmod +x "$AI_TOOLS_PREFIX/bin/agent" "$AI_TOOLS_PREFIX/codex/node_modules/.bin/codex" "$AI_TOOLS_PREFIX/claude/node_modules/.bin/claude"
    LEGACY_TOOLS_PREFIX="$AI_TOOLS_PREFIX"
    local package="$AI_TOOLS_PREFIX/codex/node_modules/@openai/codex"
    local platform="$AI_TOOLS_PREFIX/codex/node_modules/@openai/codex-$target"
    local native="$platform/vendor/$triple"
    mkdir -p "$package/bin" "$native/bin" "$native/codex-resources"
    local version
    version="$(python3 -I -c 'import json,os; from pathlib import Path; p=Path(os.environ["AUTH_SOURCE"]).parent.parent/"ai-review-cli/codex/package.json"; print(json.loads(p.read_text())["dependencies"]["@openai/codex"])')"
    printf '{"name":"@openai/codex","version":"%s","bin":{"codex":"bin/codex.js"}}' "$version" >"$package/package.json"
    printf '{"name":"@openai/codex","version":"%s-%s"}' "$version" "$target" >"$platform/package.json"
    printf '{"version":"%s","target":"%s","entrypoint":"bin/codex","resourcesDir":"codex-resources"}' "$version" "$triple" >"$native/codex-package.json"
    touch "$native/bin/codex" "$native/codex-resources/bwrap"
    mv "$AI_TOOLS_PREFIX/codex/node_modules/.bin/codex" "$package/bin/codex.js"
    ln -s ../@openai/codex/bin/codex.js "$AI_TOOLS_PREFIX/codex/node_modules/.bin/codex"
    export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
    prepare_codex
    cd "$GITHUB_WORKSPACE" || return 1
}

teardown() { teardown_temp_dir; }

prepare_codex() {
    python3 -I "$SCRIPT" --prepare-execution || return 1
    EXECUTION_ROOT="$TEST_EXECUTION_BASE/.lgtm-ci-review-exec-$(id -u)-1196-1-review"
    export AI_TOOLS_PREFIX="$EXECUTION_ROOT/ai-tools"
    cp -R "$LEGACY_TOOLS_PREFIX" "$AI_TOOLS_PREFIX"
    # Model the workflow's private Codex installation umask.
    chmod -R go-w "$AI_TOOLS_PREFIX"
}

@test "review auth: OAuth session is isolated, key absent, PR settings ignored and cleaned" {
    printf 'ai: {providers: {anthropic: {cli_bare: always}}}\n' >.lintro-config.yaml
    printf 'CODEX_API_KEY=smoke\n' >.env
    OPENAI_BASE_URL=https://hostile.invalid PYTHONPATH="$GITHUB_WORKSPACE" run python3 -I "$SCRIPT"
    assert_success
    assert_output --partial 'outcome=reviewed'
    [[ ! -e "$HOME/.lgtm-ci-review-1196-1-review" ]]
    [[ ! -e "$EXECUTION_ROOT" ]]
    [[ "$(cat "$HOME/.codex/auth.json")" == ambient-session ]]
}

@test "review auth: even an empty CODEX_API_KEY under OAuth is refused" {
    CODEX_API_KEY='' run python3 -I "$SCRIPT"
    assert_failure
    assert_output --partial 'CODEX_API_KEY must be absent'
    [[ ! -e "$HOME/.lgtm-ci-review-1196-1-review" ]]
}

@test "review auth: all tuple credentials bind without ambient session fallback" {
    for tuple in 'anthropic api api_key ANTHROPIC_API_KEY none' 'anthropic cli oauth CLAUDE_CODE_OAUTH_TOKEN never' 'anthropic cli api_key ANTHROPIC_API_KEY always' 'openai api api_key OPENAI_API_KEY none' 'openai cli api_key CODEX_API_KEY none' 'cursor cli api_key CURSOR_API_KEY none'; do
        read -r provider transport auth credential bare <<<"$tuple"
        [[ "$bare" != none ]] || bare=''
        local prefix="$LEGACY_TOOLS_PREFIX"
        [[ "$provider/$transport" != openai/cli ]] || prefix="$AI_TOOLS_PREFIX"
        env -u CODEX_AUTH_JSON AI_TOOLS_PREFIX="$prefix" LINTRO_AI_PROVIDER="$provider" LINTRO_AI_TRANSPORT="$transport" AI_REVIEW_AUTH="$auth" LINTRO_CLI_BARE="$bare" "$credential=fixture-review-key" python3 -I "$SCRIPT" >"$BATS_TEST_TMPDIR/result" 2>&1 || { cat "$BATS_TEST_TMPDIR/result"; return 1; }
        [[ ! -e "$HOME/.lgtm-ci-review-1196-1-review" ]]
    done
}

@test "review auth: missing whitespace and competing credentials are red with no fallback" {
    for value in '' ' '; do
        CODEX_AUTH_JSON="$value" run python3 -I "$SCRIPT"
        assert_failure
        assert_output --partial 'Missing review credential CODEX_AUTH_JSON'
    done
    ANTHROPIC_API_KEY=smoke run python3 -I "$SCRIPT"
    assert_failure
    assert_output --partial 'Competing credential ANTHROPIC_API_KEY'
}

@test "review auth: malformed, non-session and embedded-key snapshots are refused without leakage" {
	local utf16
	utf16="$(python3 -I -c 'import base64, os; raw=base64.b64decode(os.environ["CODEX_AUTH_JSON"]); print(base64.b64encode(raw.decode().encode("utf-16")).decode())')"
	for payload in invalid-base64 e30= W10= "$utf16"; do
	    [[ -d "$EXECUTION_ROOT" ]] || prepare_codex
	    CODEX_AUTH_JSON="$payload" run python3 -I "$SCRIPT"
        assert_failure
        assert_output --partial 'CODEX_AUTH_JSON'
    done
    prepare_codex
    CODEX_AUTH_JSON="$(printf '%s' '{"OPENAI_API_KEY":"fixture-secret-do-not-log"}' | base64 | tr -d '\n')" run python3 -I "$SCRIPT"
    assert_failure
    assert_output --partial 'not an API-key login'
    refute_output --partial 'fixture-secret-do-not-log'
}

@test "review auth: symlink and pre-existing isolated homes are never overwritten or deleted" {
    ln -s "$HOME/.codex" "$HOME/.lgtm-ci-review-1196-1-review"
    run python3 -I "$SCRIPT"
    assert_failure
    run python3 -I "$SCRIPT" --cleanup
    assert_failure
    [[ "$(cat "$HOME/.codex/auth.json")" == ambient-session ]]
    rm "$HOME/.lgtm-ci-review-1196-1-review"
    mkdir "$HOME/.lgtm-ci-review-1196-1-review"
    run python3 -I "$SCRIPT"
    assert_failure
    [[ -d "$HOME/.lgtm-ci-review-1196-1-review" ]]
}

@test "review auth: conflicting effective bare policy fails before invocation" {
    run env -u CODEX_AUTH_JSON LINTRO_AI_PROVIDER=anthropic AI_REVIEW_AUTH=oauth LINTRO_CLI_BARE=always CLAUDE_CODE_OAUTH_TOKEN=fixture python3 -I "$SCRIPT"
    assert_failure
    assert_output --partial 'LINTRO_CLI_BARE conflicts'
}

@test "review auth: selected Anthropic auth overrides conflicting repository bare settings" {
    printf 'ai: {providers: {anthropic: {cli_bare: always}}}\n' >.lintro-config.yaml
    run env -u CODEX_AUTH_JSON LINTRO_AI_PROVIDER=anthropic AI_REVIEW_AUTH=oauth LINTRO_CLI_BARE=never CLAUDE_CODE_OAUTH_TOKEN=fixture python3 -I "$SCRIPT"
    assert_success
    printf 'ai: {providers: {anthropic: {cli_bare: never}}}\n' >.lintro-config.yaml
    run env -u CODEX_AUTH_JSON LINTRO_AI_PROVIDER=anthropic AI_REVIEW_AUTH=api_key LINTRO_CLI_BARE=always ANTHROPIC_API_KEY=fixture python3 -I "$SCRIPT"
    assert_success
}

@test "review auth: ordinary provider failure still removes the session" {
    printf '#!/bin/bash\nexit 2\n' >"$VENV_DIR/bin/lintro"
    BLOCKING=true run python3 -I "$SCRIPT"
    assert_failure
    [[ ! -e "$HOME/.lgtm-ci-review-1196-1-review" ]]
    [[ ! -e "$EXECUTION_ROOT" ]]
}

@test "review auth: always cleanup is idempotent after a completed attempt" {
    run python3 -I "$SCRIPT" --cleanup
    assert_success
    prepare_codex
    run python3 -I "$SCRIPT"
    assert_success
    run python3 -I "$SCRIPT" --cleanup
    assert_success
}

@test "review auth: TERM and INT reap descendants and remove both roots" {
    cat >"$VENV_DIR/bin/lintro" <<'FAKE'
#!/bin/bash
printf '%s' "$$" > running
sleep 90 &
printf '%s' "$!" > descendant
wait
FAKE
    local sig wrapper child descendant code expected
    for sig in TERM INT; do
        [[ -d "$EXECUTION_ROOT" ]] || prepare_codex
        python3 -I "$SCRIPT" >"$BATS_TEST_TMPDIR/cancel.log" 2>&1 &
        wrapper=$!
        code=0
        for _ in {1..60}; do
            [[ ! -f "$EXECUTION_ROOT/work/descendant" ]] || break
            sleep 0.1
        done
        child="$(cat "$EXECUTION_ROOT/work/running")"
        descendant="$(cat "$EXECUTION_ROOT/work/descendant")"
        kill -"$sig" "$wrapper"
        wait "$wrapper" || code=$?
        expected=143
        [[ "$sig" != INT ]] || expected=130
        [[ "$code" -eq "$expected" ]]
        [[ ! -e "$HOME/.lgtm-ci-review-1196-1-review" && ! -e "$EXECUTION_ROOT" ]]
        ! kill -0 "$child" 2>/dev/null
        # A dead orphan may remain a zombie until the host's init reaps it.
        ! kill -0 "$descendant" 2>/dev/null || [[ "$(ps -o stat= -p "$descendant")" == Z* ]]
        [[ "$(cat "$HOME/.codex/auth.json")" == ambient-session ]]
    done
}

@test "review auth: bounded timeout removes the session and redacts decoded tokens" {
    local real_timeout
    real_timeout="$(command -v timeout)"
    cat >"$AI_TOOLS_PREFIX/codex/node_modules/.bin/timeout" <<FAKE
#!/bin/bash
shift 4
exec '$real_timeout' --foreground -v --kill-after=1 1 "\$@"
FAKE
    chmod 700 "$AI_TOOLS_PREFIX/codex/node_modules/.bin/timeout"
    cat >"$VENV_DIR/bin/lintro" <<'FAKE'
#!/bin/bash
echo fixture-access
sleep 90
FAKE
    run python3 -I "$SCRIPT"
    assert_success
    assert_output --partial 'outcome=timed-out'
    assert_output --partial '[REDACTED]'
    refute_output --partial 'fixture-access'
    [[ ! -e "$HOME/.lgtm-ci-review-1196-1-review" ]]
    [[ ! -e "$EXECUTION_ROOT" ]]
}

@test "review auth: invalid UTF-8 child diagnostics preserve the review outcome" {
    cat >"$VENV_DIR/bin/lintro" <<'FAKE'
#!/bin/bash
printf '\377' >&2
printf '{"verdict":"approve","coverage":{"complete":true}}\n'
FAKE
    run python3 -I "$SCRIPT"
    assert_success
    assert_output --partial 'outcome=reviewed'
    refute_output --partial 'Review auth refused'
    [[ ! -e "$HOME/.lgtm-ci-review-1196-1-review" ]]
}

@test "review auth: sensitive runner logs and temp stay private and are redacted" {
    cat >"$VENV_DIR/bin/lintro" <<'FAKE'
#!/bin/bash
set -eu
[[ "$TMPDIR" == "$HOME/tmp" && "$LINTRO_LOG_DIR" == "$HOME/logs" ]]
[[ "$PWD" != "$HOME"/* && ! -e .lintro ]]
file="$(mktemp)"
printf fixture-access >"$file"
printf fixture-access >"$LINTRO_LOG_DIR/provider.log"
[[ "$file" == "$HOME/tmp/"* ]]
# The real shell runner has already allocated all three temporary files here.
[[ "$(find "$TMPDIR" -maxdepth 1 -type f | wc -l)" -ge 4 ]]
echo fixture-access
printf '{"verdict":"approve","coverage":{"complete":true}}\n'
FAKE
    run python3 -I "$SCRIPT"
    assert_success
    assert_output --partial 'outcome=reviewed'
    assert_output --partial '[REDACTED]'
    refute_output --partial fixture-access
    [[ ! -e "$EXECUTION_ROOT" && ! -e "$HOME/.lgtm-ci-review-1196-1-review" ]]
    [[ "$(cat "$HOME/.codex/auth.json")" == ambient-session ]]
}

@test "review auth: always cleanup removes install-only root without tuple or secrets" {
    run env -u CODEX_AUTH_JSON -u LINTRO_AI_PROVIDER -u LINTRO_AI_TRANSPORT -u AI_REVIEW_AUTH -u AI_TOOLS_PREFIX -u GITHUB_WORKSPACE python3 -I "$SCRIPT" --cleanup
    assert_success
    [[ ! -e "$EXECUTION_ROOT" ]]
    [[ "$(cat "$HOME/.codex/auth.json")" == ambient-session ]]
}

@test "review auth: cleanup refusal of one root still cleans the other" {
    mkdir -m 700 "$HOME/.lgtm-ci-review-1196-1-review"
    run python3 -I "$SCRIPT" --cleanup
    assert_failure
    [[ ! -e "$EXECUTION_ROOT" ]]
    [[ -d "$HOME/.lgtm-ci-review-1196-1-review" ]]
    rmdir "$HOME/.lgtm-ci-review-1196-1-review"
    prepare_codex
    printf foreign >"$EXECUTION_ROOT/.lgtm-ci-owned"
    mkdir -m 700 "$HOME/.lgtm-ci-review-1196-1-review"
    printf .lgtm-ci-review-1196-1-review >"$HOME/.lgtm-ci-review-1196-1-review/.lgtm-ci-owned"
    chmod 600 "$HOME/.lgtm-ci-review-1196-1-review/.lgtm-ci-owned"
    run python3 -I "$SCRIPT" --cleanup
    assert_failure
    [[ -e "$EXECUTION_ROOT" ]]
    [[ ! -e "$HOME/.lgtm-ci-review-1196-1-review" ]]
}
