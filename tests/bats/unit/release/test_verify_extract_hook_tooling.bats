#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Unit tests for scripts/ci/bootstrap/verify-extract-hook-tooling.sh (#1450)
#
# The source script of the generated "Verify and extract lgtm-ci tooling" step
# in reusable-release-version-pr.yml; sync_inline_blocks.py --check keeps that
# copy equal to this body, and integration/test_reusable_release_hook_isolation.bats pins
# where the steps sit in each job.

load "../../../helpers/common"
load "../../../helpers/sha256_tools"

SCRIPT="${PROJECT_ROOT}/scripts/ci/bootstrap/verify-extract-hook-tooling.sh"

setup() {
	WORK="${BATS_TEST_TMPDIR}/work"
	TEMP="${BATS_TEST_TMPDIR}/runner-temp"
	mkdir -p "$WORK" "$TEMP" "${BATS_TEST_TMPDIR}/src/scripts"
	echo "echo tool" >"${BATS_TEST_TMPDIR}/src/scripts/tool.sh"
	TARBALL="${BATS_TEST_TMPDIR}/hook-tooling.tar.gz"
	COPYFILE_DISABLE=1 tar -czf "$TARBALL" -C "${BATS_TEST_TMPDIR}/src" scripts
	DIGEST="$(_sha256 "$TARBALL")"
}

_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

_verify() {
	cd "$WORK"
	run env TARBALL="$TARBALL" EXPECTED_DIGEST="$1" RUNNER_TEMP="$TEMP" bash "$SCRIPT"
}

# Writes a gzip tarball at $TARBALL holding scripts/tool.sh plus one crafted
# member: craft <kind> <name> [<link target>], kind file, symlink or hardlink.
_craft() {
	python3 -I - "$TARBALL" "$@" <<'PY'
import io
import sys
import tarfile

path, kind, name, *rest = sys.argv[1:]
with tarfile.open(path, "w:gz", format=tarfile.GNU_FORMAT) as archive:
    def add(info, data=b""):
        info.size = len(data)
        archive.addfile(info, io.BytesIO(data) if data else None)
    add(tarfile.TarInfo("scripts/tool.sh"), b"echo tool\n")
    info = tarfile.TarInfo(name)
    if kind == "file":
        add(info, b"planted\n")
    else:
        info.type = tarfile.SYMTYPE if kind == "symlink" else tarfile.LNKTYPE
        info.linkname = rest[0]
        add(info)
PY
	DIGEST="$(_sha256 "$TARBALL")"
}

# Nothing extracted, and the private copy under RUNNER_TEMP is gone.
_assert_nothing_left() {
	[ ! -e "${WORK}/.lgtm-ci-tooling" ]
	run find "$TEMP" -mindepth 1
	assert_output ""
}

@test "verify-extract-hook-tooling: a matching digest extracts the tooling" {
	_verify "$DIGEST"
	assert_success
	assert_output --partial "${TARBALL}: OK"
	[ -f "${WORK}/.lgtm-ci-tooling/scripts/tool.sh" ]
	# The private copy is removed afterwards.
	run find "$TEMP" -mindepth 1
	assert_output ""
}

@test "verify-extract-hook-tooling: a malformed or empty digest fails before hashing" {
	local digest upper
	upper="$(printf '%s' "$DIGEST" | tr '[:lower:]' '[:upper:]')"
	for digest in "" "not-a-digest" "$upper" "${DIGEST}0"; do
		_verify "$digest"
		assert_failure 1
		assert_output "::error::no tooling digest"
		[ ! -e "${WORK}/.lgtm-ci-tooling" ]
	done
}

@test "verify-extract-hook-tooling: a mismatched digest fails and extracts nothing" {
	_verify "$(printf '0%.0s' {1..64})"
	assert_failure
	assert_output --partial "FAILED"
	_assert_nothing_left
}

@test "verify-extract-hook-tooling: an existing tooling directory is never merged into" {
	mkdir "${WORK}/.lgtm-ci-tooling"
	_verify "$DIGEST"
	assert_failure
	[ ! -e "${WORK}/.lgtm-ci-tooling/scripts" ]
}

@test "verify-extract-hook-tooling: a FIFO in place of the tarball is refused" {
	# A FIFO can serve the checked archive to one open and another archive to
	# the next; it is refused before any read.
	local good="${BATS_TEST_TMPDIR}/good.tar.gz"
	mv "$TARBALL" "$good"
	mkfifo "$TARBALL"
	_verify "$DIGEST"
	assert_failure 1
	assert_output "::error::${TARBALL} is not a regular file"
	_assert_nothing_left
}

@test "verify-extract-hook-tooling: a symlink in place of the tarball is refused" {
	local good="${BATS_TEST_TMPDIR}/good.tar.gz"
	mv "$TARBALL" "$good"
	ln -s "$good" "$TARBALL"
	_verify "$DIGEST"
	assert_failure 1
	assert_output "::error::${TARBALL} is not a regular file"
	_assert_nothing_left
}

@test "verify-extract-hook-tooling: hashes and extracts the same private copy" {
	# The path is opened once: the checked bytes are the extracted bytes even
	# when the path changes between the digest check and the extraction. The
	# hash tool stubs hash, then swap the path for a different archive; an
	# extraction that reopened the path would unpack the planted tool.
	local stub="${BATS_TEST_TMPDIR}/stub" other="${BATS_TEST_TMPDIR}/other"
	local tool real
	mkdir -p "$stub" "${other}/scripts"
	echo "echo planted" >"${other}/scripts/tool.sh"
	COPYFILE_DISABLE=1 tar -czf "${BATS_TEST_TMPDIR}/other.tar.gz" -C "$other" scripts
	for tool in sha256sum shasum; do
		real="$(command -v "$tool")" || continue
		cat >"${stub}/${tool}" <<EOF
#!/usr/bin/env bash
$real "\$@"
status=\$?
$(command -v cp) "${BATS_TEST_TMPDIR}/other.tar.gz" "${TARBALL}"
exit "\$status"
EOF
		chmod +x "${stub}/${tool}"
	done
	cd "$WORK"
	run env PATH="${stub}:${PATH}" TARBALL="$TARBALL" EXPECTED_DIGEST="$DIGEST" \
		RUNNER_TEMP="$TEMP" bash "$SCRIPT"
	assert_success
	cmp -s "$TARBALL" "${BATS_TEST_TMPDIR}/other.tar.gz"
	run cat "${WORK}/.lgtm-ci-tooling/scripts/tool.sh"
	assert_output "echo tool"
}

@test "verify-extract-hook-tooling: a .. member is refused" {
	_craft file "scripts/../../escaped"
	_verify "$DIGEST"
	assert_failure 1
	assert_output --partial "has an absolute or .. member"
	_assert_nothing_left
	[ ! -e "${BATS_TEST_TMPDIR}/escaped" ]
}

@test "verify-extract-hook-tooling: an absolute member is refused" {
	_craft file "${BATS_TEST_TMPDIR}/absolute"
	_verify "$DIGEST"
	assert_failure 1
	assert_output --partial "has an absolute or .. member"
	_assert_nothing_left
	[ ! -e "${BATS_TEST_TMPDIR}/absolute" ]
}

@test "verify-extract-hook-tooling: a symlink member pointing outside is refused" {
	_craft symlink "scripts/out" "${BATS_TEST_TMPDIR}"
	_verify "$DIGEST"
	assert_failure 1
	assert_output --partial "has a link member"
	_assert_nothing_left
}

@test "verify-extract-hook-tooling: a hardlink member is refused" {
	_craft hardlink "scripts/hard" "${BATS_TEST_TMPDIR}/src/scripts/tool.sh"
	_verify "$DIGEST"
	assert_failure 1
	assert_output --partial "has a link member"
	_assert_nothing_left
}

@test "verify-extract-hook-tooling: works with only sha256sum or only shasum" {
	local tool dir
	for tool in sha256sum shasum; do
		dir="${BATS_TEST_TMPDIR}/path-${tool}"
		sha256_only_path "$tool" "$dir"
		rm -rf "${WORK}/.lgtm-ci-tooling"
		cd "$WORK"
		run env PATH="$dir" TARBALL="$TARBALL" EXPECTED_DIGEST="$DIGEST" \
			RUNNER_TEMP="$TEMP" bash "$SCRIPT"
		assert_success
		[ -f "${WORK}/.lgtm-ci-tooling/scripts/tool.sh" ]
		run cat "${dir}/calls"
		assert_output "$tool"
	done
}
