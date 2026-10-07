#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/maintenance/refresh-tool-digests.sh (#1096):
#          --check / --write against a temp versions file, with curl,
#          slsa-verifier, cosign and git stubbed on PATH.

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/maintenance/refresh-tool-digests.sh"

setup() {
	setup_temp_dir
	MOCK_BIN="${BATS_TEST_TMPDIR}/bin"
	SERVER_DIR="${BATS_TEST_TMPDIR}/server"
	CALLS="${BATS_TEST_TMPDIR}/calls"
	mkdir -p "$MOCK_BIN" "$SERVER_DIR"
	: >"$CALLS"
	export MOCK_BIN SERVER_DIR CALLS

	# A versions file with one download tool (osv-scanner) and one clone tool
	# (bats-core); the real file's grammar, placeholder digests.
	VERSIONS_FILE="${BATS_TEST_TMPDIR}/versions.env"
	cat >"$VERSIONS_FILE" <<'EOF'
# renovate: datasource=github-releases depName=google/osv-scanner
DEFAULT_OSV_SCANNER_VERSION="2.3.5"
# renovate: datasource=github-release-attachments depName=google/osv-scanner
DEFAULT_OSV_SCANNER_SHA256_LINUX_AMD64="0000000000000000000000000000000000000000000000000000000000000000" # v2.3.5
# renovate: datasource=github-release-attachments depName=google/osv-scanner
DEFAULT_OSV_SCANNER_SHA256_LINUX_ARM64="0000000000000000000000000000000000000000000000000000000000000000" # v2.3.5
# renovate: datasource=github-releases depName=bats-core/bats-core
DEFAULT_BATS_CORE_VERSION="1.10.0"
# renovate: datasource=github-tags depName=bats-core/bats-core
DEFAULT_BATS_CORE_COMMIT="1111111111111111111111111111111111111111" # v1.10.0
EOF
	export VERSIONS_FILE

	# Fake release: two binaries, a matching SHA256SUMS, and a provenance file.
	printf 'amd64 bytes\n' >"${SERVER_DIR}/osv-scanner_linux_amd64"
	printf 'arm64 bytes\n' >"${SERVER_DIR}/osv-scanner_linux_arm64"
	AMD64_SHA="$(_sha256_of "${SERVER_DIR}/osv-scanner_linux_amd64")"
	ARM64_SHA="$(_sha256_of "${SERVER_DIR}/osv-scanner_linux_arm64")"
	export AMD64_SHA ARM64_SHA
	printf '%s  osv-scanner_linux_amd64\n%s  osv-scanner_linux_arm64\n' "$AMD64_SHA" "$ARM64_SHA" \
		>"${SERVER_DIR}/osv-scanner_SHA256SUMS"
	printf '{}\n' >"${SERVER_DIR}/multiple.intoto.jsonl"

	# curl serves files by basename and records URLs.
	cat >"${MOCK_BIN}/curl" <<EOF
#!/usr/bin/env bash
url=""; out=""
while [[ \$# -gt 0 ]]; do
	case "\$1" in
	-o) out="\$2"; shift 2;;
	http*) url="\$1"; shift;;
	*) shift;;
	esac
done
printf 'curl %s\n' "\$url" >>'${CALLS}'
name="\${url##*/}"
if [[ -f '${SERVER_DIR}'/"\$name" ]]; then cp '${SERVER_DIR}'/"\$name" "\$out"; exit 0; fi
exit 22
EOF
	chmod +x "${MOCK_BIN}/curl"
	printf '#!/usr/bin/env bash\nexit 0\n' >"${MOCK_BIN}/sleep"
	chmod +x "${MOCK_BIN}/sleep"

	# slsa-verifier: records argv, succeeds unless SLSA_FAIL is set.
	cat >"${MOCK_BIN}/slsa-verifier" <<EOF
#!/usr/bin/env bash
printf 'slsa-verifier %s\n' "\$*" >>'${CALLS}'
[[ -n "\${SLSA_FAIL:-}" ]] && exit 1
exit 0
EOF
	chmod +x "${MOCK_BIN}/slsa-verifier"

	# git ls-remote: an annotated tag line plus its peeled commit.
	cat >"${MOCK_BIN}/git" <<EOF
#!/usr/bin/env bash
printf 'git %s\n' "\$*" >>'${CALLS}'
if [[ "\$1" == "ls-remote" ]]; then
	printf '%s\trefs/tags/v1.10.0\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	printf '%s\trefs/tags/v1.10.0^{}\n' f7defb94362f2053a3e73d13086a167448ea9133
	exit 0
fi
exit 1
EOF
	chmod +x "${MOCK_BIN}/git"
}

teardown() {
	teardown_temp_dir
}

_sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

# Script arguments go to the script; extra environment goes in ENV_EXTRA.
ENV_EXTRA=()
_run() {
	run env PATH="${MOCK_BIN}:${PATH}" VERSIONS_FILE="$VERSIONS_FILE" "${ENV_EXTRA[@]}" bash "$SCRIPT" "$@"
}

_pin() {
	sed -n "s/^${1}=\"\([^\"]*\)\".*/\1/p" "$VERSIONS_FILE"
}

@test "refresh-tool-digests: --check reports every placeholder that differs from upstream" {
	_run --check osv-scanner bats-core
	assert_failure
	assert_output --partial "DEFAULT_OSV_SCANNER_SHA256_LINUX_AMD64 differs"
	assert_output --partial "DEFAULT_OSV_SCANNER_SHA256_LINUX_ARM64 differs"
	assert_output --partial "DEFAULT_BATS_CORE_COMMIT differs"
	assert_output --partial "3 committed digest(s) differ"
	# --check never rewrites the file.
	[[ "$(_pin DEFAULT_OSV_SCANNER_SHA256_LINUX_AMD64)" == "0000000000000000000000000000000000000000000000000000000000000000" ]]
}

@test "refresh-tool-digests: --write replaces only the quoted values and keeps the tag comments" {
	_run --write osv-scanner bats-core
	assert_success
	[[ "$(_pin DEFAULT_OSV_SCANNER_SHA256_LINUX_AMD64)" == "$AMD64_SHA" ]]
	[[ "$(_pin DEFAULT_OSV_SCANNER_SHA256_LINUX_ARM64)" == "$ARM64_SHA" ]]
	[[ "$(_pin DEFAULT_BATS_CORE_COMMIT)" == "f7defb94362f2053a3e73d13086a167448ea9133" ]]
	run grep -c '" # v2.3.5$' "$VERSIONS_FILE"
	assert_output "2"
	run grep -c '" # v1.10.0$' "$VERSIONS_FILE"
	assert_output "1"
	# Version lines are untouched.
	[[ "$(_pin DEFAULT_OSV_SCANNER_VERSION)" == "2.3.5" ]]
	# A second --check is now clean.
	_run --check osv-scanner bats-core
	assert_success
	assert_output --partial "all committed digests match upstream"
}

@test "refresh-tool-digests: verifies every osv-scanner asset against the SLSA provenance" {
	_run --write osv-scanner
	assert_success
	run grep -c '^slsa-verifier verify-artifact' "$CALLS"
	assert_output "2"
	run cat "$CALLS"
	assert_output --partial "--source-uri github.com/google/osv-scanner"
	assert_output --partial "--source-tag v2.3.5"
}

@test "refresh-tool-digests: a provenance verification failure is fatal even with the escape hatch" {
	ENV_EXTRA=(SLSA_FAIL=1 LGTM_CI_ALLOW_UNVERIFIED=1)
	_run --write osv-scanner
	assert_failure
	[[ "$(_pin DEFAULT_OSV_SCANNER_SHA256_LINUX_AMD64)" == "0000000000000000000000000000000000000000000000000000000000000000" ]]
}

@test "refresh-tool-digests: a missing slsa-verifier is a hard error by default" {
	rm -f "${MOCK_BIN}/slsa-verifier"
	ENV_EXTRA=(PATH="${MOCK_BIN}:/usr/bin:/bin")
	_run --write osv-scanner
	assert_failure
	assert_output --partial "slsa-verifier is required for SLSA provenance verification"
	[[ "$(_pin DEFAULT_OSV_SCANNER_SHA256_LINUX_AMD64)" == "0000000000000000000000000000000000000000000000000000000000000000" ]]
}

@test "refresh-tool-digests: a missing slsa-verifier only warns under the escape hatch" {
	rm -f "${MOCK_BIN}/slsa-verifier"
	ENV_EXTRA=(PATH="${MOCK_BIN}:/usr/bin:/bin" LGTM_CI_ALLOW_UNVERIFIED=1)
	_run --write osv-scanner
	assert_success
	assert_output --partial "::warning title=unverified install::slsa-verifier is required"
	[[ "$(_pin DEFAULT_OSV_SCANNER_SHA256_LINUX_AMD64)" == "$AMD64_SHA" ]]
}

@test "refresh-tool-digests: an asset whose bytes disagree with the upstream manifest is fatal" {
	printf 'tampered\n' >"${SERVER_DIR}/osv-scanner_linux_amd64"
	_run --write osv-scanner
	assert_failure
	assert_output --partial "upstream manifest says"
	[[ "$(_pin DEFAULT_OSV_SCANNER_SHA256_LINUX_AMD64)" == "0000000000000000000000000000000000000000000000000000000000000000" ]]
}

@test "refresh-tool-digests: resolves an annotated tag to its peeled commit" {
	_run --write bats-core
	assert_success
	[[ "$(_pin DEFAULT_BATS_CORE_COMMIT)" == "f7defb94362f2053a3e73d13086a167448ea9133" ]]
	run cat "$CALLS"
	assert_output --partial "ls-remote --tags https://github.com/bats-core/bats-core.git refs/tags/v1.10.0 refs/tags/v1.10.0^{}"
}

@test "refresh-tool-digests: rejects an unknown tool and an unknown option" {
	_run --check no-such-tool
	assert_failure
	assert_output --partial "Unknown tool: no-such-tool"
	_run --bogus
	assert_failure
	assert_output --partial "Unknown option: --bogus"
}

@test "refresh-tool-digests: --write refuses to invent a variable that is not declared" {
	# Drop the arm64 line: --write must report it instead of appending.
	sed -i.bak '/LINUX_ARM64/d' "$VERSIONS_FILE"
	rm -f "${VERSIONS_FILE}.bak"
	_run --write osv-scanner
	assert_failure
	assert_output --partial "DEFAULT_OSV_SCANNER_SHA256_LINUX_ARM64 is not declared"
	run grep -c 'LINUX_ARM64' "$VERSIONS_FILE"
	assert_output "0"
}
